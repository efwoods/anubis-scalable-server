# Launch-scale configuration (~5 requests/second).
#
# To reach medium scale (~50 req/s) change only the values marked MEDIUM below; no module
# or manifest edits are needed. See architecture/resource-quantity-table.md §6.

region      = "us-east-2"
environment = "prod"

# --- network ------------------------------------------------------------------------
vpc_cidr                   = "10.40.0.0/16"
availability_zone_count    = 3
nat_gateway_count          = 1 # MEDIUM: 3
enable_interface_endpoints = true

# --- EKS ------------------------------------------------------------------------------
kubernetes_version = "1.31"

# Narrow this to office/VPN ranges once the cluster is established. Left open here so the
# first `kubectl` from any location works; IAM is still required either way.
api_public_access_cidrs = ["0.0.0.0/0"]

general_instance_type = "m7i.xlarge" # MEDIUM: m7i.2xlarge
general_disk_size_gb  = 150
general_desired_size  = 2 # MEDIUM: 3
general_min_size      = 2 # MEDIUM: 3
general_max_size      = 6 # MEDIUM: 8

media_instance_type = "m7i.2xlarge"
media_disk_size_gb  = 200
media_desired_size  = 1 # MEDIUM: 2
media_min_size      = 1
media_max_size      = 2 # MEDIUM: 3

# --- data -----------------------------------------------------------------------------
postgres_version             = "16.4"
rds_instance_class           = "db.m7g.large" # MEDIUM: db.m7g.xlarge
rds_allocated_storage_gb     = 100            # MEDIUM: 300
rds_max_allocated_storage_gb = 500
rds_multi_az                 = true
rds_backup_retention_days    = 7 # MEDIUM: 14

# Must match PG_DB / PG_USER in the Anubis environment.
database_name     = "anubis"
database_username = "anubis"

# Prefer an SSM port forward over opening 5432 to a CIDR.
database_admin_cidrs = []

redis_version    = "7.1"
redis_node_type  = "cache.t4g.medium" # MEDIUM: cache.m7g.large
redis_node_count = 2

# --- registry -------------------------------------------------------------------------
ecr_repository_names     = ["anubis-langgraph-api", "portal-server"]
ecr_retained_image_count = 10

create_github_oidc_provider = true
github_allowed_subjects = [
  "repo:efwoods/anubis:ref:refs/heads/main",
  "repo:efwoods/anubis:ref:refs/tags/v*",
  "repo:efwoods/anubis-customer-portal:ref:refs/heads/main",
  "repo:efwoods/anubis-scalable-server:ref:refs/heads/main",
]

# Deploy awslabs/cfn-ecr-aws-soci-index-builder first, then name its Lambda here. Leaving
# this empty means pods pull the full 12.8 GB image on every cold node.
soci_index_builder_function_name = ""

# --- secrets --------------------------------------------------------------------------
application_namespace = "anubis"

# --- DNS ------------------------------------------------------------------------------
domain_name = "neuralnexus.site"
hostnames   = ["api", "checkout-api"]

# true  = delegate the zone to Route 53 (Option A, recommended)
# false = keep DNS at Cloudflare, issue the certificate only (Option B)
# See docs/dns-cutover.md §1.
create_route53_zone = true

# Left empty on the first apply. After the Helm releases provision the ALB, read it from
# the Ingress status and re-apply to create the alias records:
#   kubectl get ingress -n anubis anubis-api \
#     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
alb_dns_name = ""
alb_zone_id  = ""
