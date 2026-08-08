variable "name_prefix" {
  description = "Prefix applied to IAM resource names in this module."
  type        = string
}

variable "secrets" {
  description = "Secrets Manager secrets to create, keyed by secret name. Created empty; populate per docs/runbook.md §1.2."
  type = map(object({
    description = string
  }))
  default = {
    "anubis/prod/env" = { description = "Anubis Agent Server environment, as a single JSON object (~200 keys, mirroring anubis/.env)." }
    "portal/prod/env" = { description = "Customer portal server environment, as a single JSON object." }
  }
}

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC provider ARN, from the eks module."
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC issuer host without the https:// prefix, from the eks module."
  type        = string
}

variable "external_secrets_namespace" {
  description = "Namespace the External Secrets Operator controller runs in."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_service_account" {
  description = "Service account name for the External Secrets Operator controller."
  type        = string
  default     = "external-secrets"
}

variable "application_namespace" {
  description = "Namespace the Anubis workloads run in."
  type        = string
  default     = "anubis"
}

variable "stripe_provision_service_account" {
  description = "Service account used by the Stripe provisioning Helm hook Job."
  type        = string
  default     = "anubis-stripe-provision"
}

variable "stripe_provision_secret_name" {
  description = "Key in var.secrets that the Stripe provisioning hook may write STRIPE_BILLING_CONFIG_JSON into. Empty disables the write role."
  type        = string
  default     = "anubis/prod/env"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
