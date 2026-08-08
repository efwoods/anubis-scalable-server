# Helm releases

Four releases in namespace `anubis`, installed in this order. The ordering is load-bearing
twice: `stripe-provision` must succeed before any API pod starts, and `anubis-api` runs
the Agent Server schema migrations that `anubis-stateful` depends on.

| # | Release | Chart | What it is |
|---|---|---|---|
| 0 | `platform` | `./platform` | ClusterSecretStore + ExternalSecrets, the shared ALB Ingresses, the EFS model-cache PV/PVC, the image pre-pull DaemonSet |
| 1 | `stripe-provision` | `./stripe-provision` | hook Job that provisions Stripe billing and publishes the config to Secrets Manager |
| 2 | `anubis-api` | `langchain/langgraph-cloud` (upstream) | the chat / CRUD tier, HPA 2 → 8 |
| 3 | `anubis-stateful` | `./anubis-stateful` | the single-replica media + MCP tier, same image |
| 4 | `portal-server` | `./portal-server` | the customer portal backend-for-frontend |

Full commands: [`../docs/runbook.md`](../docs/runbook.md) §1.7. The deploy workflow
(`.github/workflows/deploy.yml`) runs the same sequence with Terraform outputs filled in.

---

## Prerequisites installed outside these charts

Three controllers are cluster-level dependencies. Terraform creates their IRSA roles;
installing the controllers themselves is a one-time step:

```bash
REGION=us-east-2
CLUSTER=$(terraform -chdir=../terraform/envs/prod output -raw cluster_name)

# AWS Load Balancer Controller — provisions the shared ALB from the Ingress objects
helm repo add eks https://aws.github.io/eks-charts
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform -chdir=../terraform/envs/prod output -raw load_balancer_controller_role_arn)"

# External Secrets Operator — projects Secrets Manager into Kubernetes Secrets
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set serviceAccount.name=external-secrets \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform -chdir=../terraform/envs/prod output -raw external_secrets_role_arn)"

# cluster-autoscaler — adds nodes when pods go Pending
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER" \
  --set awsRegion="$REGION" \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set-string rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform -chdir=../terraform/envs/prod output -raw cluster_autoscaler_role_arn)"
```

`metrics-server` is required for the HPAs. EKS ships it as a managed addon on recent
versions; if `kubectl top nodes` fails, install it explicitly.

---

## Why `anubis-api` and `anubis-stateful` run the same image

Not redundancy — a deliberate split, because two registries inside the FastAPI process are
per-pod and invisible to every other replica:

- `app.state.media_jobs` (`webapp.py:1270`, dispatched at `:6510`)
- the MCP relay WebSocket registry (`webapp.py:2709`)

`anubis-stateful` is pinned to one replica and owns exactly the routes that touch them;
everything else scales freely on `anubis-api`. The `platform` chart's Ingress
`group.order` values are what enforce the routing. Full reasoning:
[`../architecture/scalable_architecture.md`](../architecture/scalable_architecture.md) §2.2
and §3.1; the fix that retires the split is
[`../docs/upstream-changes.md`](../docs/upstream-changes.md) #2 and #3.

The `anubis-stateful` chart **refuses to render** with `replicaCount != 1`. That guard is
there because the failure it prevents — `/media_job/{id}` returning 404 for a job that is
running fine on another pod — looks like data loss rather than a routing bug.

---

## Values files

Each chart ships `values.yaml` (documented defaults) and `values-prod.yaml` (the launch
configuration). Empty strings in `values-prod.yaml` are filled from Terraform outputs at
deploy time; every one is annotated with the command that produces it.

To move from launch to medium scale, change only the values marked `MEDIUM` — see
[`../architecture/resource-quantity-table.md`](../architecture/resource-quantity-table.md) §6.

---

## Verifying a change before applying it

```bash
helm lint ./platform -f ./platform/values-prod.yaml

helm template platform ./platform -f ./platform/values-prod.yaml -n anubis \
  --set ingress.certificateArn=arn:test \
  --set modelCache.fileSystemId=fs-1 --set modelCache.accessPointId=fsap-1 \
  --set prePull.image=repo --set prePull.tag=abc123

# Against the live cluster, without applying:
helm upgrade anubis-api langchain/langgraph-cloud \
  -f ./anubis-api/values-prod.yaml --dry-run --debug -n anubis
```

The two checks worth making by eye on any Ingress change:

1. `group.order` still puts the four stateful prefixes (10) ahead of the catch-all (20).
2. `idle_timeout.timeout_seconds` is still **3600** — the default 60 s cuts `/message`
   SSE streams and the `/mcp/relay` WebSocket.
