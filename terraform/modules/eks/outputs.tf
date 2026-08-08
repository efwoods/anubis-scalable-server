output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA, for kubeconfig and the Helm/Kubernetes providers."
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group EKS attaches to managed nodes. Data-tier security groups allow ingress from this."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, for IRSA trust policies."
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without the https:// prefix, for IRSA condition keys."
  value       = local.oidc_host
}

output "node_role_arn" {
  description = "IAM role assumed by nodes in both node groups."
  value       = aws_iam_role.node.arn
}

output "load_balancer_controller_role_arn" {
  description = "IRSA role for the AWS Load Balancer Controller service account (kube-system/aws-load-balancer-controller)."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role for the cluster-autoscaler service account (kube-system/cluster-autoscaler)."
  value       = aws_iam_role.cluster_autoscaler.arn
}
