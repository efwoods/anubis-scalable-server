variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "environment" {
  description = "Environment name, used in every resource name."
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Extra tags merged into the standard set."
  type        = map(string)
  default     = {}
}

# --- network ----------------------------------------------------------------------

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "availability_zone_count" {
  type    = number
  default = 3
}

variable "nat_gateway_count" {
  description = "1 at launch, 3 at medium scale."
  type        = number
  default     = 1
}

variable "enable_interface_endpoints" {
  description = "See architecture/cost-model.md §1.1 -- ~$110/month, worth dropping only while image-pull volume is low."
  type        = bool
  default     = true
}

# --- EKS --------------------------------------------------------------------------

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API. Narrow this once the cluster is established."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "general_instance_type" {
  description = "x86_64 only -- the image ships x86 PyTorch wheels and a wolfi chromium apk."
  type        = string
  default     = "m7i.xlarge"
}

variable "general_disk_size_gb" {
  type    = number
  default = 150
}

variable "general_desired_size" {
  type    = number
  default = 2
}

variable "general_min_size" {
  type    = number
  default = 2
}

variable "general_max_size" {
  type    = number
  default = 6
}

variable "media_instance_type" {
  type    = string
  default = "m7i.2xlarge"
}

variable "media_disk_size_gb" {
  type    = number
  default = 200
}

variable "media_desired_size" {
  type    = number
  default = 1
}

variable "media_min_size" {
  type    = number
  default = 1
}

variable "media_max_size" {
  type    = number
  default = 2
}

# --- data -------------------------------------------------------------------------

variable "postgres_version" {
  type    = string
  default = "16.4"
}

variable "rds_instance_class" {
  description = "db.m7g.large at launch, db.m7g.xlarge at medium scale."
  type        = string
  default     = "db.m7g.large"
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 100
}

variable "rds_max_allocated_storage_gb" {
  type    = number
  default = 500
}

variable "rds_multi_az" {
  description = "Keep true. The store is every avatar's identity."
  type        = bool
  default     = true
}

variable "rds_backup_retention_days" {
  type    = number
  default = 7
}

variable "database_name" {
  description = "Must match PG_DB in the Anubis environment."
  type        = string
  default     = "anubis"
}

variable "database_username" {
  description = "Must match PG_USER in the Anubis environment."
  type        = string
  default     = "anubis"
}

variable "database_admin_cidrs" {
  description = "Extra CIDRs allowed to reach Postgres for one-off admin work (pg_restore). Prefer an SSM port forward and leave this empty."
  type        = list(string)
  default     = []
}

variable "redis_version" {
  type    = string
  default = "7.1"
}

variable "redis_node_type" {
  description = "Do not oversize -- Redis holds only ephemeral Agent Server pubsub data."
  type        = string
  default     = "cache.t4g.medium"
}

variable "redis_node_count" {
  type    = number
  default = 2
}

# --- registry ---------------------------------------------------------------------

variable "ecr_repository_names" {
  type    = list(string)
  default = ["anubis-langgraph-api", "portal-server"]
}

variable "ecr_retained_image_count" {
  type    = number
  default = 10
}

variable "create_github_oidc_provider" {
  description = "False when the account already has a GitHub OIDC provider -- only one may exist per issuer URL."
  type        = bool
  default     = true
}

variable "existing_github_oidc_provider_arn" {
  type    = string
  default = ""
}

variable "github_allowed_subjects" {
  type = list(string)
  default = [
    "repo:efwoods/anubis:ref:refs/heads/main",
    "repo:efwoods/anubis:ref:refs/tags/v*",
    "repo:efwoods/anubis-customer-portal:ref:refs/heads/main",
    "repo:efwoods/anubis-scalable-server:ref:refs/heads/main",
  ]
}

variable "soci_index_builder_function_name" {
  description = "Deployed awslabs SOCI index builder Lambda name. Empty skips the EventBridge wiring; see docs/image-pipeline.md §4."
  type        = string
  default     = ""
}

# --- secrets ----------------------------------------------------------------------

variable "application_namespace" {
  description = "Kubernetes namespace for the Anubis workloads."
  type        = string
  default     = "anubis"
}

# --- DNS --------------------------------------------------------------------------

variable "domain_name" {
  type    = string
  default = "neuralnexus.site"
}

variable "hostnames" {
  type    = list(string)
  default = ["api", "checkout-api"]
}

variable "create_route53_zone" {
  description = "True delegates DNS to Route 53 (Option A). False keeps it at Cloudflare and issues the certificate only (Option B) -- see docs/dns-cutover.md §1."
  type        = bool
  default     = true
}

variable "alb_dns_name" {
  description = "Set on a second apply, after the Helm releases have provisioned the ALB."
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  type    = string
  default = ""
}
