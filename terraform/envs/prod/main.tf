# Production environment for the Anubis Agent Server and the customer portal server.
#
# See ../../../architecture/scalable_architecture.md for the design and
# ../../../docs/runbook.md §1 for the deployment order. This file wires modules
# together and holds no logic of its own.

locals {
  name_prefix = "anubis-${var.environment}"

  tags = merge(var.tags, {
    Project     = "anubis"
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "anubis-scalable-server"
  })
}

module "network" {
  source = "../../modules/network"

  name_prefix                = local.name_prefix
  cluster_name               = local.name_prefix
  region                     = var.region
  vpc_cidr                   = var.vpc_cidr
  availability_zone_count    = var.availability_zone_count
  nat_gateway_count          = var.nat_gateway_count
  enable_interface_endpoints = var.enable_interface_endpoints

  tags = local.tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name            = local.name_prefix
  kubernetes_version      = var.kubernetes_version
  vpc_id                  = module.network.vpc_id
  private_subnet_ids      = module.network.private_subnet_ids
  public_subnet_ids       = module.network.public_subnet_ids
  api_public_access_cidrs = var.api_public_access_cidrs

  general_instance_type = var.general_instance_type
  general_disk_size_gb  = var.general_disk_size_gb
  general_desired_size  = var.general_desired_size
  general_min_size      = var.general_min_size
  general_max_size      = var.general_max_size

  media_instance_type = var.media_instance_type
  media_disk_size_gb  = var.media_disk_size_gb
  media_desired_size  = var.media_desired_size
  media_min_size      = var.media_min_size
  media_max_size      = var.media_max_size

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  name_prefix            = local.name_prefix
  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  node_security_group_id = module.eks.cluster_security_group_id
  admin_access_cidrs     = var.database_admin_cidrs

  postgres_version         = var.postgres_version
  instance_class           = var.rds_instance_class
  allocated_storage_gb     = var.rds_allocated_storage_gb
  max_allocated_storage_gb = var.rds_max_allocated_storage_gb
  multi_az                 = var.rds_multi_az
  backup_retention_days    = var.rds_backup_retention_days
  database_name            = var.database_name
  master_username          = var.database_username

  redis_version    = var.redis_version
  redis_node_type  = var.redis_node_type
  redis_node_count = var.redis_node_count

  tags = local.tags
}

module "registry" {
  source = "../../modules/registry"

  name_prefix                       = local.name_prefix
  repository_names                  = var.ecr_repository_names
  retained_image_count              = var.ecr_retained_image_count
  create_github_oidc_provider       = var.create_github_oidc_provider
  existing_github_oidc_provider_arn = var.existing_github_oidc_provider_arn
  github_allowed_subjects           = var.github_allowed_subjects
  soci_index_builder_function_name  = var.soci_index_builder_function_name

  tags = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name_prefix           = local.name_prefix
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = module.eks.oidc_provider_url
  application_namespace = var.application_namespace

  tags = local.tags
}

module "dns" {
  source = "../../modules/dns"

  domain_name        = var.domain_name
  hostnames          = var.hostnames
  create_hosted_zone = var.create_route53_zone

  # Empty on the first apply. After the Helm releases exist, read the ALB from the
  # Ingress status and set alb_dns_name / alb_zone_id, then apply again to create the
  # alias records. See docs/dns-cutover.md §4.
  alb_dns_name = var.alb_dns_name
  alb_zone_id  = var.alb_zone_id

  tags = local.tags
}
