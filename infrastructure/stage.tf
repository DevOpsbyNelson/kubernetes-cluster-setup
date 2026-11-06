locals {
  # The Terraform workspace is the deployment stage (development, staging, production).
  stage        = coalesce(var.stage, terraform.workspace)
  stage_config = lookup(var.stages, local.stage, null)
  name_prefix  = "${var.project_name}-${local.stage}"

  # Values passed to the modules. The placeholder for an unknown stage only lets the plan reach
  # stage_guard's clear error message; it is never applied because that guard fails the plan.
  stage_settings = coalesce(local.stage_config, {
    kubernetes_version  = "1.37"
    support_type        = "STANDARD"
    vpc_cidr            = "10.0.0.0/16"
    az_count            = 2
    single_nat_gateway  = true
    node_instance_types = ["t3.medium"]
    node_capacity_type  = "ON_DEMAND"
    node_min_size       = 1
    node_desired_size   = 1
    node_max_size       = 1
    node_disk_size_gib  = 20
    log_retention_days  = 1
    deletion_protection = false
  })
}

# Fails plan/apply early when the selected workspace is not a configured stage (e.g. "default").
resource "terraform_data" "stage_guard" {
  lifecycle {
    precondition {
      condition     = local.stage_config != null
      error_message = "Workspace \"${terraform.workspace}\" is not a configured stage. Run `terraform workspace select <stage>` with one of: ${join(", ", keys(var.stages))}."
    }

    # var.stage must not point a stage's workspace at another stage's resources.
    precondition {
      condition     = var.stage == null || terraform.workspace == "default" || var.stage == terraform.workspace
      error_message = "var.stage (\"${coalesce(var.stage, "-")}\") does not match workspace \"${terraform.workspace}\". Leave var.stage unset outside of tests."
    }
  }
}
