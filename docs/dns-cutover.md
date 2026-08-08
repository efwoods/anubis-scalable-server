# DNS Cutover — Cloudflare Tunnel to AWS ALB

Moving `api.neuralnexus.site` and `checkout-api.neuralnexus.site` off the host
`cloudflared` tunnel and onto the AWS Application Load Balancer.

**Current state** (from `anubis-customer-portal/_TUNNEL_DEPLOY_RUNBOOK.md` and
`anubis/cloudflare/config.yml`) — one tunnel, `neuralnexus-api`
(`980ecf10-3835-4226-a164-dc22d13b2dc9`), running as a host systemd service with two
ingress rules:

```yaml
ingress:
  - hostname: api.neuralnexus.site
    service: http://localhost:8124        # Anubis Compose stack
  - hostname: checkout-api.neuralnexus.site
    service: http://localhost:8200        # portal-live Compose stack
  - service: http_status:404
```

**Target state** — both hostnames resolve to the ALB. No tunnel, no `cloudflared`.

---

## 1. Pick a DNS authority

The zone `neuralnexus.site` is on Cloudflare today. Two options; the architecture is
identical either way.

### Option A — delegate the zone to Route 53 (recommended)

One authority for DNS, ACM validation, and health checks; everything in Terraform.

1. `terraform apply` creates the hosted zone and outputs its four name servers.
2. At the **registrar**, replace the Cloudflare name servers with those four.
3. Wait for propagation (minutes to 48 hours, usually under an hour).

**Cost:** a Cloudflare-proxied zone also provides DDoS protection and WAF for free.
Moving off it means AWS WAF on the ALB is the replacement if that protection is wanted —
not provisioned by default in this repo.

### Option B — keep DNS at Cloudflare, DNS-only records

Nothing is delegated; Cloudflare stays the authority and simply points at the ALB.

- Add `CNAME api → <alb-dns-name>`, **grey cloud (DNS only, not proxied)**.
- Add `CNAME checkout-api → <alb-dns-name>`, grey cloud.
- Add the ACM validation `CNAME`s that Terraform outputs.

**Proxied (orange cloud) will break things.** Cloudflare's proxy buffers responses and
enforces its own ~100 s timeout, which is incompatible with the `/message` SSE stream and
the `/mcp/relay` WebSocket that the ALB is configured with a 3600 s idle timeout to
support. If the zone stays on Cloudflare, these two records must be DNS-only.

Set `create_route53_zone = false` in `terraform.tfvars` for this option; the `dns` module
then only creates the ACM certificate and outputs the validation records for manual entry.

---

## 2. Validate the certificate

ACM issues a certificate for `api.neuralnexus.site` and `checkout-api.neuralnexus.site`
using DNS validation.

**Option A:** Terraform creates the validation records automatically; `terraform apply`
blocks until the certificate is `ISSUED`.

**Option B:** `terraform apply` pauses at `aws_acm_certificate_validation`. Add the
records Terraform printed:

```bash
terraform output acm_validation_records
```

to Cloudflare (DNS-only), then let the apply finish.

```bash
aws acm describe-certificate --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query 'Certificate.Status'      # want "ISSUED"
```

---

## 3. Verify the ALB before changing any record

This is the step that makes the cutover safe. The ALB serves correct traffic under its
own hostname long before DNS points at it.

```bash
ALB=$(kubectl get ingress -n anubis anubis-api \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Resolve the ALB but send the production Host header and SNI
curl -sf --resolve "api.neuralnexus.site:443:$(dig +short "$ALB" | head -1)" \
     https://api.neuralnexus.site/ok

curl -sf --resolve "checkout-api.neuralnexus.site:443:$(dig +short "$ALB" | head -1)" \
     https://checkout-api.neuralnexus.site/healthz
```

`--resolve` exercises the real certificate, the real Host-based routing rules, and the
real path-ordering rules — everything DNS would exercise, without DNS.

Work through the full checklist in [runbook.md](runbook.md) §7 here. **Do not proceed
until every item passes.**

---

## 4. Cut over

Lower the TTL first so a rollback is fast.

```bash
# Option A — Route 53 alias records, created by terraform apply.
#   Set dns_ttl = 60 in terraform.tfvars, apply, wait one TTL, then apply the
#   real records. (Alias records to an ALB have no TTL of their own, so this
#   only matters if you used CNAMEs.)
terraform apply -target=module.dns
```

For Option B, change the TTL to 60 in Cloudflare, wait an hour, then repoint the records.

Then, one hostname at a time — **`checkout-api` first**, because it carries less traffic
and a failure there is contained to the billing portal:

```bash
watch -n5 'dig +short checkout-api.neuralnexus.site'
curl -s https://checkout-api.neuralnexus.site/healthz
```

Confirm the portal is healthy and the Vercel client works end to end, then repeat for
`api.neuralnexus.site`.

**Both tunnels and the ALB serve correctly during the transition.** The Compose stacks are
still running and still registered with the tunnel, so a client resolving the old address
gets the old stack and a client resolving the new one gets the ALB. Both talk to the same
RDS database if you have already migrated the data — decide which is true before this
step:

- **Migrated first (recommended):** the Compose stack is stopped and the tunnel returns
  502 for anything that has not yet moved. Short, visible, unambiguous.
- **Both live:** the Compose stack still points at the old container database, so writes
  split across two databases during the transition. **Do not do this.** Stop the Compose
  API before repointing DNS.

---

## 5. Rollback

Valid until §6 is done.

```bash
# Restart the old stacks
sudo systemctl start cloudflared
cd anubis && docker compose -f docker-compose-prod.yml up -d
cd anubis-customer-portal/src/server && docker compose -f docker-compose.yml up -d
```

**Option A:** delete the Route 53 alias records; the registrar still points at Route 53,
so also re-add the Cloudflare tunnel `CNAME`s there
(`<tunnel-id>.cfargotunnel.com`, proxied). Faster: revert the registrar's name servers to
Cloudflare, which restores the whole previous zone at once.

**Option B:** change the two `CNAME`s back to `<tunnel-id>.cfargotunnel.com` and re-enable
the orange cloud.

Rollback speed is bounded by the TTL, which is why §4 lowers it first.

Note the split-write hazard in reverse: any avatar data written to RDS after the cutover
is **not** in the old container database. A rollback more than a few minutes after
cutover needs a `pg_dump` from RDS restored into the container, or that data is lost.

---

## 6. Decommission

Only after the AWS deployment has been stable for at least a full business week.

```bash
sudo systemctl disable --now cloudflared
cd anubis && docker compose -f docker-compose-prod.yml down
cd anubis && docker compose -f docker-compose-postgres.yml down     # keep the volume
cd anubis-customer-portal/src/server && docker compose -f docker-compose.yml down
```

**Keep the Postgres volume and take a final `pg_dump`** before removing anything. It is
the only remaining copy of the pre-migration state.

Then clean up the tunnel:

```bash
cloudflared tunnel route dns --overwrite-dns neuralnexus-api ...   # or delete the records
cloudflared tunnel delete neuralnexus-api
```

Also update, in the repos this repo does not modify:

- `anubis/cloudflare/config.yml` — the ingress rules no longer describe reality
- `anubis-customer-portal/_TUNNEL_DEPLOY_RUNBOOK.md` — superseded by this document

---

## 7. What does not change

- **The Vercel client.** `src/client/.env.production` pins
  `VITE_API_BASE_URL=https://checkout-api.neuralnexus.site`, which is the same hostname
  after the cutover. No rebuild, no redeploy.
- **`checkout.neuralnexus.site`.** The Cloudflare 302 redirect rule to the Vercel
  production alias is a client-side concern and is untouched. It works with either DNS
  option.
- **`CLIENT_ORIGIN`.** The Vercel origin is unchanged, so the portal's CORS allowlist
  needs no edit.
- **Stripe webhooks.** The registered endpoint is
  `https://api.neuralnexus.site/stripe/webhook` — same hostname, same signing secret.
  Confirm delivery in the Stripe dashboard after cutover; a webhook failing silently is
  how a portal-driven downgrade cancels a paid subscription without creating the
  replacement free-tier one.
- **Auth0.** Callback and logout URLs reference the same hostnames.
