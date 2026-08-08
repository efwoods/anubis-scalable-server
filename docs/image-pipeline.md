# Image Pipeline — building and publishing to ECR

Two images feed this deployment. Neither is built from source in *this* repo — the
sources live in repositories this repo does not modify.

| Image | Source repo | Built by |
|---|---|---|
| `anubis-langgraph-api` | `efwoods/anubis` | its own two-stage `dockerbuild.sh` |
| `portal-server` | `efwoods/anubis-customer-portal` (`src/server`) | its `Dockerfile` |

---

## 1. The contract

Everything downstream — `helm upgrade`, the pre-pull DaemonSet, rollbacks — depends on
exactly three properties. Any pipeline satisfying them is acceptable.

1. **Immutable tags.** Every image is tagged with the **short git SHA** of the source
   commit (`a1b2c3d`). The ECR repositories are created with
   `image_tag_mutability = "IMMUTABLE"`, so a tag can never be re-pointed and **there is
   no `latest` in ECR** — re-pushing it would be rejected. Local `latest` tags produced by
   `dockerbuild.sh` stay local. A Deployment pinned to a floating tag cannot be rolled
   back and cannot be reasoned about during an incident.
2. **A SOCI index per image.** The Anubis image is 12.8 GB
   ([architecture §2.4](../architecture/scalable_architecture.md)); without lazy loading a
   scale-out event stalls for minutes.
3. **Pushed to the ECR repositories created by Terraform**
   (`terraform/modules/registry`), so lifecycle policies prune old tags and scan-on-push
   runs.

---

## 2. Building from a local checkout (available today)

`scripts/push-to-ecr.sh` in this repo drives both source repos from a local checkout. It
does not modify them — it runs their own build scripts and pushes the result.

```bash
# Anubis Agent Server (runs anubis/dockerbuild.sh, then tags and pushes)
./scripts/push-to-ecr.sh anubis ../anubis

# Customer portal server
./scripts/push-to-ecr.sh portal ../anubis-customer-portal/src/server

# Both, with an explicit tag
./scripts/push-to-ecr.sh all --tag "$(git -C ../anubis rev-parse --short HEAD)"
```

The script prints the fully qualified image reference on completion. That value is the
`--set image.tag` argument for `helm upgrade`.

**Two-stage build.** `anubis/dockerbuild.sh` builds `anubis-base:latest` from
`Dockerfile.anubis.base` (ffmpeg, native audio libs, chromium, full dependency install,
NLTK corpora) and then `Dockerfile` on top of it, which refreshes source and installs
only changed dependencies. The base stage is the slow one — expect 20–40 minutes cold,
and a couple of minutes when only source changed.

**Bandwidth warning.** Pushing 12.8 GB from a laptop takes a while. The layers are stable
across source-only rebuilds, so subsequent pushes upload only the top layer.

---

## 3. Building in CI (recommended, requires a change in the source repos)

The better home for the build is the repo that owns the source, so a merge to `main`
produces an image without anyone's laptop being involved. That is a workflow file added
to `anubis` and `anubis-customer-portal` — **not** to this repo, and therefore not
included here. The workflow to add:

```yaml
# .github/workflows/publish-image.yml  (in the anubis repo)
name: Publish image to ECR
on:
  push:
    branches: [main]
    tags: ["v*"]

permissions:
  id-token: write        # OIDC — no long-lived AWS keys in GitHub
  contents: read

jobs:
  publish:
    runs-on: ubuntu-latest-16-cores     # the base build is heavy
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<account-id>:role/anubis-ecr-push
          aws-region: us-east-2

      - id: login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build
        run: ./dockerbuild.sh

      - name: Tag and push
        env:
          REGISTRY: ${{ steps.login.outputs.registry }}
        run: |
          TAG="$(git rev-parse --short HEAD)"
          docker tag evdev3/anubis-langgraph-api:latest "$REGISTRY/anubis-langgraph-api:$TAG"
          docker push "$REGISTRY/anubis-langgraph-api:$TAG"
          echo "IMAGE_TAG=$TAG" >> "$GITHUB_STEP_SUMMARY"

      - name: Trigger deploy
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.DEPLOY_DISPATCH_TOKEN }}
          repository: efwoods/anubis-scalable-server
          event-type: image-published
          client-payload: '{"service":"anubis","tag":"${{ github.sha }}"}'
```

The IAM role `anubis-ecr-push` and its GitHub OIDC trust policy **are** created by
`terraform/modules/registry` in this repo, so the AWS side is ready before the workflow
exists. Its ARN is a Terraform output.

The dispatch step lands on `.github/workflows/deploy.yml` here, which runs the
`helm upgrade`.

---

## 4. SOCI indexing

SOCI (Seekable OCI) lets containerd start a container before the whole image is
downloaded. Two ways to produce the index:

**Automatic (preferred).** `terraform/modules/registry` provisions the
[ECR SOCI index builder](https://github.com/awslabs/cfn-ecr-aws-soci-index-builder)
pattern: an EventBridge rule on `ECR Image Action → PUSH` invoking a Lambda that builds
and pushes the index artifact. Nothing to remember at push time.

**Manual.** `soci create <image>` then `soci push --user AWS:$(aws ecr get-login-password) <image>`.

Verify an index exists for a tag:

```bash
aws ecr list-images --repository-name anubis-langgraph-api \
  --filter tagStatus=UNTAGGED --query 'imageIds[*].imageDigest' --output text
# SOCI index artifacts are untagged manifests referring to the image digest
```

On the node, the snapshotter's log is the ground truth:

```bash
kubectl debug node/<node> -it --image=busybox -- \
  chroot /host journalctl -u soci-snapshotter -n 50
```

If SOCI is unavailable, nothing breaks — pods just pull the full image. Watch for
`ImagePullBackOff` and multi-minute `ContainerCreating` during scale-out as the symptom.

---

## 5. Lifecycle and retention

`terraform/modules/registry` sets:

- keep the **last 10 tagged images** per repository (≈130 GB for `anubis-langgraph-api`)
- expire **untagged** images after 7 days, *except* SOCI index artifacts
- **scan on push** enabled

Ten tags is roughly two weeks of deploys and comfortably more than the rollback window
anyone actually uses. Raising it costs $0.10/GB/month against a 13 GB image — do that
deliberately, not by accident.

---

## 6. Rollback

Because tags are immutable git SHAs, rollback is a redeploy of a previous tag:

```bash
helm rollback anubis-api                       # previous Helm revision
# or explicitly:
helm upgrade anubis-api langgraph-cloud/langgraph-cloud \
  -f helm/anubis-api/values-prod.yaml \
  --set images.apiServerImage.tag=<previous-sha>
```

Both are fast **only if the previous image is still on the node**. It usually is —
`deregistration_delay` and the pre-pull DaemonSet keep recent tags warm — but a rollback
after a node replacement pays the full pull. Budget minutes, not seconds, and see the
[runbook](runbook.md).
