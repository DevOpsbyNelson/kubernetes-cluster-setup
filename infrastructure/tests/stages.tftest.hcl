# Tests for the per-stage (workspace) wiring of the root configuration. The AWS provider is mocked.
# `terraform test` always runs in the default workspace, so runs select a stage through var.stage.
# Run from infrastructure/: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/mock"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }

  mock_data "aws_eks_addon_version" {
    defaults = {
      version = "v1.0.0-eksbuild.1"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      certificate_authority = [{ data = "bW9jaw==" }]
    }
  }
}

run "default_workspace_is_rejected" {
  command = plan

  expect_failures = [terraform_data.stage_guard]
}

run "unknown_stage_is_rejected" {
  command = plan

  variables {
    stage = "qa"
  }

  expect_failures = [terraform_data.stage_guard]
}

run "development" {
  variables {
    stage = "development"
  }

  assert {
    condition     = output.cluster_name == "eks-cluster-development" && output.stage == "development"
    error_message = "The cluster must be named after project and stage."
  }

  assert {
    condition     = module.vpc.nat_gateway_count == 1 && length(module.vpc.private_subnet_ids) == 2
    error_message = "development must use the cheap network: 2 zones, 1 NAT gateway."
  }

  assert {
    condition     = local.stage_config.node_capacity_type == "SPOT" && !module.eks.deletion_protection
    error_message = "development must use disposable Spot nodes and allow deletion."
  }
}

run "staging" {
  variables {
    stage = "staging"
  }

  assert {
    condition     = output.cluster_name == "eks-cluster-staging"
    error_message = "The cluster must be named after project and stage."
  }

  assert {
    condition     = local.stage_config.node_capacity_type == "ON_DEMAND" && !module.eks.deletion_protection
    error_message = "staging must use on-demand nodes and allow deletion."
  }
}

run "production" {
  variables {
    stage = "production"
  }

  assert {
    condition     = output.cluster_name == "eks-cluster-production"
    error_message = "The cluster must be named after project and stage."
  }

  assert {
    condition     = module.vpc.nat_gateway_count == 3 && length(module.vpc.private_subnet_ids) == 3
    error_message = "production must survive a zone failure: 3 zones, a NAT gateway in each."
  }

  assert {
    condition     = module.eks.deletion_protection
    error_message = "The production cluster must be protected from deletion."
  }

  assert {
    condition     = local.stage_config.node_capacity_type == "ON_DEMAND" && local.stage_config.node_min_size >= 3
    error_message = "production must run on at least 3 on-demand nodes."
  }
}

run "override_unlocks_production" {
  variables {
    stage                       = "production"
    disable_deletion_protection = true
  }

  assert {
    condition     = !module.eks.deletion_protection
    error_message = "disable_deletion_protection must let the production cluster be deleted."
  }

  assert {
    condition     = local.stage_config.deletion_protection
    error_message = "The override must not change the stage's own setting."
  }
}

run "stage_networks_do_not_overlap" {
  command = plan

  variables {
    stage = "development"
  }

  assert {
    condition     = length(toset([for s in var.stages : s.vpc_cidr])) == length(var.stages)
    error_message = "Each stage needs its own VPC range, so the networks can be peered later."
  }
}

run "project_name_is_validated" {
  command = plan

  variables {
    stage        = "development"
    project_name = "Invalid_Name"
  }

  expect_failures = [var.project_name]
}
