# Anubis Scalable Architecture on AWS

Target: a horizontally scalable AWS deployment of the **Anubis Agent Server** and the
**Neural Nexus customer portal server**, replacing the single-host Docker Compose stack
that runs both today.

- **Topology:** LangSmith [standalone Agent Server](https://docs.langchain.com/langsmith/deploy-standalone-server)
  on Amazon EKS — API server containers plus your own PostgreSQL and Redis, no LangSmith
  control plane.
- **Region:** `us-east-2`.
- **Ingress:** AWS Application Load Balancer + ACM. **No Cloudflare Tunnel.**
- **Scale:** deployed at launch scale (~5 req/s), sized and bounded so medium scale
  (~50 req/s) is a values change. See [resource-quantity-table.md](resource-quantity-table.md)
  and [cost-model.md](cost-model.md).

---

## 1. What runs today

| Piece | Today |
|---|---|
| Anubis Agent Server (`evdev3/anubis-langgraph-api`) | `anubis/docker-compose-prod.yml` → host `:8124` |
| Customer portal server | `anubis-customer-portal/src/server/docker-compose.yml` → host `:8200` |
| PostgreSQL (pgvector) | `anubis/docker-compose-postgres.yml` container, local volume |
| Redis | `redis:7-alpine` container |
| Prometheus + Grafana | prod compose |
| Public ingress | host `cloudflared` systemd tunnel `980ecf10-3835-4226-a164-dc22d13b2dc9` |

One machine. No autoscaling, no failover, and the durable store — every avatar's
identity documents, memories, and checkpoints — is a container on a local disk. A batch
of media uploads (ffmpeg, torch, diarization) competes for CPU with live chat inference
on the same box.

---

## 2. Findings from the application code that shape this design

The generic answer for "scale a LangGraph deployment" does not fit Anubis unmodified.
Four properties of `anubis/src/api/webapp.py` change it. Each is load-bearing for a
decision below.

### 2.1 Agent execution happens in the API pods, not in queue workers

`webapp.py` executes the compiled graph **in-process**:

| Location | Call |
|---|---|
| `src/api/webapp.py:900` | `graph.astream(...)` — the SSE streaming path |
| `src/api/webapp.py:3563` | `graph.ainvoke(...)` — `POST /message` |
| `src/api/webapp.py:3834` | `graph.ainvoke(...)` — `POST /message/{assistant_id}` |
| `src/api/webapp.py:1271` | `AsyncPostgresSaver(app.state.pool)` — its checkpointer |

A repo-wide search for `client.runs.*` across `anubis/src/` returns **nothing**. No code
path creates a LangGraph run through the task queue. The `get_client()` calls elsewhere
in `webapp.py` are for assistants, threads, and store CRUD only.

**Consequence.** The architecture in `scalable_architecture.png` — API servers → Redis →
queue workers — is the Agent Server's *available* topology, not the one Anubis currently
uses. Queue workers would sit idle, and `N_JOBS_PER_WORKER` would govern nothing.

> **The API tier is the compute tier.** Launch with `queue.enabled: false` (the chart's
> single-host mode) and scale the API tier. Turning queue workers on is Phase 2, gated on
> [upstream change #1](../docs/upstream-changes.md#1-move-message-onto-the-task-queue).

### 2.2 Two in-process registries block naive API replica scaling

Both live in the FastAPI process and are invisible to every other pod:

- **Media jobs** — `app.state.media_jobs` (`webapp.py:1270`), populated by
  `create_master_job` / `create_child_job` and driven by `asyncio.create_task`
  (`webapp.py:6510`). The `/media_jobs` docstring states it plainly: *"The registry is
  per-process (see media_jobs.py), so this reflects jobs owned by the worker handling
  the request."* A job started on pod A and polled on pod B returns 404.
- **MCP relay sessions** — `webapp.py:2709` accepts the local daemon's WebSocket and
  calls `relay_registry.register_session(...)`. The graph's `mcp_discovery` node and the
  `/mcp/relay/{device_id}` bridge read that same in-process registry.

Everything else — chat, threads, conversations, avatar CRUD, the store — keeps its state
in PostgreSQL and is replica-safe.

> **Decision.** Split the API tier into **two Deployments from one image**, routed by ALB
> path rules: a freely scaling `anubis-api` and a deliberately single-replica
> `anubis-stateful` that owns the media and MCP paths. This buys real horizontal scale
> for chat today with zero change to the reference repos.

### 2.3 Rate limiting and metering are already replica-safe

`anubis/src/anubis/utils/billing/metering.py` computes the rolling rate-limit window with
SQL against the `api_metrics` table (`_ROLLING_WINDOW_USAGE_SQL`,
`token_rate_limit_retry_after_seconds`), not an in-memory token bucket, and fails open on
a database error. Nothing to change, and the limits stay correct across any replica count.

### 2.4 The container image is 12.8 GB

`Dockerfile.anubis.base` installs `ffmpeg-7`, `libsndfile`, `libgomp`, and `chromium` on
top of `langchain/langgraph-api:3.12-wolfi`, then the full dependency set (torch,
torchaudio, torchcodec, librosa, moviepy, playwright) and ~20 MB of NLTK corpora.
Measured: **12.8 GB**, against a 797 MB base.

> **Consequence.** A scale-out that must pull 12.8 GB from ECR takes minutes, which
> defeats the purpose of an HPA. Mitigated three ways in §6.

### 2.5 Cold-start downloads and bind mounts that do not exist on Kubernetes

`docker-compose-prod.yml` bind-mounts `.:/deps/anubis` plus the host's
`~/.cache/huggingface` and `~/.cache/nltk_data`. On EKS the image must be
self-contained. NLTK corpora are already baked into the base image. Hugging Face weights
are **not**: `ensure_huggingface_models_cached`
(`src/anubis/utils/huggingface_prefetch.py:21`) downloads the embedding model
(`microsoft/harrier-oss-v1-270m`) and the GoEmotions model during lifespan startup on
every cold pod. Solved with a shared EFS cache (§6).

### 2.6 pgvector is mandatory

`anubis/langgraph.json` pins the store index to
`huggingface:microsoft/harrier-oss-v1-270m` at **640 dims** over
`document.kwargs.page_content`, and the local database image is `pgvector/pgvector:pg16`.
RDS for PostgreSQL 16 with `CREATE EXTENSION vector` satisfies this; the extension is
created by `scripts/bootstrap-db.sh`.

### 2.7 Stripe provisioning is a start-up ordering constraint

`docker-compose-prod.yml:95` runs `scripts/provision_stripe_billing.py --live` as a
one-shot and blocks the API on `service_completed_successfully`, deliberately: *"Billing
correctness is worth more than that availability."* Preserved as a Helm
`pre-install,pre-upgrade` hook Job (§5.4).

### 2.8 Analysis workspaces are ephemeral

`data_analysis_workspace_root` defaults to `/tmp/anubis-analysis`
(`src/anubis/utils/context.py:494`) and is deleted at the end of each turn — an
`emptyDir` is sufficient, no shared filesystem needed.

---

## 3. Target architecture

```
                        Route 53  ·  neuralnexus.site
                        ACM certificate (DNS-validated)
                                     │
                    ┌────────────────┴─────────────────┐
                    │  Application Load Balancer       │
                    │  IngressGroup "anubis"           │
                    │  idle_timeout 3600s (SSE + WS)   │
                    │  HTTP → HTTPS redirect           │
                    └────────────────┬─────────────────┘
             api.neuralnexus.site    │    checkout-api.neuralnexus.site
        ┌───────────────┬────────────┘────────────────┬─────────────┐
        │ order 10      │ order 20                    │ order 30    │
        │ /update_avatar_identity_with_media          │ /*          │
        │ /media_jobs /media_job/* /mcp/*   /*        │             │
        ▼                            ▼                ▼
┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
│  anubis-stateful   │   │     anubis-api     │   │   portal-server    │
│  replicas 1        │   │  HPA 2 → 8         │   │  HPA 2 → 4         │
│  Recreate strategy │   │  RollingUpdate     │   │  RollingUpdate     │
│  media + MCP relay │   │  chat / CRUD / SSE │   │  Stripe + Auth0    │
│  2–4 vCPU, 8–16 Gi │   │  1–2 vCPU, 4–8 Gi  │   │  0.25 vCPU, 512 Mi │
│  nodegroup: media  │   │  nodegroup: general│   │  nodegroup: general│
│  (tainted)         │   │                    │   │                    │
└─────────┬──────────┘   └─────────┬──────────┘   └─────────┬──────────┘
          │  same image, same env  │                        │
          └───────────┬────────────┘                        │
                      ▼                                     ▼
   ┌──────────────────────────────────────────┐   Stripe · Auth0 · LLM
   │ RDS PostgreSQL 16, Multi-AZ, pgvector    │   providers (via NAT)
   │   assistants · threads · runs            │
   │   checkpoints · store (640-dim vectors)  │
   │   api_metrics (metering + rate limits)   │
   ├──────────────────────────────────────────┤
   │ ElastiCache Redis 7 — Agent Server pubsub│
   ├──────────────────────────────────────────┤
   │ EFS — shared Hugging Face weight cache   │
   └──────────────────────────────────────────┘

   Secrets Manager ──(External Secrets Operator)──▶ Kubernetes Secrets
   ECR (SOCI-indexed)  ·  S3 (Terraform state)  ·  CloudWatch Logs
```

### 3.1 Why two Deployments instead of one

| | `anubis-api` | `anubis-stateful` |
|---|---|---|
| Image | identical | identical |
| Env | identical (`anubis-env` Secret) | identical |
| Replicas | 2, HPA to 8 | **1**, no HPA |
| Update strategy | RollingUpdate, maxUnavailable 0 | **Recreate** |
| Node group | `general` | `media` (tainted `workload=media:NoSchedule`) |
| Grace period | 600 s (drain SSE) | 1800 s (drain a diarization batch) |
| Serves | `/message*`, `/conversations*`, avatar CRUD, Stripe webhook, `/metrics` | `/update_avatar_identity_with_media`, `/media_jobs`, `/media_job/*`, `/mcp/*` |

This turns §2.2 from *"the deployment cannot exceed one replica"* into *"one small,
deliberately single-replica pod holds the pod-local state; everything else scales
freely"* — without touching the reference repos. The media tier also gets its own
CPU-heavy node group, so a diarization batch can no longer starve live chat, which is
the specific failure mode of the current single host.

### 3.2 Known limitations of the split

Stated plainly rather than buried:

1. **MCP data-analysis across tiers.** A `/message` run needing the MCP relay executes on
   an `anubis-api` pod, which does not hold the daemon's WebSocket (that lives on
   `anubis-stateful`). Until [upstream change #3](../docs/upstream-changes.md) lands,
   either keep `DATA_ANALYSIS_ENABLED=false` on `anubis-api`, or add an ALB header rule
   routing MCP-enabled users' `/message` to `anubis-stateful`.
2. **In-flight media jobs are lost on an `anubis-stateful` restart.** Identical to today's
   behaviour on the single host — not a regression, but not yet fixed either. Fixed by
   [upstream change #2](../docs/upstream-changes.md).
3. **`/metrics` is per-pod.** Prometheus counters are process-local, so a scrape must
   aggregate across replicas rather than hitting one endpoint. See §8.

---

## 4. AWS resources

| Layer | Resource | Notes |
|---|---|---|
| Network | VPC, 3 AZs, public + private subnets | private subnets host all workloads |
| | 1 NAT Gateway (2 at medium scale) | LLM provider + Stripe + Auth0 + `beacon.langchain.com` egress |
| | VPC endpoints: ECR api/dkr, **S3 gateway**, Secrets Manager, CloudWatch Logs, STS | the S3 gateway endpoint keeps 12.8 GB image pulls off the NAT's per-GB meter |
| Compute | EKS 1.31, OIDC provider | |
| | node group `general` — `m7i.xlarge`, 150 GB gp3 | 2 → 6 nodes |
| | node group `media` — `m7i.2xlarge`, 200 GB gp3, tainted | 1 → 2 nodes |
| | Addons: EBS CSI, EFS CSI, metrics-server, AWS Load Balancer Controller, External Secrets Operator, cluster-autoscaler | |
| Data | RDS PostgreSQL 16, Multi-AZ, gp3, 7-day PITR, `rds.force_ssl=1` | pgvector extension |
| | ElastiCache Redis 7, encryption in transit + at rest | Agent Server pubsub only — no durable data |
| | EFS (ReadWriteMany) | Hugging Face weight cache |
| Images | ECR `anubis-langgraph-api`, `portal-server` | scan-on-push, SOCI index, keep last 10 |
| Secrets | Secrets Manager `anubis/prod/env`, `portal/prod/env` | one JSON blob per service, synced by ESO |
| Edge | ALB (single, shared by IngressGroup), ACM cert, Route 53 zone | |
| State | S3 bucket + DynamoDB lock table | Terraform backend |

Sizes and quantities: [resource-quantity-table.md](resource-quantity-table.md).
Prices: [cost-model.md](cost-model.md).

---

## 5. Kubernetes composition

### 5.1 `anubis-api` — LangChain's `langgraph-cloud` Helm chart

Chart: <https://github.com/langchain-ai/helm/tree/main/charts/langgraph-cloud>.
Values in [`helm/anubis-api/values-prod.yaml`](../helm/anubis-api/values-prod.yaml).
Key settings and why:

| Setting | Value | Reason |
|---|---|---|
| `queue.enabled` | `false` | §2.1 — nothing enqueues runs; workers would idle |
| `apiServer.autoscaling` | 2 → 8, 65 % CPU | the API tier is the compute tier |
| `postgres.external.enabled` | `true` | RDS, not an in-cluster StatefulSet |
| `redis.external.enabled` | `true` | ElastiCache |
| `ingress.enabled` | `false` | one shared ALB, defined in `helm/platform` |
| probes | `exec: python /api/healthcheck.py` | same check `docker-compose-prod.yml:44` uses |
| `terminationGracePeriodSeconds` | 600 + preStop sleep 15 | in-flight SSE streams drain |

### 5.2 `anubis-stateful` — local chart, same image

A thin Deployment/Service chart. `replicas: 1`, `strategy: Recreate`, toleration for
`workload=media`, 1800 s grace period. Installed **after** `anubis-api` so the Agent
Server's schema migrations run once, from one release.

### 5.3 `portal-server` — local chart

`anubis-customer-portal/src/server` built to ECR and run as 2 replicas behind the same
ALB on `checkout-api.neuralnexus.site`. Probe: `GET /healthz`
(`src/server/main.py:91`), which returns `{"ok": true, "environment": "live"}` — the
`environment` field is the check that matters, because a 200 alone does not prove which
Stripe account is behind it.

### 5.4 `stripe-provision` — its own release, installed before `anubis-api`

`helm/stripe-provision` renders a `pre-install,pre-upgrade` hook Job running
`python scripts/provision_stripe_billing.py --live` with `PYTHONPATH=/deps/anubis`,
mirroring `docker-compose-prod.yml:95-111`. It is a separate release rather than a hook
inside `anubis-api` because that release uses LangChain's upstream chart, which this repo
does not fork. Installing it first preserves Compose's ordering guarantee: a failure here
aborts the deploy before any API pod starts.

The script is idempotent; every deploy performs writes against the **live** Stripe
account, which is safe by idempotency, not by omission.

**One deliberate difference from Compose.** Compose passes the resulting
`billing_config.json` through a shared Docker volume. Pods cannot share a volume that
way, so the Job merges the JSON into the `anubis/prod/env` Secrets Manager secret under
`STRIPE_BILLING_CONFIG_JSON`; External Secrets Operator refreshes the Kubernetes Secret,
and every pod reads it from the environment. `STRIPE_BILLING_CONFIG_FILE` is left unset
on Kubernetes so it cannot shadow the value.

The Job runs in three stages across two images, because the Anubis image is a wolfi
Python base with no `aws` CLI and the `aws-cli` image has no application code: read the
secret (`aws-cli`), provision and merge (Anubis image, stdlib `json`), write it back
(`aws-cli`). The shared volume is `emptyDir: { medium: Memory }`, so the secret never
touches disk. Recorded in the [runbook](../docs/runbook.md) §4.

### 5.5 ALB configuration

```yaml
alb.ingress.kubernetes.io/group.name: anubis
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
alb.ingress.kubernetes.io/target-group-attributes: >-
  stickiness.enabled=true,stickiness.type=lb_cookie,
  stickiness.lb_cookie.duration_seconds=86400,
  deregistration_delay.timeout_seconds=300
alb.ingress.kubernetes.io/ssl-redirect: "443"
```

The **3600 s idle timeout** is not optional: `/message` SSE streams and the `/mcp/relay`
WebSocket both outlive the 60 s default. `nginx.conf:34` uses the same value today for
exactly this reason. Stickiness keeps a browser session pinned to one `anubis-api` pod,
which is harmless for chat and useful if the media routes are ever consolidated.

---

## 6. Making a 12.8 GB image schedulable

Three mitigations, all in this repo:

1. **SOCI lazy loading.** ECR generates a SOCI index on push; nodes run the
   `soci-snapshotter`. Pods start on the layers they need instead of the whole 12.8 GB.
2. **Pre-pull DaemonSet** pinned to the currently deployed tag, so a newly scaled-up node
   already holds the image before the scheduler places a real pod on it.
3. **Conservative HPA scale-up** — `stabilizationWindowSeconds: 120` and `minReplicas: 2`,
   so scale-out is rare rather than fast, and a pod is never the critical path for a
   request already in flight.

The real fix is splitting the image into a slim API variant and a fat media variant via
pyproject extras — an upstream change, tracked as
[#4](../docs/upstream-changes.md).

**Hugging Face weights** (§2.5) live on an EFS `ReadWriteMany` PVC mounted at
`/root/.cache/huggingface`, warmed once by `scripts/warm-hf-cache.sh`. A few dollars a
month, and it removes minutes from every cold pod with no upstream change. Baking the
weights into `Dockerfile.anubis.base` is strictly better and is upstream change
[#5](../docs/upstream-changes.md).

---

## 7. Licensing — confirm before the first deploy

Per [deploy-standalone-server](https://docs.langchain.com/langsmith/deploy-standalone-server),
a standalone Agent Server needs:

- `LANGSMITH_API_KEY`, and
- `LANGGRAPH_CLOUD_LICENSE_KEY` — verified **once at server start-up** against
  `https://beacon.langchain.com`, so pods need egress there (allowed via NAT).

The infrastructure is identical either way, but a missing or unentitled license key means
the pods will not start. Confirm what the current LangSmith plan entitles before
`terraform apply`. Both values are carried in the `anubis/prod/env` secret.

---

## 8. Observability

Out of scope for this milestone, but the seams are left in place:

- The Agent Server already exposes Prometheus metrics at `/metrics`
  (`webapp.py:1336`), and `anubis/prometheus.yml` + `anubis/grafana/provisioning/` show
  what the current dashboards expect.
- EKS control-plane logs and container logs go to CloudWatch Logs via the cluster's log
  configuration.
- When the dashboards are ported, the intended landing spot is **Amazon Managed Service
  for Prometheus** + **Amazon Managed Grafana**, scraping both Deployments by pod (not
  through the ALB), because `/metrics` counters are per-process (§3.2).

---

## 9. Migration sequence

1. `terraform apply` — network, EKS, RDS, ElastiCache, ECR, EFS, Secrets Manager,
   Route 53/ACM. Nothing user-facing changes.
2. Bootstrap the database: `CREATE EXTENSION vector`, then restore a dump of the current
   pgvector container into RDS.
3. Push both images to ECR; warm the EFS Hugging Face cache.
4. `helm upgrade --install` the four releases. Verify against the ALB hostname directly,
   before any DNS change.
5. Cut DNS per [dns-cutover.md](../docs/dns-cutover.md).
6. Only then stop the host `cloudflared` service and the Compose stacks — with the
   documented rollback (restart both) still available.

Full verification steps: [runbook.md](../docs/runbook.md).

---

## 10. References

- [Agent Server](https://docs.langchain.com/langsmith/agent-server) — parts of a
  deployment, container architecture, run lifecycle
- [Control plane](https://docs.langchain.com/langsmith/control-plane) — what the managed
  option provides, and therefore what this standalone design owns instead
- [Self-host standalone servers](https://docs.langchain.com/langsmith/deploy-standalone-server)
- [Configure Agent Server for scale](https://docs.langchain.com/langsmith/agent-server-scale)
- [Self-hosted LangSmith on AWS](https://docs.langchain.com/langsmith/aws-self-hosted)
- [`langgraph-cloud` Helm chart](https://github.com/langchain-ai/helm/tree/main/charts/langgraph-cloud)
