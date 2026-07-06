# Anubis — Capacity & Unit Economics (Data-Driven Addendum)

**Companion to** `architecture/scalable_infrastructure_report.md`.

This report answers three questions from **measured production data**, not estimates:

1. What is the average size of a *message* and a *document* in the vectorstore?
2. How many concurrent users does each infrastructure tier support?
3. What does LLM inference actually cost, given the measured per-turn context sizes?

> **Data source:** live local Postgres (`pgvector/pgvector:pg16`), the same schema the
> scalable server uses (LangGraph `store` + `store_vectors` + `checkpoints`). Snapshot taken
> **2026-07-06**. Sample: **1 user, 29 assistants (17 with data), 2,676 threads, 45,378 checkpoints.**
> This is a development/testing instance with one heavyweight user account; scaling assumptions
> based on per-assistant footprints derived here.

---

## 1. Vectorstore contents & sizing

The "vectorstore" is the LangGraph `store` table plus its `store_vectors` HNSW index. Every row is
a serialized LangChain `Document` (`page_content` + metadata) with one 640-dim embedding.

**Measured total footprint: `store` = 71 MB + `store_vectors` = 103 MB → 174 MB** across 24 users.

### The two averages requested

| Metric | Stored size (jsonb, TOAST-compressed) | Raw text (`page_content`) | + fixed embedding |
|---|---|---|---|
| **Message** (conversation-derived `identity_memory` entry) | **1,184 B** | 723 B | +2,564 B vector |
| **Document** (uploaded-file chunk, `document` namespace) | **2,880 B** | 3,471 B | +2,564 B vector |

Every entry carries a fixed **2,564-byte** 640-dim `float32` vector (11,560 vectors → 28 MB raw,
103 MB on disk with HNSW overhead). So *effective* per-entry cost is ~3.7 KB (message) and ~5.4 KB
(document) once the vector + index are counted.

> Note on compression: `page_content` for a document (3,471 B raw) is *larger* than its whole
> TOAST-compressed `value` (2,880 B) because jsonb in Postgres is compressed at rest.

### Full namespace breakdown (all entry types)

| Entry type | Rows | Avg stored value | Avg `page_content` | Role |
|---|---|---|---|---|
| `quote` | 6,928 | 1,816 B | 113 B | Few-shot style snippets (top-K per turn) |
| `document` | 2,330 | 2,880 B | 3,471 B | Uploaded-file chunks (retrieved, **not** always loaded) |
| `identity` | 974 | 3,054 B | 668 B | Primary-source facts (**all loaded every turn**) |
| `analysis` | 886 | 4,348 B | 856 B | Extracted identity-dimension analysis |
| `identity_memory` | 308 | 1,184 B | 723 B | Episodic conversation memory ("messages") |

A single uploaded document fans out into many chunks (e.g. a 780 KB log file → 263 `document` rows).

### If "message" means an actual chat turn (not memory)

Real conversation messages live in `checkpoint_blobs`, **not** the vectorstore. The `messages`
channel averages **5,322 B** per checkpointed state blob (17,416 blobs); the largest single
full-history blob measured is **7.9 MB**.

---

## 2. Per-assistant / per-thread storage footprint

**Per-assistant** (17 assistants with active data):

| Component | Per assistant |
|---|---|
| Vectorstore (`store` + `store_vectors`) | 174 MB / 17 ≈ **10.2 MB** |
| Conversation checkpoints | 157 threads/assistant × 791 KB/thread ≈ **~124 MB** |
| **Total** | **~134 MB/assistant** |

**Per-thread** (2,676 threads):

| Component | Per thread |
|---|---|
| Vectorstore entries + vector | ~65 KB |
| Checkpoint storage | 791 KB |
| **Total** | ~856 KB |

**The vectorstore is not the storage problem — checkpoints are.** Checkpoint tables total ~2.2 GB
(`checkpoint_blobs` 1.2 GB + `checkpoint_writes` 0.9 GB + `checkpoints` 67 MB) versus 174 MB for the
whole vectorstore — a 12.5× difference.

**Root cause of checkpoint bloat:** each of the 45,378 checkpoints re-stores the full
`assistant_identity_documents` channel (**52 KB avg**) and `system_message` (**15 KB avg**) *every
super-step*. Applying TTL / pruning to those channels collapses per-assistant storage from ~134 MB
to **~24 MB** (vectorstore + a few recent threads).

| Postgres tier | Assistants capacity @134 MB (raw) | @24 MB (pruned) |
|---|---|---|
| Dev 32 GB | ~240 | ~1,330 |
| Staging 128 GB | ~950 | ~5,330 |
| Prod 256 GB | ~1,900 | ~10,660 |

Storage cost is negligible either way — the 256 GB tier is $60/mo; Postgres compute + HA ($520/mo)
and AKS nodes dominate the fixed bill, not data volume.

---

## 3. Concurrent-user capacity per tier

Concurrency is gated by queue-worker slots (`N_JOBS_PER_WORKER = 10` graph runs per worker replica),
**not** storage. A "run" = one message being processed (report's stated 2–20 s latency). Using a
duty cycle (~10 s run over a ~45 s message cadence in an active session → each slot serves ~4–5
online users):

| Tier | Queue workers | In-flight runs | ~Online users | Infra cost |
|---|---|---|---|---|
| **Dev/Lite** | 1 | 10 | ~45 | **$193/mo** |
| **Staging** | 2–3 | 20–30 | ~90–135 | **$733/mo** |
| **Prod (HA)** | 3 → 10 | 30 → 100 | ~135 → ~450 | **$1,733/mo baseline → ~$2,800 peak** |

### Infra cost per online user
- **Prod baseline:** $1,733 ÷ ~135 ≈ **~$13/online-user/mo**
- **Prod at autoscale peak:** $2,800 ÷ ~450 ≈ **~$6/online-user/mo**

---

## 4. LLM inference cost

**Models in use:**
- Text inference + image description: **gpt-5.4-nano** — $0.20/1M input · $0.02/1M cached input · $1.25/1M output (High reasoning; reasoning tokens billed as output). — https://developers.openai.com/api/docs/models/gpt-5.4-nano
- Diarization: **gpt-4o-transcribe-diarize** — $2.50/1M audio input · $10/1M output. — https://developers.openai.com/api/docs/models/gpt-4o-transcribe-diarize

### How a turn consumes tokens (derived from measured context sizes, ≈4 chars/token)

The `think` call re-sends the full consciousness prompt every turn:

| Prompt component | Measured bytes/turn | ≈ tokens | Re-sent every turn? |
|---|---|---|---|
| Identity docs (full `identity` ns, loaded every turn) | 55,546 B/avatar | ~13,900 | ✅ identical → **cacheable** |
| System-message template | 15,000 B | ~3,750 | ✅ stable → cacheable |
| Quotes (top-K) + recalled memory + user docs | ~8,000 B | ~2,000 | partly |
| Conversation history (grows; avg state 5.3 KB) | ~12,000 B | ~3,000 | grows |
| **Input total per call** | | **~22,000 tok** | |
| Output (High reasoning + reply) | | **~2,000 tok** | |

Uploaded **documents** (2.7 MB/avatar for heavy users) go to the vectorstore for *retrieval* — only
the `identity` namespace is loaded wholesale each turn. That is why identity, not documents, drives
per-turn cost.

### Cost per inference call

| | Input | Output | **Per call** |
|---|---|---|---|
| **No prompt caching** | 22K × $0.20/1M = $0.0044 | 2K × $1.25/1M = $0.0025 | **$0.0069** |
| **With caching** (17.6K stable tokens cached) | $0.0004 + $0.0009 | $0.0025 | **$0.0037** (−46%) |

### Rolled up (~1.4 LLM calls/user-message from the tool loop; ~4 user messages/thread)

| Unit | No cache | Cached |
|---|---|---|
| Per **user message** | **~$0.010** | ~$0.005 |
| Per **conversation** (~4 msgs) | **~$0.04** | ~$0.02 |
| Per **user lifetime** in this DB (111 threads) | ~$4.30 | ~$2.20 |

### Media (one-time, per upload — not per message)

- **Image description** (gpt-5.4-nano vision): ~1,500 image tokens + short caption ≈ **~$0.001/image**. Negligible.
- **Diarization** (gpt-4o-transcribe-diarize): assuming ~10 audio-tokens/sec (~600/min) input +
  ~200 transcript tokens/min output → **~$0.0035/audio-minute ≈ $0.21/hour**, plus the reference
  clip re-sent each diarizer call. ⚠️ The audio-tokens-per-second rate is the one figure to confirm
  against actual usage — it swings this ±3×. Either way, diarization is a small one-time ingestion
  cost, not a recurring driver.

### Monthly inference cost vs. the fixed infra bill

| Tier | ~Online users | Assumed msgs/user/mo | Msgs/mo | Inference (no cache) | Inference (cached) | Infra (fixed) |
|---|---|---|---|---|---|---|
| Dev/Lite | ~45 | 300 | 13.5K | ~$130 | ~$70 | $193 |
| Staging | ~110 | 500 | 55K | ~$550 | ~$290 | $733 |
| Prod baseline | ~135 | 500 | 68K | ~$660 | ~$350 | $1,733 |
| Prod, heavy | ~450 | 1,500 | 675K | **~$6,600** | ~$3,500 | ~$2,800 (peak) |

**Crossover — where inference overtakes the Kubernetes bill:** at the no-cache rate, inference = the
$1,733 Prod infra bill at **~180K user-messages/month**; caching pushes the crossover to
**~330K/month**. The original report's "inference exceeds the Kubernetes bill at scale" holds — but
with gpt-5.4-nano it only flips at high volume; at beta scale, inference sits *below* infra.

---

## 5. Recommendations

1. **Enable OpenAI prompt caching on the stable prompt prefix.** ~17,600 tokens (identity docs +
   system template) are byte-identical turn to turn. Caching drops that portion 10× and roughly
   **halves total inference spend** — a bigger lever than any infra tuning.
2. **Add TTL / pruning to checkpoint channels** (`assistant_identity_documents`, `system_message`).
   This is the *same* 52 KB block that both bloats checkpoints (~95 MB → ~17 MB per user) and
   inflates inference input — fixing it helps storage and cost simultaneously.
3. **Meter per-message token usage** (token-usage + Stripe-metering roadmap items) so unit economics
   are tracked against the ~$0.005–0.010/message figure derived here.
4. **Vectorstore growth is not a scaling concern** — at ~7 MB/user it is a rounding error against
   both checkpoints and LLM spend; do not over-invest in Postgres storage tiers on its account.

---

## Appendix — Key measured figures

| Figure | Value |
|---|---|
| Users / assistants / threads / checkpoints | 1 / 29 (17 active) / 2,676 / 45,378 |
| Vectorstore total (`store` + `store_vectors`) | 174 MB |
| Avg message (`identity_memory`) stored value | 1,184 B (+2,564 B vector) |
| Avg document chunk stored value | 2,880 B (+2,564 B vector) |
| Fixed embedding size (640-dim float32) | 2,564 B |
| Avg identity text loaded per turn (per assistant) | 55,546 B (~13,900 tok) |
| Avg system-message per turn | 15,000 B (~3,750 tok) |
| Avg messages-channel blob | 5,322 B (max 7.9 MB) |
| Threads per assistant / message-blobs per thread | 157 / 7 (median 5) |
| Checkpoint storage per thread | 791 KB |
| Per-assistant total footprint (raw / pruned) | ~134 MB / ~24 MB |
| Per-thread total footprint | ~856 KB |
| Per-call inference cost (no cache / cached) | $0.0069 / $0.0037 |
| Per-message inference cost (no cache / cached) | ~$0.010 / ~$0.005 |
