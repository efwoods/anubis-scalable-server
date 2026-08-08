# Runbook

Operating the Anubis Agent Server and the customer portal server on EKS.

Assumes `terraform/envs/prod` is applied and `kubectl` is pointed at the cluster:

```bash
aws eks update-kubeconfig --region us-east-2 --name anubis-prod
kubectl config set-context --current --namespace=anubis
```

---

## 1. First deployment

Run in order. Steps 1–3 change nothing user-facing.

### 1.1 Provision infrastructure

```bash
cd terraform/envs/prod
terraform init
terraform plan -out=tfplan          # review; expect ~120 resources on a clean account
terraform apply tfplan
```

Takes 20–30 minutes, dominated by the EKS control plane and the Multi-AZ RDS instance.

### 1.2 Populate secrets

Terraform creates the Secrets Manager secrets **empty** — it never holds secret values in
state. Populate them from the existing `.env` files:

```bash
# Anubis: convert the prod .env into the JSON blob ESO syncs
python - <<'PY' > /tmp/anubis-env.json
import json, pathlib
env = {}
for line in pathlib.Path("../../../anubis/.env").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    env[key.strip()] = value.strip().strip('"').strip("'")
print(json.dumps(env, indent=2))
PY

aws secretsmanager put-secret-value \
  --secret-id anubis/prod/env --secret-string file:///tmp/anubis-env.json
shred -u /tmp/anubis-env.json
```

Then **override the values that are host-specific**, using the Terraform outputs:

| Key | Value |
|---|---|
| `POSTGRES_URI` / `DATABASE_URI` | `terraform output -raw rds_connection_uri` |
| `PG_HOST` / `PG_PORT` / `PG_DB` / `PG_USER` / `PG_PASSWORD` | from the same output |
| `REDIS_URI` | `terraform output -raw redis_connection_uri` |
| `LANGGRAPH_CLOUD_LICENSE_KEY` | from LangChain — see architecture §7 |
| `LANGSMITH_API_KEY` | existing key |
| `STRIPE_BILLING_CONFIG_FILE` | **unset** — Kubernetes uses `STRIPE_BILLING_CONFIG_JSON` (§4) |
| `PORT` | `8000` |

Repeat for `portal/prod/env` from `anubis-customer-portal/src/server/.env`, overriding
`CLIENT_ORIGIN` and `NN_API_BASE_URL` as needed.

### 1.3 Bootstrap the database

```bash
./scripts/bootstrap-db.sh            # CREATE EXTENSION vector; verify version
```

To migrate existing data from the Compose Postgres container:

```bash
docker exec postgres16 pg_dump -U "$PG_USER" -Fc "$PG_DB" > anubis.dump
pg_restore --no-owner --no-privileges -d "$(terraform output -raw rds_connection_uri)" anubis.dump
```

Take the dump with the API stopped, or accept that writes after the dump are lost.

### 1.4 Push images

```bash
./scripts/push-to-ecr.sh all --tag "$(git -C ../anubis rev-parse --short HEAD)"
```

See [image-pipeline.md](image-pipeline.md). Expect a long first push.

### 1.5 Install the platform layer

```bash
helm upgrade --install platform ./helm/platform \
  -f helm/platform/values-prod.yaml -n anubis --create-namespace
kubectl get externalsecret -n anubis      # expect SecretSynced
kubectl get secret anubis-env portal-env -n anubis
```

If `ExternalSecret` is not `SecretSynced`, nothing downstream will start. Check the ESO
controller logs and the IRSA role annotation on the service account first.

### 1.6 Warm the Hugging Face cache

```bash
kubectl apply -f scripts/warm-hf-cache.yaml
kubectl wait --for=condition=complete job/warm-hf-cache --timeout=20m
```

Skipping this is not fatal — the first pod of each Deployment downloads the models itself
and takes several extra minutes to become ready.

### 1.7 Install the workloads

Order matters, for two reasons: `stripe-provision` must succeed before any API pod
starts, and `anubis-api` runs the Agent Server schema migrations, so it must precede
`anubis-stateful` (which runs the same image against the same database).

```bash
helm repo add langchain https://langchain-ai.github.io/helm/
helm repo update

TAG=<the tag from 1.4>
REGISTRY=$(terraform -chdir=terraform/envs/prod output -raw registry_url)

# 1. Stripe billing config -> Secrets Manager. Fails the deploy if Stripe is
#    unreachable or the account is unprovisioned. That is intended; see §4.
helm upgrade --install stripe-provision ./helm/stripe-provision \
  -f helm/stripe-provision/values-prod.yaml \
  --set image.repository="$REGISTRY/anubis-langgraph-api" \
  --set image.tag="$TAG" -n anubis --wait --timeout 30m

# 2. Chat / CRUD tier. Owns the schema migrations.
helm upgrade --install anubis-api langchain/langgraph-cloud \
  -f helm/anubis-api/values-prod.yaml \
  --set images.apiServerImage.repository="$REGISTRY/anubis-langgraph-api" \
  --set images.apiServerImage.tag="$TAG" -n anubis --wait --timeout 20m

# 3. Single-replica media + MCP tier, same image.
helm upgrade --install anubis-stateful ./helm/anubis-stateful \
  -f helm/anubis-stateful/values-prod.yaml \
  --set image.repository="$REGISTRY/anubis-langgraph-api" \
  --set image.tag="$TAG" -n anubis --wait --timeout 20m

# 4. Customer portal.
helm upgrade --install portal-server ./helm/portal-server \
  -f helm/portal-server/values-prod.yaml \
  --set image.repository="$REGISTRY/portal-server" \
  --set image.tag="$PORTAL_TAG" -n anubis --wait --timeout 10m
```

`.github/workflows/deploy.yml` runs exactly this sequence with the Terraform outputs
filled in; the manual form is here for first installs and incident work.

### 1.8 Verify before touching DNS

```bash
ALB=$(kubectl get ingress -n anubis anubis-api \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -sf "https://$ALB/ok" -H 'Host: api.neuralnexus.site' --insecure
curl -sf "https://$ALB/healthz" -H 'Host: checkout-api.neuralnexus.site' --insecure
```

The portal must answer `{"ok":true,"environment":"live"}`. The `environment` field is the
check that matters — a 200 alone does not tell you which Stripe account is behind it.

Then work through the full checklist in §7 before cutting DNS
([dns-cutover.md](dns-cutover.md)).

---

## 2. Routine deploy

```bash
./scripts/push-to-ecr.sh anubis ../anubis --tag "$TAG"

helm upgrade anubis-api langchain/langgraph-cloud \
  -f helm/anubis-api/values-prod.yaml --set images.apiServerImage.tag="$TAG" \
  -n anubis --wait --timeout 20m

kubectl rollout status deploy/anubis-api -n anubis
```

`anubis-api` rolls with `maxUnavailable: 0` and a 600-second grace period, so open SSE
streams finish on the old pods while new ones take traffic.

`anubis-stateful` uses `strategy: Recreate` — **it goes down during its own upgrade, and
in-flight media jobs are lost** (the registry is in-process; see
[upstream change #2](upstream-changes.md)). Deploy it when uploads are quiet, and check
first:

```bash
kubectl exec -n anubis deploy/anubis-stateful -- \
  curl -s localhost:8000/media_jobs | jq '.count'      # want 0
```

---

## 3. Rollback

```bash
helm rollback anubis-api           # previous revision
helm history anubis-api            # pick a specific revision
```

Fast only if the previous image is still cached on the nodes. After a node replacement,
expect a full 12.8 GB pull — minutes, not seconds.

**Full retreat to the old single host** (valid until the Compose stacks are torn down):
revert the DNS records per [dns-cutover.md](dns-cutover.md) §5 and restart
`cloudflared` plus both Compose stacks. Nothing in the AWS deployment needs to be
destroyed to do this.

---

## 4. Stripe billing configuration — the one behavioural difference from Compose

Compose passes `billing_config.json` between `stripe-provision` and the API through a
shared Docker volume (`docker-compose-prod.yml:95-111`). Pods cannot share a volume that
way.

On Kubernetes this is the `stripe-provision` release (`helm/stripe-provision`), a
`pre-install,pre-upgrade` hook Job in three stages — because the Anubis image is a wolfi
Python base with no `aws` CLI and no `jq`, while the `aws-cli` image has no application
code:

| Stage | Image | Does |
|---|---|---|
| `fetch-secret` (init) | `aws-cli` | reads the current `anubis/prod/env` JSON |
| `provision` (init) | Anubis | runs `provision_stripe_billing.py --live`, merges its output into that JSON with the standard library |
| `publish` | `aws-cli` | writes the merged JSON back |

The shared volume between stages is `emptyDir: { medium: Memory }`, so the secret never
touches disk. External Secrets Operator then refreshes the Kubernetes Secret and every
pod reads `STRIPE_BILLING_CONFIG_JSON` from the environment.

Consequences to know:

- **`STRIPE_BILLING_CONFIG_FILE` must be unset** on Kubernetes. `resolve_stripe_billing_config_json`
  gives the env var precedence, so leaving the file path set is harmless — but leaving
  `STRIPE_BILLING_CONFIG_JSON` *stale* is not, because it silently shadows a freshly
  provisioned config.
- **Every `helm upgrade` performs writes against the live Stripe account.** Safe by
  idempotency, not by omission — the same property the Compose file documents.
- If the hook Job fails, the upgrade **stops**. That is intended: an API running with no
  billing config treats paying customers as free tier. Billing correctness beats
  availability.

Check what the API actually loaded:

```bash
kubectl logs -n anubis deploy/anubis-api | grep -i "billing config\|tier catalog"
kubectl logs -n anubis job/stripe-provision --all-containers
```

The finished Job is deliberately **not** deleted on success (`hook-delete-policy:
before-hook-creation`, not `hook-succeeded`), so those logs are still there days later
when reconciling an invoice question.

---

## 5. Scaling

**Chat tier** — HPA-driven, 2 → 8 pods on 65 % CPU:

```bash
kubectl get hpa -n anubis -w
kubectl scale deploy/anubis-api -n anubis --replicas=4   # manual override; HPA reclaims it
```

**Media tier** — pinned at 1 replica by design ([architecture §3.1](../architecture/scalable_architecture.md)).
Scale *up* by giving it a bigger node and raising its resource requests, not by adding
replicas. Adding replicas will produce 404s on `/media_job/{id}` polling.

**Nodes** — cluster-autoscaler adds nodes when pods go `Pending`. A new node must pull the
image; see [image-pipeline.md](image-pipeline.md) §4.

**Data tier** — see [resource-quantity-table.md](../architecture/resource-quantity-table.md) §6.
Watch Postgres connections before raising `maxReplicas` past 12:

```sql
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
```

---

## 6. Incident playbook

| Symptom | First checks |
|---|---|
| Pods `CrashLoopBackOff` at startup | `kubectl logs --previous`. Most common: missing `LANGGRAPH_CLOUD_LICENSE_KEY`, or no egress to `beacon.langchain.com` (license verification runs once at start-up). |
| Pods stuck `ContainerCreating` for minutes | 12.8 GB pull. `kubectl describe pod` → `Pulling`. Check SOCI (image-pipeline §4) and whether the pre-pull DaemonSet is running on that node. |
| `ExternalSecret` not `SecretSynced` | ESO controller logs; IRSA role annotation on the service account; the secret's resource policy. |
| SSE streams cut at ~60 s | ALB `idle_timeout` reverted to default. `kubectl get ingress -o yaml \| grep idle_timeout` — must be 3600. |
| `/media_job/{id}` returns 404 | `anubis-stateful` has more than 1 replica, or the ALB path rule for `/media_job` is not ordered ahead of `/`. `kubectl get ingress -o yaml`, check `group.order`. |
| MCP data-analysis tools not found | Expected across tiers today. `DATA_ANALYSIS_ENABLED` should be `false` on `anubis-api`. See [upstream change #3](upstream-changes.md). |
| 402 responses spike | Metering, not infrastructure. `api_metrics` rolling window (`metering.py`). Check `USAGE_PERIOD_DAYS` matches the portal's setting. |
| 503 on checkout / tier changes | Portal found no provisioned tiers. `kubectl logs deploy/portal-server \| grep "Tier catalog"`. Re-run the Stripe provision hook. |
| Postgres connection exhaustion | `pg_stat_activity`; reduce `maxReplicas` or `LANGGRAPH_POSTGRES_POOL_MAX_SIZE`, or scale RDS up. |
| High NAT Gateway cost | A VPC endpoint is missing or a pull is bypassing it. Check the S3 gateway endpoint exists in every route table. |

**Log access:**

```bash
kubectl logs -n anubis deploy/anubis-api --tail=200 -f
kubectl logs -n anubis deploy/anubis-stateful --tail=200 -f
aws logs tail /aws/eks/anubis-prod/cluster --follow
```

---

## 7. Verification checklist

Run after the first deployment and after any change to the ALB, node groups, or data
tier.

- [ ] `terraform plan` reports no drift
- [ ] `SELECT extversion FROM pg_extension WHERE extname='vector';` returns a version
- [ ] `kubectl get pods -o wide` — `anubis-api` spread across ≥ 2 AZs, `anubis-stateful`
      alone on the tainted `media` node
- [ ] `curl -f https://api.neuralnexus.site/ok`
- [ ] `curl -s https://checkout-api.neuralnexus.site/healthz` → `environment: "live"`
- [ ] SSE holds past 60 s:
      `curl -N -X POST https://api.neuralnexus.site/message/<assistant_id> -H "API-KEY: $KEY" -d '...'`
- [ ] CORS from the Vercel origin:
      `curl -si -X OPTIONS https://checkout-api.neuralnexus.site/subscription -H 'Origin: https://anubis-customer-portal.vercel.app' -H 'Access-Control-Request-Method: GET' | grep -i access-control-allow-origin`
- [ ] Media round trip: upload via `/update_avatar_identity_with_media`, then poll
      `/media_job/{id}/progress` **at least 10 times** — no 404 (proves the path rule pins
      to `anubis-stateful`)
- [ ] HPA reacts: `hey -z 3m -c 50 https://api.neuralnexus.site/conversations` while
      watching `kubectl get hpa -w`; replicas rise above 2 and settle back, no 5xx
- [ ] Rolling deploy is non-disruptive: `helm upgrade` during an open SSE stream; the
      stream completes
- [ ] RDS failover: `aws rds reboot-db-instance --force-failover`; pods reconnect without
      a restart loop
- [ ] Stripe: `kubectl logs job/...stripe-provision` shows every tier as created or
      existing

---

## 8. Routine maintenance

| Cadence | Task |
|---|---|
| Weekly | Review `kubectl get hpa` history and AWS Budgets actual vs forecast |
| Monthly | `terraform plan` for drift; review ECR scan findings; check RDS `FreeStorageSpace` |
| Quarterly | EKS version upgrade (control plane, then node groups, then addons); rotate `SESSION_SIGNING_SECRET` and the RDS password; restore a backup into a scratch instance to prove PITR works |
| As needed | Re-check [cost-model.md](../architecture/cost-model.md) against actual Cost Explorer; take a Savings Plan once instance sizing has settled |
