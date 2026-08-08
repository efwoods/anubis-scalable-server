#!/usr/bin/env bash
#
# Build the Anubis and/or portal images from a local checkout and push them to ECR.
#
# This script does NOT modify either source repository -- it runs their own build tooling
# (anubis/dockerbuild.sh, the portal's Dockerfile) and tags the result. See
# docs/image-pipeline.md for the CI alternative, which is the better long-term home for
# the build.
#
#   ./scripts/push-to-ecr.sh anubis ../anubis
#   ./scripts/push-to-ecr.sh portal ../anubis-customer-portal/src/server
#   ./scripts/push-to-ecr.sh all --anubis-path ../anubis --portal-path ../anubis-customer-portal/src/server
#
# The tag defaults to the short git SHA of the source checkout. ECR repositories are
# created IMMUTABLE, so a re-push of an existing tag is rejected -- which is the point.

set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
ANUBIS_REPOSITORY="anubis-langgraph-api"
PORTAL_REPOSITORY="portal-server"

# The local tag anubis/dockerbuild.sh produces.
ANUBIS_LOCAL_IMAGE="evdev3/anubis-langgraph-api:latest"

target="${1:-}"
shift || true

anubis_path=""
portal_path=""
explicit_tag=""

# A bare path as the second argument is a convenience for the single-target forms.
if [[ $# -gt 0 && $1 != -* ]]; then
    case "$target" in
        anubis) anubis_path="$1" ;;
        portal) portal_path="$1" ;;
        *) echo "A bare path argument is only valid with 'anubis' or 'portal'." >&2; exit 2 ;;
    esac
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) explicit_tag="$2"; shift 2 ;;
        --anubis-path) anubis_path="$2"; shift 2 ;;
        --portal-path) portal_path="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

usage() {
    cat >&2 <<'USAGE'
Usage:
  push-to-ecr.sh anubis <path-to-anubis-checkout> [--tag TAG] [--region REGION]
  push-to-ecr.sh portal <path-to-portal-server-dir> [--tag TAG] [--region REGION]
  push-to-ecr.sh all --anubis-path PATH --portal-path PATH [--tag TAG]
USAGE
    exit 2
}

case "$target" in
    anubis) [[ -n $anubis_path ]] || usage ;;
    portal) [[ -n $portal_path ]] || usage ;;
    all)    [[ -n $anubis_path && -n $portal_path ]] || usage ;;
    *)      usage ;;
esac

for tool in docker aws git; do
    command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 1; }
done

account_id="$(aws sts get-caller-identity --query Account --output text)"
registry="${account_id}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> Registry: $registry"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry"

# Resolve a tag from the source checkout unless one was given. Falls back to a timestamp
# for a checkout that is not a git repository.
resolve_tag() {
    local source_path="$1"
    if [[ -n $explicit_tag ]]; then
        printf '%s' "$explicit_tag"
        return
    fi
    if git -C "$source_path" rev-parse --short HEAD >/dev/null 2>&1; then
        local short_sha dirty
        short_sha="$(git -C "$source_path" rev-parse --short HEAD)"
        # A dirty tree would otherwise publish an immutable tag that no commit reproduces.
        dirty=""
        if ! git -C "$source_path" diff --quiet HEAD 2>/dev/null; then
            dirty="-dirty-$(date -u +%H%M%S)"
            echo "    WARNING: $source_path has uncommitted changes; tagging ${short_sha}${dirty}" >&2
        fi
        printf '%s%s' "$short_sha" "$dirty"
    else
        date -u +%Y%m%d%H%M%S
    fi
}

push_image() {
    local local_image="$1" repository="$2" tag="$3"
    local remote="${registry}/${repository}:${tag}"

    if aws ecr describe-images --region "$REGION" --repository-name "$repository" \
        --image-ids "imageTag=${tag}" >/dev/null 2>&1; then
        echo "==> ${repository}:${tag} already exists in ECR; nothing to push."
        echo "    Image reference: ${remote}"
        return
    fi

    echo "==> Tagging ${local_image} -> ${remote}"
    docker tag "$local_image" "$remote"

    echo "==> Pushing (the Anubis image is ~12.8 GB; the first push is slow, later ones reuse layers)"
    docker push "$remote"
    echo "    Image reference: ${remote}"
}

if [[ $target == anubis || $target == all ]]; then
    tag="$(resolve_tag "$anubis_path")"
    echo "==> Building Anubis Agent Server from ${anubis_path} (tag ${tag})"
    echo "    Running the repo's own two-stage build; nothing in that checkout is modified."
    ( cd "$anubis_path" && ./dockerbuild.sh )
    push_image "$ANUBIS_LOCAL_IMAGE" "$ANUBIS_REPOSITORY" "$tag"
    anubis_tag="$tag"
fi

if [[ $target == portal || $target == all ]]; then
    tag="$(resolve_tag "$portal_path")"
    local_portal_image="portal-server:${tag}"
    echo "==> Building customer portal server from ${portal_path} (tag ${tag})"
    docker build -t "$local_portal_image" "$portal_path"
    push_image "$local_portal_image" "$PORTAL_REPOSITORY" "$tag"
    portal_tag="$tag"
fi

echo
echo "==> Done. Deploy with:"
[[ -n ${anubis_tag:-} ]] && echo "      ANUBIS_TAG=${anubis_tag}"
[[ -n ${portal_tag:-} ]] && echo "      PORTAL_TAG=${portal_tag}"
echo "    then follow docs/runbook.md §1.7, or run the deploy workflow with these tags."
