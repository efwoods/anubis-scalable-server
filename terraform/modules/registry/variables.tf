variable "name_prefix" {
  description = "Prefix applied to IAM resource names in this module."
  type        = string
}

variable "repository_names" {
  description = "ECR repositories to create."
  type        = list(string)
  default     = ["anubis-langgraph-api", "portal-server"]
}

variable "retained_image_count" {
  description = "Tagged images kept per repository. Ten is roughly two weeks of deploys and ~130 GB for the Anubis repository at 12.8 GB per image."
  type        = number
  default     = 10
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false when the account already has one -- an account may hold only a single provider per issuer URL."
  type        = bool
  default     = true
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_github_oidc_provider is false."
  type        = string
  default     = ""
}

variable "github_allowed_subjects" {
  description = "GitHub OIDC subject patterns permitted to assume the push role. Pin the repository and the ref so a fork or an unexpected branch cannot push images."
  type        = list(string)
  default = [
    "repo:efwoods/anubis:ref:refs/heads/main",
    "repo:efwoods/anubis:ref:refs/tags/v*",
    "repo:efwoods/anubis-customer-portal:ref:refs/heads/main",
    "repo:efwoods/anubis-scalable-server:ref:refs/heads/main",
  ]
}

variable "soci_index_builder_function_name" {
  description = "Name of an already-deployed SOCI index builder Lambda (awslabs/cfn-ecr-aws-soci-index-builder). Leave empty to skip the EventBridge wiring and build indexes manually."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
