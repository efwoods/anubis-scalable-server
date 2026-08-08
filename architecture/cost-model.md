# Cost Model

Monthly AWS cost for the architecture in [scalable_architecture.md](scalable_architecture.md),
at the two sizing points in [resource-quantity-table.md](resource-quantity-table.md).

- **Region:** `us-east-2` (Ohio)
- **Basis:** on-demand list prices, 730 hours/month, as published at time of writing.
  Re-check with the [AWS Pricing Calculator](https://calculator.aws) before committing —
  these move.
- **Excluded:** LLM provider spend, which dominates everything below. See §5.

---

## 1. Launch scale — ~$800/month

| Line item | Spec | Qty | Unit | Monthly |
|---|---|---|---|---|
| EKS control plane | | 1 | $0.10/hr | **$73** |
| EC2 — `general` node group | `m7i.xlarge` on-demand | 2 | $0.2016/hr | **$294** |
| EC2 — `media` node group | `m7i.2xlarge` on-demand | 1 | $0.4032/hr | **$294** |
| EBS — node root volumes | gp3, 150 + 150 + 200 GB | 500 GB | $0.08/GB | **$40** |
| RDS PostgreSQL | `db.m7g.large`, **Multi-AZ** | 1 | $0.3460/hr | **$253** |
| RDS storage | gp3, Multi-AZ (billed 2×) | 200 GB | $0.115/GB | **$23** |
| RDS backups | beyond free tier, ~50 GB | | $0.095/GB | **$5** |
| ElastiCache Redis | `cache.t4g.medium` × 2 (primary + replica) | 2 | $0.068/hr | **$99** |
| Application Load Balancer | fixed + ~3 LCU | 1 | $0.0225/hr | **$25** |
| NAT Gateway | fixed + ~100 GB processed | 1 | $0.045/hr | **$37** |
| VPC interface endpoints | ECR api/dkr, Secrets Mgr, Logs, STS | 5 × 3 AZ | $0.01/hr each | **$110** |
| ECR storage | 10 images × ~13 GB | 130 GB | $0.10/GB | **$13** |
| EFS | Elastic, ~5 GB | 5 GB | $0.30/GB | **$2** |
| Route 53 | hosted zone + queries | 1 | $0.50 + usage | **$2** |
| Secrets Manager | 2 secrets + API calls | 2 | $0.40 each | **$1** |
| S3 + DynamoDB | Terraform state + lock | | | **$1** |
| CloudWatch Logs | ~20 GB ingest, 7-day retention | 20 GB | $0.50/GB | **$11** |
| Data transfer out | ~200 GB | 200 GB | $0.09/GB | **$18** |
| | | | **Total** | **≈ $1,301** |

### 1.1 Bringing launch cost down to ~$800

The table above is the *safe* configuration. Three optional reductions, in the order they
should be considered:

| Action | Saves | Cost of the trade |
|---|---|---|
| Drop VPC interface endpoints, route via NAT | **−$110** | image pulls and Secrets Manager calls traverse the NAT at $0.045/GB. At ~130 GB/month of pulls that is ~$6, so this is a clear win **only while pull volume is low**. Keep the free S3 gateway endpoint either way. |
| 1-year Compute Savings Plan on EC2 | **−$170** (~29 %) | one-year commitment. Take this once instance sizing has settled — not on day one. |
| Single-AZ RDS | **−$126** | **Do not.** The store is every avatar's identity. This is the one line item worth paying full price for. |
| `media` node group scale-to-zero off-hours | **−$100** | media uploads queue until a node is available. Viable pre-launch, not after. |

Applying the first two: **≈ $1,020**. Applying the first, second, and fourth:
**≈ $920**. The commonly quoted "~$800" figure requires also running `general` on
`m7i.large` (2 vCPU / 8 GiB) with a single `anubis-api` replica — which forfeits both
high availability and the horizontal scaling this whole design exists to provide.
**Recommendation: budget $1,300/month, and take the Savings Plan at month three.**

---

## 2. Medium scale (~50 req/s) — ~$2,600/month

| Line item | Spec | Qty | Monthly |
|---|---|---|---|
| EKS control plane | | 1 | **$73** |
| EC2 — `general` | `m7i.2xlarge` | 3 | **$883** |
| EC2 — `media` | `m7i.2xlarge` | 2 | **$589** |
| EC2 — queue workers (upstream #1) | absorbed into `general` (+1 node) | 1 | **$294** |
| EBS — node root volumes | gp3, ~1,050 GB | | **$84** |
| RDS PostgreSQL | `db.m7g.xlarge`, Multi-AZ | 1 | **$505** |
| RDS storage + backups | gp3, 600 GB billed + backups | | **$85** |
| ElastiCache Redis | `cache.m7g.large` × 2 | 2 | **$236** |
| Application Load Balancer | fixed + ~25 LCU | 1 | **$70** |
| NAT Gateway | 2 AZs + ~500 GB | 2 | **$88** |
| VPC interface endpoints | | 5 × 3 AZ | **$110** |
| ECR / EFS / Route 53 / Secrets / S3 | | | **$20** |
| CloudWatch Logs | ~150 GB ingest | | **$78** |
| Data transfer out | ~1.5 TB | | **$135** |
| | | **Total** | **≈ $3,150** |

With a 1-year Compute Savings Plan on the EC2 lines (−$510) and interface endpoints
dropped (−$110): **≈ $2,530**.

---

## 3. Cost shape — what actually drives the bill

```
Launch (≈$1,300)                    Medium (≈$3,150)
├── EC2 nodes        $628  48%      ├── EC2 nodes       $1,766  56%
├── RDS Multi-AZ     $281  22%      ├── RDS Multi-AZ      $590  19%
├── VPC endpoints    $110   8%      ├── ElastiCache       $236   8%
├── ElastiCache       $99   8%      ├── VPC endpoints     $110   3%
├── EKS               $73   6%      ├── Data transfer     $135   4%
└── everything else  $110   8%      └── everything else   $313  10%
```

**Compute is roughly half the bill at both scales, and it is driven by the 12.8 GB
image.** The image forces a large root volume on every node, and its memory footprint
(torch + two Hugging Face models resident per pod) forces 4 Gi requests, which is what
sets how many pods fit per node. Splitting the image into slim-API and fat-media variants
([upstream change #4](../docs/upstream-changes.md)) would let `anubis-api` pods run at
~1.5 Gi, roughly doubling pod density on `general` and cutting the largest line item by
~30 %. **That single upstream change is worth more than every AWS-side optimisation in
§1.1 combined.**

---

## 4. Comparison to today

The current single host (whatever its actual cost) buys: no failover, no autoscaling, and
a durable store on a local volume. The AWS launch configuration buys Multi-AZ Postgres
with point-in-time recovery, rolling zero-downtime deploys, an autoscaling chat tier, and
media processing isolated onto its own nodes so a diarization batch can no longer starve
live chat.

The honest framing: this is not a cost optimisation, it is buying availability and
headroom. The number to judge it against is the revenue that a multi-hour outage of a
single host would cost.

---

## 5. What this table excludes: LLM spend

Not an AWS cost, but it will dwarf the AWS bill and belongs in the same budget
conversation.

Per the metering configuration in `anubis/src/anubis/utils/context.py` and
`_METERING_FEATURE.md`, each `/message` consumes a system prompt built from the full
identity document set plus retrieved memories and quotes — the prompt, not the reply, is
the dominant token cost. Each media upload additionally consumes:

- OpenAI `whisper-1` transcription, billed per audio minute
- `gpt-4o-transcribe-diarize` for diarization
- `ESTIMATED_ANALYSIS_PASSES_PER_DOCUMENT` structured-output passes per document

At medium scale (~50 req/s of mixed traffic) LLM spend is plausibly **5–20× the AWS
bill**. The `api_metrics` table already records per-request tokens, cost, and latency
(`persist_api_metrics_row` in `metering.py`) — that table, not this document, is the
authoritative source once traffic is real.

**Track both in one place.** The Grafana dashboards in `anubis/grafana/provisioning/`
already chart `api_metrics`; add AWS Cost Explorer alongside them when observability is
ported (architecture §8).

---

## 6. Budget alarms to set

| Alarm | Threshold |
|---|---|
| AWS Budgets — monthly actual | $1,500 at launch, $3,500 at medium |
| AWS Budgets — forecasted overrun | 110 % of budget |
| CloudWatch — NAT Gateway bytes processed | > 500 GB/month (signals a missing VPC endpoint) |
| CloudWatch — ECR storage | > 200 GB (signals the lifecycle policy is not pruning) |
| CloudWatch — `general` node group desired count | pinned at max for > 1 hour (signals undersized nodes, not real load) |
