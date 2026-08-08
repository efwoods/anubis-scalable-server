# Remote state.
#
# The bucket and lock table are a chicken-and-egg dependency: they must exist before this
# configuration can initialise. Create them once with scripts/bootstrap-tf-backend.sh,
# then fill in the values below and run `terraform init -migrate-state`.
#
# The state file contains the generated RDS master password and the ElastiCache AUTH
# token. Bucket encryption, versioning, and a restrictive bucket policy are not optional.

terraform {
  backend "s3" {
    bucket = "anubis-terraform-state-CHANGEME" # must be globally unique
    key    = "prod/terraform.tfstate"
    region = "us-east-2"

    encrypt      = true
    use_lockfile = true # S3-native locking; no DynamoDB table required (Terraform >= 1.10)
  }
}
