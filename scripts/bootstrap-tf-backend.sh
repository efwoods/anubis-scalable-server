#!/usr/bin/env bash
#
# Create the S3 bucket that holds Terraform state. Chicken-and-egg: this cannot itself be
# Terraform-managed in the same configuration, so it is a one-time script.
#
#   ./scripts/bootstrap-tf-backend.sh anubis-terraform-state-<something-unique>
#
# Then put the bucket name in terraform/envs/prod/backend.tf and run
# `terraform init -migrate-state`.
#
# State locking uses the S3-native lockfile (Terraform >= 1.10), so no DynamoDB table is
# needed. Versioning and encryption are not optional: the state file carries the
# generated RDS master password and the ElastiCache AUTH token in cleartext.

set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
bucket="${1:-}"

if [[ -z $bucket ]]; then
    echo "Usage: bootstrap-tf-backend.sh <globally-unique-bucket-name> [--region REGION]" >&2
    exit 2
fi
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "==> Bucket ${bucket} already exists; ensuring its settings are correct."
else
    echo "==> Creating ${bucket} in ${REGION}"
    # us-east-1 rejects a LocationConstraint; every other region requires one.
    if [[ $REGION == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$bucket" --region "$REGION"
    else
        aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=${REGION}"
    fi
fi

echo "==> Enabling versioning (so a corrupted state can be rolled back)"
aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled

echo "==> Enabling default encryption"
aws s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

echo "==> Blocking all public access"
aws s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "==> Requiring TLS for every request"
aws s3api put-bucket-policy --bucket "$bucket" --policy "$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${bucket}", "arn:aws:s3:::${bucket}/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
POLICY
)"

echo
echo "==> Done. Set this in terraform/envs/prod/backend.tf:"
echo "      bucket = \"${bucket}\""
echo "      region = \"${REGION}\""
echo "    then: terraform -chdir=terraform/envs/prod init -migrate-state"
