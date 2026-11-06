module "vpc" {
  source = "./modules/vpc"

  name               = local.name_prefix
  cluster_name       = local.name_prefix
  vpc_cidr           = local.stage_settings.vpc_cidr
  az_count           = local.stage_settings.az_count
  single_nat_gateway = local.stage_settings.single_nat_gateway
}

module "eks" {
  source = "./modules/eks"

  name               = local.name_prefix
  kubernetes_version = local.stage_settings.kubernetes_version
  support_type       = local.stage_settings.support_type
  subnet_ids         = module.vpc.private_subnet_ids

  public_access_cidrs          = var.public_access_cidrs
  cluster_admin_principal_arns = var.cluster_admin_principal_arns

  node_instance_types = local.stage_settings.node_instance_types
  node_capacity_type  = local.stage_settings.node_capacity_type
  node_min_size       = local.stage_settings.node_min_size
  node_desired_size   = local.stage_settings.node_desired_size
  node_max_size       = local.stage_settings.node_max_size
  node_disk_size_gib  = local.stage_settings.node_disk_size_gib

  log_retention_days  = local.stage_settings.log_retention_days
  deletion_protection = !var.disable_deletion_protection && local.stage_settings.deletion_protection
}
