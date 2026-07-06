# Anubis Scalable Cloud Server — Cost & Code Report

**Goal:** Deploy the [Anubis API](https://github.com/efwoods/anubis) as a horizontally scalable
LangGraph Agent Server on Azure, backed by PostgreSQL and Redis, with **API servers and queue
workers as separate, independently-scaling container pools** (per `architecture/infrastructure_scalable.png`).

This report defines (1) how the diagram maps to real components, (2) the resources required, (3) the
Azure cost at three sizes, and (4) the concrete Terraform + Helm + Kubernetes code to build it.

> Pricing below is East US pay-as-you-go (PAYG), gathered July 2026. Treat every figure as an
> **estimate to confirm on the linked Azure pricing pages** — SKU prices change by region and over time.
> LLM inference (OpenAI / Together / NVIDIA) is a **separate, usage-driven cost** and is called out at the end.

---

## 1. Architecture → LangGraph Agent Server mapping

The diagram is exactly the [LangGraph Agent Server](https://docs.langchain.com/langsmith/agent-server)
"split API + queue" runtime. Each box maps to a real, deployable component:

| Diagram box | LangGraph component | What it does | Scales on |
|---|---|---|---|
| **API Servers** | `langgraph-api` in *API mode* | Accepts `POST /message`, creates runs, streams SSE back to the client. Does **not** execute graph code. | HTTP request volume (CPU) |
| **Queue Loop → Workers** | `langgraph-api` in *queue mode* | Claims pending runs from Postgres (with a lease), runs the `Anubis` graph, writes checkpoints. `N_JOBS_PER_WORKER` (default 10) concurrent runs per worker. | Pending-run backlog |
| **Redis** | Pub/sub broker | Signaling, run cancellation, and streaming events from workers back to API servers. **Ephemeral only** — no user/run data persists here. | Rarely; small instance |
| **Postgres** | Durable store | Assistants, threads, runs, cron, **checkpoints**, and long-term memory (the `memory`/`identity`/`quote` store namespaces + pgvector). Also holds the task-queue state. | Storage + connection load |

Flow (matches the arrows): `User → API Server` creates a run row in Postgres (`create run`), API
`notify`s Redis; an idle worker is `wake`d, `claim next run` from Postgres, executes, `publish events`
to Redis which the API `stream`s to the user as SSE, and the worker `save checkpoints / update status`
back to Postgres.

**Why the split matters for Anubis:** inference and media preprocessing (audio transcription/diarization,
video → frames) are long-running and CPU/GPU-heavy. Keeping them in the **queue pool** means a burst of
uploads never starves the **API pool** that must stay responsive for SSE chat streaming. They scale on
independent signals.

### Licensing — this decides your cost floor

LangGraph Platform's self-hosted runtime has two relevant tiers
([deployment options](https://langchain-ai.github.io/langgraph/concepts/langgraph_standalone_container/),
[pricing](https://www.langchain.com/pricing)):

- **Self-Hosted Lite — free**, capped at **1 million nodes executed per year**. Needs a free
  `LANGSMITH_API_KEY`. Every graph node counts; an Anubis turn runs several nodes
  (`load_consciousness → think → process_thoughts …`), so ~1M nodes ≈ tens of thousands of
  conversations/year. Fine for launch/beta.
- **Enterprise license** (`LANGGRAPH_CLOUD_LICENSE_KEY`) — removes the node cap and unlocks the
  self-hosted **data plane** (control-plane SaaS + your VPC), custom autoscaling, HA support. Custom
  pricing (contact sales). Required once you exceed the Lite cap or want the managed control plane.

The infrastructure code below is **identical** for both tiers — only the license secret changes.

---

## 2. Resource quantity table

| Resource | Dev / Lite | Staging | Production (HA) |
|---|---|---|---|
| AKS cluster (control plane) | Free tier | Standard tier | Standard tier + Availability Zones |
| API-server node pool | 1× D4s_v5 (4 vCPU/16 GB) | 2× D4s_v5 | 3–6× D8s_v5 (8 vCPU/32 GB), HPA |
| Queue-worker node pool | shares above | 1–3× D4s_v5, HPA | 3–10× D8s_v5, HPA/KEDA |
| API server replicas | 1 | 2 | 3 → 8 (autoscale) |
| Queue worker replicas | 1 | 2 | 3 → 10 (autoscale) |
| PostgreSQL (Flexible Server) | Burstable B1ms (1 vCPU/2 GB) | GP D2ds_v5 (2 vCore/8 GB) | GP D4ds_v5 (4 vCore/16 GB) + zone-redundant HA |
| Postgres storage | 32 GB | 128 GB | 256 GB + backups |
| Redis | Managed Redis Balanced B0 (1 GB) | Balanced B1 (~1.5 GB) | Balanced B3 (~3 GB) |
| Container registry | ACR Basic | ACR Standard | ACR Standard |
| Ingress | Azure LoadBalancer | LoadBalancer | LoadBalancer + WAF (App Gateway optional) |

pgvector note: the store's vector index embeds at **640 dims** with `microsoft/harrier-oss-v1-270m`
(see `langgraph.json`). The embedding model runs **inside the workers**, so worker memory (≥16 GB)
matters more than Postgres compute; Postgres just stores vectors + does ANN search.

---

## 3. Cost breakdown (Azure, East US, PAYG monthly)

Unit prices used (confirm on the linked pages):

- AKS control plane: **Free = $0**; **Standard = $0.10/cluster/hr ≈ $73/mo** ([AKS pricing](https://azure.microsoft.com/en-us/pricing/details/kubernetes-service/))
- VM nodes: **D4s_v5 = $0.192/hr ≈ $140/mo**; **D8s_v5 = $0.384/hr ≈ $280/mo** ([Vantage D4s_v5](https://instances.vantage.sh/azure/vm/d4s-v5))
- Postgres Flexible Server ([pricing](https://azure.microsoft.com/en-us/pricing/details/postgresql/flexible-server/)): Burstable **B1ms ≈ $25/mo**; GP **D2ds_v5 ≈ $130/mo**; GP **D4ds_v5 ≈ $260/mo** compute (HA doubles compute)
- Managed Redis Balanced ([pricing](https://azure.microsoft.com/en-us/pricing/details/managed-redis/)): **B0 ≈ $13/mo**, **B1 ≈ $50/mo**, **B3 ≈ $160/mo**
- ACR: Basic ≈ $5/mo, Standard ≈ $20/mo · LoadBalancer + egress ≈ $25–100/mo

### Dev / Lite — **≈ $190/mo**
| Item | Cost |
|---|---|
| AKS control plane (Free) | $0 |
| 1× D4s_v5 node | $140 |
| Postgres B1ms + 32 GB | $30 |
| Redis Balanced B0 | $13 |
| ACR Basic + LB | $10 |
| **Total** | **≈ $193/mo** |

### Staging — **≈ $560/mo**
| Item | Cost |
|---|---|
| AKS Standard control plane | $73 |
| 3× D4s_v5 nodes (API+queue) | $420 |
| Postgres GP D2ds_v5 + 128 GB | $145 |
| Redis Balanced B1 | $50 |
| ACR Standard + LB | $45 |
| **Total** | **≈ $733/mo** |

### Production (HA, baseline before autoscale) — **≈ $1,900/mo**
| Item | Cost |
|---|---|
| AKS Standard + AZ | $73 |
| 3× D8s_v5 baseline (scales to 10) | $840 (→ up to ~$2,800 at peak) |
| Postgres GP D4ds_v5 **+ zone-redundant HA** | $520 |
| Postgres storage + backups (256 GB) | $60 |
| Redis Balanced B3 | $160 |
| ACR Standard + LB + egress | $80 |
| **Baseline total** | **≈ $1,733/mo** (autoscale peaks higher) |

**Levers to cut cost:** Azure **Reserved Instances / savings plans** (up to ~40–60% on nodes & Postgres),
**spot node pool** for stateless queue workers (interruptible — fine because runs are checkpointed and
re-claimed), Postgres reserved capacity, and scaling the queue pool to **zero** off-peak via KEDA.

### The real variable cost: LLM inference
Infra above is **fixed capacity**. Per-conversation cost is dominated by model API calls
(`MODEL_PROVIDER` = OpenAI/Together/NVIDIA) plus Whisper/`gpt-4o-transcribe-diarize` for media. Budget
this separately and meter it (see the token-usage/Stripe-metering roadmap items). At scale this typically
**exceeds the Kubernetes bill**.

---

## 4. Code to build it

Three layers: **(A) Terraform** provisions Azure (AKS + Postgres + Redis + ACR). **(B)** `langgraph build`
produces the server image. **(C) Helm** deploys the split API/queue pools with autoscaling.

### A. Terraform — Azure infrastructure

`infra/terraform/main.tf`:

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}
provider "azurerm" { features {} }

variable "prefix"   { default = "anubis" }
variable "location" { default = "eastus" }

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# --- AKS: system pool + separately-scaling API and queue pools ---
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.prefix}-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.prefix
  sku_tier            = "Standard"            # "Free" for dev/lite

  default_node_pool {
    name       = "system"
    vm_size    = "Standard_D4s_v5"
    node_count = 1
  }
  identity { type = "SystemAssigned" }
}

resource "azurerm_kubernetes_cluster_node_pool" "api" {
  name                  = "api"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_D8s_v5"
  auto_scaling_enabled  = true
  min_count             = 3
  max_count             = 8
  node_labels           = { pool = "api" }
}

resource "azurerm_kubernetes_cluster_node_pool" "queue" {
  name                  = "queue"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_D8s_v5"
  auto_scaling_enabled  = true
  min_count             = 3
  max_count             = 10
  # priority = "Spot"  # optional: cheap, interruptible workers (runs are checkpointed)
  node_labels           = { pool = "queue" }
}

# --- PostgreSQL Flexible Server (v16, HA) ---
resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "${var.prefix}-pg"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "16"
  sku_name                      = "GP_Standard_D4ds_v5"   # B_Standard_B1ms for dev
  storage_mb                    = 262144                  # 256 GB
  auto_grow_enabled             = true
  administrator_login           = "anubis"
  administrator_password        = var.pg_password          # from a secret / tfvars
  high_availability { mode = "ZoneRedundant" }             # omit for dev
  public_network_access_enabled = false
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = "anubis"
  server_id = azurerm_postgresql_flexible_server.pg.id
}

# pgvector must be allowlisted before CREATE EXTENSION
resource "azurerm_postgresql_flexible_server_configuration" "vector" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "VECTOR"
}

# --- Azure Managed Redis (pub/sub broker; ephemeral) ---
resource "azurerm_redis_enterprise_cluster" "redis" {
  name                = "${var.prefix}-redis"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "Balanced_B3"        # Balanced_B0 for dev
}

resource "azurerm_redis_enterprise_database" "redisdb" {
  name       = "default"
  cluster_id = azurerm_redis_enterprise_cluster.redis.id
  clustering_policy = "EnterpriseCluster"
}

# --- Container registry ---
resource "azurerm_container_registry" "acr" {
  name                = "${var.prefix}acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
}
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}
```

> `azurerm_redis_enterprise_*` is the Managed Redis family. For the cheaper classic
> **Azure Cache for Redis**, use `azurerm_redis_cache` (`sku_name = "Standard"`, `capacity = 1`).

### B. Build the Anubis server image

The Anubis repo already has `langgraph.json` and a Dockerfile. Produce the platform image and push to ACR:

```bash
# from the anubis repo root
langgraph build -t anubisacr.azurecr.io/anubis-langgraph-api:latest
az acr login --name anubisacr
docker push anubisacr.azurecr.io/anubis-langgraph-api:latest
```

`langgraph build` wraps `langgraph.json` into a server image that starts in API or queue mode via env
(`SERVER_MODE`) — the same image runs both pools.

### C. Helm — deploy split API + queue pools

Uses the official [`langgraph-cloud` Helm chart](https://github.com/langchain-ai/helm). Key idea: **one
chart install, two independently-autoscaling deployments** (`apiServer` and `queue`), external Postgres +
Redis, license via secret.

`deploy/values.yaml`:

```yaml
images:
  apiServerImage:
    repository: anubisacr.azurecr.io/anubis-langgraph-api
    tag: latest

config:
  # Lite (free): set apiKey to a LangSmith key, leave license empty.
  # Enterprise: set langGraphCloudLicenseKey.
  existingSecretName: anubis-secrets   # holds LANGSMITH_API_KEY, LANGGRAPH_CLOUD_LICENSE_KEY,
                                        # DATABASE_URI, REDIS_URI, model provider keys

postgres:
  external:
    enabled: true
    connectionUrl: "postgresql://anubis:PASSWORD@anubis-pg.postgres.database.azure.com:5432/anubis?sslmode=require"

redis:
  external:
    enabled: true
    connectionUrl: "rediss://:PASSWORD@anubis-redis.eastus.redisenterprise.cache.azure.net:10000/0"

apiServer:
  deployment:
    replicaCount: 3
    resources:
      requests: { cpu: "1000m", memory: "2Gi" }
      limits:   { cpu: "2000m", memory: "4Gi" }
    nodeSelector: { pool: api }
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 8
    targetCPUUtilizationPercentage: 70
  service:
    type: LoadBalancer

queue:
  deployment:
    replicaCount: 3
    resources:
      requests: { cpu: "2000m", memory: "8Gi" }   # embeddings + media preprocessing live here
      limits:   { cpu: "4000m", memory: "16Gi" }
    nodeSelector: { pool: queue }
    extraEnv:
      - { name: N_JOBS_PER_WORKER, value: "10" }
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 10
```

Secret + install:

```bash
kubectl create secret generic anubis-secrets \
  --from-literal=LANGSMITH_API_KEY="$LANGSMITH_API_KEY" \
  --from-literal=LANGGRAPH_CLOUD_LICENSE_KEY="$LANGGRAPH_CLOUD_LICENSE_KEY" \
  --from-literal=DATABASE_URI="$DATABASE_URI" \
  --from-literal=REDIS_URI="$REDIS_URI" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY"

helm repo add langchain https://langchain-ai.github.io/helm/
helm install anubis langchain/langgraph-cloud -f deploy/values.yaml
```

### Optional — scale the queue on *backlog*, not CPU (KEDA)

CPU-based HPA reacts late for bursty upload jobs. [KEDA](https://keda.sh) can scale the queue pool
(even to zero off-peak) on the count of pending runs in Postgres:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: anubis-queue-scaler }
spec:
  scaleTargetRef: { name: anubis-queue }
  minReplicaCount: 1
  maxReplicaCount: 12
  triggers:
    - type: postgresql
      metadata:
        connectionFromEnv: DATABASE_URI
        query: "SELECT count(*) FROM run WHERE status = 'pending';"
        targetQueryValue: "10"   # ~1 replica per 10 pending runs
```

---

## 5. Recommended build order

1. **Terraform apply** the Dev/Lite tier (Free AKS, B1ms Postgres, Redis B0) — proves the wiring for ~$190/mo.
2. **`langgraph build` + push** the Anubis image to ACR; run `CREATE EXTENSION vector;` on Postgres.
3. **Helm install** with a single node pool, Lite license (free `LANGSMITH_API_KEY`).
4. **Split the pools** (`api` + `queue` node pools, nodeSelectors) and enable HPA — validates independent scaling.
5. **Add KEDA** backlog scaling for the queue; load-test uploads vs chat separately.
6. **Promote to Production**: Standard AKS + AZ, GP Postgres with zone-redundant HA, Redis B3, Reserved
   Instances, spot queue nodes. Switch to an **Enterprise license** when you approach the 1M-node/yr Lite cap.
7. **Meter LLM spend** (token-usage + Stripe metering roadmap items) — it, not Kubernetes, sets unit economics.

---

## Sources

- LangGraph Agent Server architecture — https://docs.langchain.com/langsmith/agent-server
- Control plane / data plane — https://docs.langchain.com/langsmith/control-plane
- Self-host standalone server — https://docs.langchain.com/langsmith/deploy-standalone-server
- Standalone Container concept & Lite 1M-node cap — https://langchain-ai.github.io/langgraph/concepts/langgraph_standalone_container/
- LangGraph Helm chart — https://github.com/langchain-ai/helm
- LangChain pricing (Lite vs Enterprise) — https://www.langchain.com/pricing
- AKS pricing — https://azure.microsoft.com/en-us/pricing/details/kubernetes-service/
- Azure VM D4s_v5 / D8s_v5 — https://instances.vantage.sh/azure/vm/d4s-v5
- Postgres Flexible Server pricing — https://azure.microsoft.com/en-us/pricing/details/postgresql/flexible-server/
- Azure Managed Redis pricing — https://azure.microsoft.com/en-us/pricing/details/managed-redis/
