output "cluster_name" {
  description = "aws eks update-kubeconfig --region <region> --name <this>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

# --- values needed by the Helm releases ---------------------------------------------

output "registry_url" {
  description = "ECR registry host for image references."
  value       = module.registry.registry_url
}

output "repository_urls" {
  description = "Repository name to full ECR URL."
  value       = module.registry.repository_urls
}

output "acm_certificate_arn" {
  description = "alb.ingress.kubernetes.io/certificate-arn"
  value       = module.dns.acm_certificate_arn
}

output "external_secrets_role_arn" {
  description = "Annotate the External Secrets Operator service account with this."
  value       = module.secrets.external_secrets_role_arn
}

output "stripe_provision_role_arn" {
  description = "Annotate the Stripe provisioning hook's service account with this."
  value       = module.secrets.stripe_provision_role_arn
}

output "load_balancer_controller_role_arn" {
  description = "Annotate kube-system/aws-load-balancer-controller with this."
  value       = module.eks.load_balancer_controller_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "Annotate kube-system/cluster-autoscaler with this."
  value       = module.eks.cluster_autoscaler_role_arn
}

output "efs_file_system_id" {
  description = "spec.csi.volumeHandle for the Hugging Face model cache PersistentVolume."
  value       = module.data.efs_file_system_id
}

output "efs_access_point_id" {
  value = module.data.efs_access_point_id
}

output "public_subnet_ids" {
  description = "alb.ingress.kubernetes.io/subnets, if subnet auto-discovery is ever disabled."
  value       = module.network.public_subnet_ids
}

# --- connection strings for the Secrets Manager population step ----------------------
# Read with `terraform output -raw ...`; see docs/runbook.md §1.2.

output "rds_connection_uri" {
  description = "POSTGRES_URI / DATABASE_URI."
  value       = module.data.postgres_connection_uri
  sensitive   = true
}

output "rds_endpoint" {
  description = "PG_HOST."
  value       = module.data.postgres_endpoint
}

output "rds_password" {
  description = "PG_PASSWORD."
  value       = module.data.postgres_password
  sensitive   = true
}

output "redis_connection_uri" {
  description = "REDIS_URI."
  value       = module.data.redis_connection_uri
  sensitive   = true
}

# --- DNS ------------------------------------------------------------------------------

output "route53_name_servers" {
  description = "Set these at the registrar under DNS Option A."
  value       = module.dns.name_servers
}

output "acm_validation_records" {
  description = "Add these to Cloudflare (DNS-only) under DNS Option B."
  value       = module.dns.acm_validation_records
}

output "ecr_push_role_arn" {
  description = "Role assumed by GitHub Actions to push images; see docs/image-pipeline.md §3."
  value       = module.registry.ecr_push_role_arn
}
