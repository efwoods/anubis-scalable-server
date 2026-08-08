variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC id from the network module."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet ids for the DB, cache, and EFS mount targets."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group. The only source allowed to reach Postgres, Redis, and NFS."
  type        = string
}

variable "admin_access_cidrs" {
  description = "Extra CIDRs allowed to reach Postgres on 5432, for one-off admin access (pg_restore, psql). Leave empty in steady state and use a bastion or SSM port forward instead."
  type        = list(string)
  default     = []
}

# --- PostgreSQL -------------------------------------------------------------------

variable "postgres_version" {
  description = "RDS PostgreSQL engine version. 16.x to match the pgvector/pgvector:pg16 image the current stack runs; a cluster major-version mismatch is not a valid restore target."
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  description = "RDS instance class. db.m7g.large at launch, db.m7g.xlarge at medium scale."
  type        = string
  default     = "db.m7g.large"
}

variable "allocated_storage_gb" {
  type        = number
  description = "Initial gp3 storage."
  default     = 100
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling. Growth is driven by the vector store and checkpoints, both of which scale with avatar count."
  type        = number
  default     = 500
}

variable "multi_az" {
  description = "Multi-AZ. Keep this true: the store is every avatar's identity documents, memories, quotes, and checkpoints, and its current home is a container on one local disk."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  type        = number
  description = "Automated backup retention, which also enables point-in-time recovery."
  default     = 7
}

variable "deletion_protection" {
  type        = bool
  description = "Block accidental deletion of the primary datastore."
  default     = true
}

variable "database_name" {
  type        = string
  description = "Initial database name. Must match PG_DB in the Anubis environment."
  default     = "anubis"
}

variable "master_username" {
  type        = string
  description = "Master username. Must match PG_USER in the Anubis environment."
  default     = "anubis"
}

# --- Redis ------------------------------------------------------------------------

variable "redis_version" {
  type        = string
  description = "ElastiCache Redis engine version. LangSmith requires Redis OSS 5 or higher."
  default     = "7.1"
}

variable "redis_node_type" {
  description = "ElastiCache node type. Do not oversize: the Agent Server stores only ephemeral pubsub data here, and LangChain's reference configuration keeps Redis at 2 GiB even at 500 req/s."
  type        = string
  default     = "cache.t4g.medium"
}

variable "redis_node_count" {
  description = "Total nodes (primary plus replicas). 2 gives automatic failover."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
