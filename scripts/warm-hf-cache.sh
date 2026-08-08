#!/usr/bin/env bash
#
# Warm the shared Hugging Face weight cache on EFS by running warm-hf-cache.yaml with the
# image reference filled in.
#
#   ./scripts/warm-hf-cache.sh <git-sha>
#   ./scripts/warm-hf-cache.sh <git-sha> --wait
#
# See warm-hf-cache.yaml for why this exists and when it goes away.

set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
NAMESPACE="${NAMESPACE:-anubis}"
REPOSITORY="anubis-langgraph-api"
TERRAFORM_DIR="${TERRAFORM_DIR:-terraform/envs/prod}"

tag="${1:-}"
shift || true
wait_for_completion=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait) wait_for_completion=true; shift ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z $tag ]]; then
    echo "Usage: warm-hf-cache.sh <image-tag> [--wait] [--namespace NS]" >&2
    exit 2
fi

command -v kubectl >/dev/null || { echo "kubectl not found." >&2; exit 1; }

if [[ -n ${REGISTRY:-} ]]; then
    registry="$REGISTRY"
elif command -v terraform >/dev/null && [[ -d $TERRAFORM_DIR ]]; then
    registry="$(terraform -chdir="$TERRAFORM_DIR" output -raw registry_url)"
else
    account_id="$(aws sts get-caller-identity --query Account --output text)"
    registry="${account_id}.dkr.ecr.${REGION}.amazonaws.com"
fi

image="${registry}/${REPOSITORY}:${tag}"
manifest="$(dirname "$0")/warm-hf-cache.yaml"

echo "==> Image: ${image}"

# The PVC must exist first -- it comes from the platform chart.
if ! kubectl get pvc anubis-model-cache -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "PersistentVolumeClaim anubis-model-cache not found in namespace ${NAMESPACE}." >&2
    echo "Install the platform chart first (docs/runbook.md §1.5)." >&2
    exit 1
fi

# Jobs are immutable, so a previous run has to go before this one is created.
kubectl delete job warm-hf-cache -n "$NAMESPACE" --ignore-not-found

echo "==> Applying warm-hf-cache Job"
sed "s#__IMAGE__#${image}#" "$manifest" | kubectl apply -n "$NAMESPACE" -f -

if [[ $wait_for_completion == true ]]; then
    echo "==> Waiting for completion (first run pulls a 12.8 GB image; allow ~20 minutes)"
    kubectl wait --for=condition=complete job/warm-hf-cache -n "$NAMESPACE" --timeout=20m
    kubectl logs job/warm-hf-cache -n "$NAMESPACE"
else
    echo "==> Applied. Follow with:"
    echo "      kubectl wait --for=condition=complete job/warm-hf-cache -n ${NAMESPACE} --timeout=20m"
    echo "      kubectl logs job/warm-hf-cache -n ${NAMESPACE}"
fi
