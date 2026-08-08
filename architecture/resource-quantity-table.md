# Resource Quantity Table

Sizing for the two deployment points named in
[scalable_architecture.md](scalable_architecture.md): **Launch** (deploy this now) and
**Medium** (the next step up, reachable by changing values, not architecture).

Load definitions follow LangChain's
[Agent Server scale guide](https://docs.langchain.com/langsmith/agent-server-scale):
low ≈ 5 requests/second, medium ≈ 50 requests/second.

> **Deviation from LangChain's reference table, and why.** Their table sizes run
> execution onto queue workers. Anubis executes graphs inside the API process
> (`webapp.py:900, 3563, 3834` — see architecture §2.1), so CPU and memory that their
> table assigns to queue workers is assigned to the API tier here, and queue workers are
> disabled at launch.

---

## 1. Kubernetes workloads

| Workload | | Launch | Medium |
|---|---|---|---|
| **`anubis-api`** | replicas | 2 | 4 |
| | HPA min / max | 2 / 8 | 4 / 12 |
| | HPA target CPU | 65 % | 65 % |
| | requests | 1 vCPU / 4 Gi | 2 vCPU / 8 Gi |
| | limits | 2 vCPU / 8 Gi | 4 vCPU / 12 Gi |
| | node group | `general` | `general` |
| | grace period | 600 s | 600 s |
| **`anubis-stateful`** | replicas | 1 (fixed) | 1 (fixed) |
| | requests | 2 vCPU / 8 Gi | 4 vCPU / 16 Gi |
| | limits | 4 vCPU / 16 Gi | 6 vCPU / 24 Gi |
| | node group | `media` (tainted) | `media` (tainted) |
| | grace period | 1800 s | 1800 s |
| **queue workers** | replicas | **0 — disabled** | 3–5 (after upstream #1) |
| | `N_JOBS_PER_WORKER` | n/a | 10 |
| | requests | n/a | 1 vCPU / 2 Gi |
| **`portal-server`** | replicas | 2 | 3 |
| | HPA min / max | 2 / 4 | 3 / 6 |
| | requests | 0.25 vCPU / 512 Mi | 0.5 vCPU / 1 Gi |
| | limits | 0.5 vCPU / 1 Gi | 1 vCPU / 2 Gi |
| **`hf-cache-prepull`** (DaemonSet) | — | 1 per node, 10 m CPU / 32 Mi | same |

**`anubis-api` memory floor.** Each pod loads the 640-dim embedding model and the
GoEmotions classifier (`huggingface_prefetch.py:21`) plus the torch runtime. 4 Gi is the
request, not the ceiling; the 8 Gi limit is the guard against a large context blowing the
pod. Do not drop the request below 4 Gi — the pod will OOM during model load, not during
traffic, which is a confusing failure.

**Why `anubis-stateful` is CPU-heavy.** Audio preprocessing (`noisereduce` spectral
gating, `librosa`, `soundfile`, `moviepy` video demux) and PDF/document extraction are
CPU-bound and run at `MEDIA_PROCESSING_CONCURRENCY` in parallel per batch. Transcription
and diarization themselves are OpenAI API calls, so no GPU is needed anywhere in this
architecture.

---

## 2. EKS node groups

| | | Launch | Medium |
|---|---|---|---|
| **`general`** | instance type | `m7i.xlarge` (4 vCPU / 16 GiB) | `m7i.2xlarge` (8 vCPU / 32 GiB) |
| | desired / min / max | 2 / 2 / 6 | 3 / 3 / 8 |
| | root volume | 150 GB gp3 | 150 GB gp3 |
| | AZs | 3 | 3 |
| **`media`** | instance type | `m7i.2xlarge` (8 vCPU / 32 GiB) | `m7i.2xlarge` |
| | desired / min / max | 1 / 1 / 2 | 2 / 1 / 3 |
| | root volume | 200 GB gp3 | 200 GB gp3 |
| | taint | `workload=media:NoSchedule` | same |

**Architecture: `x86_64` only.** The image installs x86 PyTorch/torchcodec wheels and the
wolfi `chromium` apk. Graviton (`m7g`) instance types will not run it. RDS and
ElastiCache *are* Graviton (`m7g`, `t4g`) — those are managed services and unaffected.

**Root volume sizing.** The image is 12.8 GB; with two tags cached during a rolling
deploy, plus the base OS and ephemeral layers, 150 GB is the floor for `general`. The
`media` nodes get 200 GB because media batches write large temporary audio files under
`/tmp`.

---

## 3. Managed data services

| | | Launch | Medium |
|---|---|---|---|
| **RDS PostgreSQL 16** | instance class | `db.m7g.large` (2 vCPU / 8 GiB) | `db.m7g.xlarge` (4 vCPU / 16 GiB) |
| | storage | 100 GB gp3 | 300 GB gp3 |
| | Multi-AZ | **yes** | yes |
| | backup retention | 7 days | 14 days |
| | `max_connections` | default (~680) | default |
| | extensions | `vector` | `vector` |
| **ElastiCache Redis 7** | node type | `cache.t4g.medium` (2 vCPU / 3.09 GiB) | `cache.m7g.large` (2 vCPU / 6.38 GiB) |
| | nodes | 1 primary + 1 replica | 1 primary + 1 replica |
| | Multi-AZ failover | yes | yes |
| **EFS** | mode | Elastic throughput, General Purpose | same |
| | expected size | < 5 GB (model weights) | < 5 GB |

**Multi-AZ RDS at launch is deliberate.** The store *is* the product — every avatar's
identity documents, memories, quotes, and conversation checkpoints. Its current home is a
container on one local disk. Multi-AZ costs ~$70/month more than single-AZ and is the
single highest-value line item in the whole budget.

**Do not oversize Redis.** LangChain's own reference configuration keeps Redis at 2 GiB
even at 500 req/s, because the Agent Server stores only ephemeral pubsub and cancellation
data there — no user or run data. `cache.t4g.medium` has headroom at both scale points.

**Connection budget.** At medium scale: 12 `anubis-api` pods × the Agent Server pool
(`LANGGRAPH_POSTGRES_POOL_MAX_SIZE`, default 20) + the app's own
`AsyncPostgresSaver` pool ≈ 300–400 connections. Comfortably inside a `db.m7g.xlarge`,
but this is the number to watch first when adding replicas — raise the instance class
before raising `maxReplicas` past 12.

---

## 4. Edge, registry, and supporting resources

| Resource | Launch | Medium |
|---|---|---|
| Application Load Balancer | 1 (shared via IngressGroup) | 1 |
| ACM certificates | 1 (SANs: `api.`, `checkout-api.`) | 1 |
| Route 53 hosted zone | 1 | 1 |
| NAT Gateways | 1 | 2 (one per AZ) |
| VPC interface endpoints | ECR api, ECR dkr, Secrets Manager, CloudWatch Logs, STS | same |
| VPC gateway endpoints | S3 | S3 |
| ECR repositories | 2 (`anubis-langgraph-api`, `portal-server`) | 2 |
| ECR retained images | last 10 tagged (~130 GB) | last 10 |
| Secrets Manager secrets | 2 | 2 |
| S3 buckets | 1 (Terraform state, versioned) | 1 |
| DynamoDB tables | 1 (state lock) | 1 |

---

## 5. Throughput math

For when the queue is enabled (Phase 2), from the
[scale guide](https://docs.langchain.com/langsmith/agent-server-scale):

```
available_jobs        = number_of_queue_workers × N_JOBS_PER_WORKER
throughput_per_second = available_jobs / average_run_execution_time_seconds
```

Anubis's average `/message` run is **2–20 s** today (`features/response_latency.md`
targets < 1 s). Taking a pessimistic 10 s average and a target of 5 runs/second:

```
number_of_queue_workers = 5 × 10 / 10 = 5 workers
```

which is where the "3–5 queue workers at medium scale" figure in §1 comes from.

**Until then, the same math applies to the API tier**, because that is where runs
execute. With 4 pods at 2 vCPU and an I/O-bound workload (the graph spends most of its
time awaiting LLM responses), concurrency is bounded by the event loop and Postgres
connections rather than CPU — which is why the HPA targets 65 % CPU and why the
connection budget in §3 is the real ceiling.

---

## 6. What to change to go from Launch to Medium

Values only — no manifests, no Terraform module changes:

| File | Change |
|---|---|
| `terraform/envs/prod/terraform.tfvars` | `general_instance_type`, `general_desired_size`, `media_desired_size`, `rds_instance_class`, `rds_allocated_storage`, `redis_node_type`, `nat_gateway_count` |
| `helm/anubis-api/values-prod.yaml` | `apiServer.deployment.replicaCount`, `resources`, `autoscaling.{min,max}Replicas` |
| `helm/anubis-stateful/values-prod.yaml` | `resources` |
| `helm/portal-server/values-prod.yaml` | `replicaCount`, `autoscaling` |

Enabling queue workers is **not** a values change — it depends on
[upstream change #1](../docs/upstream-changes.md#1-move-message-onto-the-task-queue).
