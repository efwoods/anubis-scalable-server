variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for the kubernetes.io/cluster subnet tags that let the AWS Load Balancer Controller discover subnets."
  type        = string
}

variable "region" {
  description = "AWS region, used to build VPC endpoint service names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough for pod IPs, which the VPC CNI allocates from the private subnets."
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zone_count" {
  description = "Number of availability zones to span. Three is the minimum for a Multi-AZ RDS plus a spread API tier."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4."
  }
}

variable "nat_gateway_count" {
  description = "Number of NAT Gateways. 1 at launch (shared, single-AZ egress dependency); raise to availability_zone_count at medium scale."
  type        = number
  default     = 1

  validation {
    condition     = var.nat_gateway_count >= 1
    error_message = "At least one NAT Gateway is required for pods to reach LLM providers and beacon.langchain.com."
  }
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints for ECR, Secrets Manager, CloudWatch Logs, and STS. Costs ~$0.01/hr per endpoint per AZ; disable at very low image-pull volume and let the NAT carry the traffic instead."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
