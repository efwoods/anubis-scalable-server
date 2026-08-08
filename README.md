# anubis-scalable-server

AWS deployment for the [Anubis API](https://github.com/efwoods/anubis) (Neural Nexus) and
the customer portal server — Terraform, Helm, and the architecture and cost analysis
behind them.

Today both services run on **one host** via Docker Compose behind a Cloudflare Tunnel,
with PostgreSQL and Redis as local containers. This repository replaces that with a
LangSmith **standalone Agent Server** on Amazon EKS: managed RDS and ElastiCache, an
autoscaling chat tier, media processing isolated onto its own nodes, and an ALB in place
of the tunnel.

> The `anubis` and `anubis-customer-portal` repositories are **reference-only** here.
> Nothing in this repository modifies them. Changes they need are documented as a phased
> backlog in [`docs/upstream-changes.md`](docs/upstream-changes.md), and the
> infrastructure is designed to be correct today without any of them.

---

## Start here

| If you want to | Read |
|---|---|
| Understand the design and why it deviates from the standard answer | [`architecture/scalable_architecture.md`](architecture/scalable_architecture.md) |
| Size the deployment | [`architecture/resource-quantity-table.md`](architecture/resource-quantity-table.md) |
| Know what it costs | [`architecture/cost-model.md`](architecture/cost-model.md) |
| Deploy it, or fix it at 3am | [`docs/runbook.md`](docs/runbook.md) |
| Move DNS off Cloudflare | [`docs/dns-cutover.md`](docs/dns-cutover.md) |
| Build and publish images | [`docs/image-pipeline.md`](docs/image-pipeline.md) |
| Know what to change in `anubis` next | [`docs/upstream-changes.md`](docs/upstream-changes.md) |
| Work on the Helm releases | [`helm/README.md`](helm/README.md) |

---

## Four findings that shaped the design

Read from the application code, and each one changes a decision:

1. **The API tier is the compute tier.** `webapp.py` executes graphs in-process
   (`graph.astream` at `:900`, `graph.ainvoke` at `:3563` and `:3834`), and a repo-wide
   search for `client.runs.*` finds nothing — the Agent Server's task queue is never
   used. So queue workers are **off** at launch and the API tier is what scales.
2. **Two in-process registries block naive replica scaling** — the media-job registry
   (`:1270`) and the MCP relay registry (`:2709`). Rather than capping the whole
   deployment at one replica, a single-replica `anubis-stateful` Deployment owns exactly
   those routes and everything else scales freely.
3. **Rate limiting and metering are already replica-safe** — `metering.py` computes the
   rolling window in SQL over `api_metrics`, not in memory. Nothing to change.
4. **The image is 12.8 GB**, so a scale-out event stalls for minutes without help. Three
   mitigations ship here; the real fix is upstream change #4.

---

## Layout

```
architecture/   design, sizing, and cost analysis
docs/           runbook, DNS cutover, image pipeline, upstream backlog
terraform/      modules/{network,eks,data,registry,secrets,dns} + envs/prod
helm/           platform, stripe-provision, anubis-api, anubis-stateful, portal-server
scripts/        backend bootstrap, DB bootstrap, ECR push, model-cache warm
.github/        terraform plan/apply and Helm deploy workflows
```

---

## Quick start

Full detail and the verification checklist are in [`docs/runbook.md`](docs/runbook.md);
this is the shape of it.

```bash
# 0. One-time: create the Terraform state bucket, then set it in
#    terraform/envs/prod/backend.tf
./scripts/bootstrap-tf-backend.sh anubis-terraform-state-<unique>

# 1. Infrastructure (~20-30 min, dominated by EKS and Multi-AZ RDS)
terraform -chdir=terraform/envs/prod init
terraform -chdir=terraform/envs/prod apply

# 2. Populate the two Secrets Manager secrets from the existing .env files
#    (runbook §1.2 — Terraform creates them empty and never holds their values)

# 3. pgvector, and optionally restore the current database
./scripts/bootstrap-db.sh
./scripts/bootstrap-db.sh --restore anubis.dump

# 4. Images
./scripts/push-to-ecr.sh all --anubis-path ../anubis \
  --portal-path ../anubis-customer-portal/src/server

# 5. Cluster controllers, then the four Helm releases (helm/README.md)
#    or run .github/workflows/deploy.yml

# 6. Verify against the ALB, then cut DNS (docs/dns-cutover.md)
```

Nothing user-facing changes until step 6. The Compose stacks keep serving traffic
throughout, and the rollback is to restart them.

---

## Before the first deploy

Two things will block it if unresolved:

- **A LangSmith license key.** A standalone Agent Server verifies
  `LANGGRAPH_CLOUD_LICENSE_KEY` once at start-up against `beacon.langchain.com`. Confirm
  what the current plan entitles — the infrastructure is identical either way, but
  without it the pods do not start.
- **DNS authority.** Either delegate `neuralnexus.site` to Route 53 (one registrar
  change) or keep it at Cloudflare with **DNS-only** records. Cloudflare's proxy would
  break the `/message` SSE stream and the `/mcp/relay` WebSocket, both of which the ALB
  carries a 3600 s idle timeout to support.

---

## Validation

Everything here is checked, not just written:

```bash
terraform -chdir=terraform/envs/prod init -backend=false && \
terraform -chdir=terraform/envs/prod validate     # Success
terraform fmt -check -recursive terraform/        # clean

for chart in platform anubis-stateful stripe-provision portal-server; do
  helm lint "helm/$chart" -f "helm/$chart/values-prod.yaml"
done                                              # 0 failed

shellcheck -S warning scripts/*.sh                # clean
actionlint                                        # clean
```

The rendered manifests validate against the Kubernetes 1.31 schemas with `kubeconform`
(17 resources valid, 3 CRDs skipped for lack of a public schema).
