output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block, used by data-tier security groups."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids (the ALB lives here)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids (all workloads and the data tier live here)."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones spanned by this VPC."
  value       = local.availability_zones
}
