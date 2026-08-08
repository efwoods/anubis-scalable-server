output "secret_arns" {
  description = "Map of secret name to ARN."
  value       = { for name, secret in aws_secretsmanager_secret.this : name => secret.arn }
}

output "secret_names" {
  description = "Names of the created secrets, referenced by ExternalSecret remoteRef keys."
  value       = keys(aws_secretsmanager_secret.this)
}

output "external_secrets_role_arn" {
  description = "IRSA role for the External Secrets Operator service account. Annotate that service account with this."
  value       = aws_iam_role.external_secrets.arn
}

output "stripe_provision_role_arn" {
  description = "IRSA role for the Stripe provisioning hook Job's service account. Empty when the write role is disabled."
  value       = var.stripe_provision_secret_name == "" ? "" : aws_iam_role.stripe_provision[0].arn
}
