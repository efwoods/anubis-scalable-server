output "repository_urls" {
  description = "Map of repository name to its ECR URL, for image references in Helm values."
  value       = { for name, repository in aws_ecr_repository.this : name => repository.repository_url }
}

output "registry_url" {
  description = "The account's ECR registry host."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "ecr_push_role_arn" {
  description = "IAM role for GitHub Actions to assume via OIDC when pushing images. Referenced by the publish-image workflows described in docs/image-pipeline.md."
  value       = aws_iam_role.ecr_push.arn
}
