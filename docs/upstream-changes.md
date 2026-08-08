# Upstream Changes Required in `anubis`

These are changes to the [`anubis`](https://github.com/efwoods/anubis) repository, which
this repo treats as **reference-only and does not modify**. The AWS architecture is
designed to be correct today without any of them; each one removes a limitation that is
currently worked around by infrastructure.

Ordered by how much scale each unblocks.

| # | Change | Unblocks | Effort |
|---|---|---|---|
| 1 | Move `/message` onto the task queue | independent API/compute scaling; the whole queue-worker tier | Large |
| 2 | Persist the media-job registry | `anubis-stateful` beyond 1 replica; job durability across restarts | Medium |
| 3 | Redis-bridge the MCP relay | data-analysis MCP across a multi-replica API tier | Medium |
| 4 | Split the Docker image | ~30 % of the AWS compute bill; fast autoscaling | Medium |
| 5 | Bake Hugging Face weights into the base image | retires the EFS cache; faster cold start | Small |

---

## 1. Move `/message` onto the task queue

### Current behaviour

`src/api/webapp.py` executes the compiled graph inside the API process:

- `webapp.py:900` — `graph.astream(...)`, the SSE token stream
- `webapp.py:3563` — `graph.ainvoke(...)` in `POST /message`
- `webapp.py:3834` — `graph.ainvoke(...)` in `POST /message/{assistant_id}`
- `webapp.py:1271` — `AsyncPostgresSaver(app.state.pool)`, its checkpointer
- `webapp.py:1277` — `message_workflow.compile(...)` into `app.state.graph`

A search for `client.runs.*` across `src/` returns nothing. The Agent Server's task queue
is never used.

### Why it matters

The [Agent Server architecture](https://docs.langchain.com/langsmith/agent-server) exists
to separate request serving from run execution: API servers stay light and scale on
request volume, queue workers scale on pending-run count, and a worker crash resumes from
the last checkpoint rather than dropping the request. Anubis currently gets none of that —
an API pod that dies mid-`/message` drops the run, and every API replica must be sized
for full inference load.

### What to change

Replace in-process execution with SDK run creation and streaming:

```python
# instead of: async for chunk in graph.astream(state, config): ...
from langgraph_sdk import get_client

client = get_client(headers={"API-KEY": token})
async for chunk in client.runs.stream(
    thread_id=thread_id,
    assistant_id=assistant_id,
    input=state,
    config=config,
    stream_mode=["messages", "values"],
    durability="async",
):
    ...
```

Notes for whoever picks this up:

- The server injects the checkpointer and store at runtime. `app.state.checkpointer` and
  the `AsyncPostgresSaver` construction (`webapp.py:1271`) go away — the docs are
  explicit that graph code must not configure these itself.
- `internal_thoughts` (the tool-call loop channel that keeps tool turns from emitting
  `assistant_token` events) is already a state channel, so it survives the move
  unchanged; `stream_mode` selection is what controls what reaches the client.
- Consider `durability="exit"` for the latency-sensitive `response_only_workflow` path —
  it stores only the final state and removes a checkpoint write per step.

### Infrastructure change once this lands

```yaml
# helm/anubis-api/values-prod.yaml
queue:
  enabled: true
  deployment:
    replicaCount: 3
    resources: { requests: { cpu: "1", memory: 2Gi } }
  autoscaling: { enabled: true, minReplicas: 3, maxReplicas: 10 }
apiServer:
  deployment:
    resources: { requests: { cpu: "500m", memory: 2Gi } }   # much lighter
```

---

## 2. Persist the media-job registry

### Current behaviour

`app.state.media_jobs` is a plain dict created at `webapp.py:1270`. Master and child jobs
are created into it (`create_master_job` / `create_child_job`, `webapp.py:6467-6480`) and
executed by `asyncio.create_task(run_batch_media_job(...))` at `webapp.py:6510`.

The `/media_jobs` handler documents the consequence itself:

> *"The registry is per-process (see media_jobs.py), so this reflects jobs owned by the
> worker handling the request."*

### Why it matters

Two failures follow. A job started on pod A and polled on pod B returns 404. And an
in-flight batch is lost entirely if the pod restarts — including a routine `helm upgrade`.
This is what pins `anubis-stateful` to `replicas: 1` with `strategy: Recreate` and an
1800-second termination grace period.

### What to change

Either of two designs works:

**(a) Postgres-backed registry.** Add a `media_jobs` table (job id, parent id, user id,
assistant id, filename, status, progress, timestamps, result JSON). `/media_job/*` reads
it; progress SSE tails it. Workers claim jobs with `SELECT … FOR UPDATE SKIP LOCKED` so
any replica can pick up orphaned work.

**(b) Dispatch to the existing `process_media` graph via the queue.** `langgraph.json`
already registers `process_media` as a deployable graph. `/update_avatar_identity_with_media`
becomes `client.runs.create(assistant_id="process_media", ...)` and `/media_job/{id}`
becomes a thin wrapper over the Agent Server's own run status and `/stream`. This reuses
durability, cancellation, and streaming that the platform already provides — strictly
less code — and composes with change #1.

**(b) is the recommended design.**

### Infrastructure change once this lands

`anubis-stateful` gains an HPA and `strategy: RollingUpdate`; the media ALB path rules
can point at `anubis-api` and the separate Deployment disappears (keeping the tainted
`media` node group as a scheduling preference for CPU-heavy work).

---

## 3. Redis-bridge the MCP relay

### Current behaviour

`webapp.py:2709` (`@app.websocket("/mcp/relay")`) authenticates a user's local MCP daemon
and calls `relay_registry.register_session(...)` into an **in-process** registry
(`src/anubis/utils/tools/data_analysis/relay.py`). The graph's `mcp_discovery` node and
the `/mcp/relay/{device_id}` bridge read that same registry.

### Why it matters

The WebSocket is held by exactly one pod. Any request served by a different pod cannot
reach that device. With the tier split in the current architecture, a `/message` run
executes on `anubis-api` while the daemon socket lives on `anubis-stateful` — so
cross-tier MCP does not work at all until this is fixed. The interim mitigation is
`DATA_ANALYSIS_ENABLED=false` on `anubis-api`.

### What to change

Add a Redis-backed routing layer over the existing registry:

1. On `register_session`, record `device_id → pod_identity` in Redis with a TTL refreshed
   by the existing `/mcp/heartbeat` (`webapp.py:2934`).
2. `proxy_request` looks up the owning pod. If it is the local pod, use the in-process
   socket as today. If not, publish the request on a Redis channel keyed by
   `pod_identity` and await the correlated `proxy_response` on a reply channel.
3. On `unregister` / socket close, delete the Redis key.

`REDIS_URI` is already configured and ElastiCache is already provisioned, so no new
infrastructure is needed. The frame types (`FRAME_REGISTER`, `proxy_request`,
`proxy_response`) and the per-device secret authentication stay exactly as they are — only
the transport between pods is new.

---

## 4. Split the Docker image

### Current behaviour

`Dockerfile.anubis.base` produces a single **12.8 GB** image containing ffmpeg-7,
libsndfile, libgomp, chromium, torch, torchaudio, torchcodec, librosa, moviepy,
playwright, and baked NLTK corpora. Both tiers run it.

### Why it matters

Three costs, all real:

- **Autoscaling is slow.** A new node must pull 12.8 GB before a pod can start. Worked
  around with SOCI lazy loading, a pre-pull DaemonSet, and a conservative HPA scale-up
  window — three mitigations for one root cause.
- **Node storage.** Every node needs a 150–200 GB root volume.
- **Pod density.** Torch plus two resident Hugging Face models sets the `anubis-api`
  memory request at 4 Gi, which is what determines pods-per-node — the largest single
  driver of the EC2 bill.

Per [cost-model.md](../architecture/cost-model.md), this change is worth roughly 30 % of
the compute line — **more than every AWS-side optimisation combined**.

### What to change

Introduce pyproject extras and two Dockerfiles from a shared slim base:

```toml
# pyproject.toml
[project.optional-dependencies]
media = ["torch", "torchaudio", "torchcodec", "librosa", "soundfile", "moviepy", "noisereduce", "demucs"]
browser = ["playwright"]
```

- `Dockerfile.api` — no apk media packages, no chromium, install without the `media`
  extra. The embedding and GoEmotions models still need transformers, so a CPU-only
  torch wheel (`--index-url https://download.pytorch.org/whl/cpu`) is the meaningful
  saving here; estimated ~3 GB.
- `Dockerfile.media` — today's full base, unchanged.

Guard the media code paths so the API image fails loudly on a genuine misroute rather
than at import time: the lazy-import convention in `CLAUDE.md` ("heavy SDK imports must
be lazy, not at module scope") already puts most of these imports inside functions.

### Infrastructure change once this lands

Two ECR repositories, `apiServer.deployment.resources.requests.memory` drops to ~1.5 Gi,
`general` node count drops, and the pre-pull DaemonSet becomes unnecessary for the API
tier.

---

## 5. Bake Hugging Face weights into the base image

### Current behaviour

`ensure_huggingface_models_cached` (`src/anubis/utils/huggingface_prefetch.py:21`) calls
`snapshot_download` for `context.embedding_model` and `GO_EMOTIONS_MODEL_ID` during
lifespan startup (`webapp.py:1216`). On Compose this is masked by the bind-mounted
`~/.cache/huggingface`. On Kubernetes every cold pod downloads them.

### Why it matters

It adds minutes to cold start — exactly when the HPA is trying to add capacity — and it
makes pod start-up depend on Hugging Face being reachable. The current workaround is an
EFS ReadWriteMany PVC mounted at `/root/.cache/huggingface`, warmed by
`scripts/warm-hf-cache.sh`.

### What to change

Add to `Dockerfile.anubis.base`, immediately after the dependency install (the same
placement and reasoning as the existing NLTK prefetch at line 58):

```dockerfile
# Pre-bake the Hub snapshots the store index and the sentiment node need, for the same
# reason the NLTK corpora above are baked: fetching them lazily on the first request
# leaves that request streaming keepalive frames for minutes.
# Kept in lockstep with huggingface_prefetch.py.
RUN python -c "\
from huggingface_hub import snapshot_download; \
[snapshot_download(repo_id=repo_id) for repo_id in \
 ('microsoft/harrier-oss-v1-270m', 'SamLowe/roberta-base-go_emotions')]"
```

The repo ids above match `GO_EMOTIONS_MODEL_ID`
(`huggingface_prefetch.py:15` — `SamLowe/roberta-base-go_emotions`) and the
`EMBEDDING_MODEL` pinned in `langgraph.json`; they must be kept in lockstep, or the
runtime download happens anyway and the layer is dead weight. Note that this trades
image size (already the subject of change #4) for start-up time; apply
it to the media image unconditionally and to the slim API image once #4 lands.

### Infrastructure change once this lands

Delete the EFS PVC, the `warm-hf-cache` Job, and `scripts/warm-hf-cache.sh`.

---

## Tracking

None of these are required to deploy. Recommended order once the AWS deployment is
stable: **#5 → #4 → #2 → #3 → #1**, cheapest and most independent first. #1 is the
largest and benefits from #2 landing as design (b) first.
