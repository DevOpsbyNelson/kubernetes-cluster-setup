# Unit tests for the eks module. The AWS provider is mocked: no credentials needed, nothing is
# created. Run from modules/eks: terraform init && terraform test

mock_provider "aws" {
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

variables {
  name               = "test"
  kubernetes_version = "1.37"
  subnet_ids         = ["subnet-1", "subnet-2"]
}

run "cluster_is_hardened" {
  assert {
    condition     = one(aws_eks_cluster.this.access_config).authentication_mode == "API"
    error_message = "Access must use access entries, not the aws-auth ConfigMap."
  }

  assert {
    condition     = one(aws_eks_cluster.this.vpc_config).endpoint_private_access
    error_message = "Nodes must reach the API through the private endpoint."
  }

  assert {
    condition     = one(aws_eks_cluster.this.encryption_config).resources == toset(["secrets"]) && aws_kms_key.secrets.enable_key_rotation
    error_message = "Kubernetes secrets must be encrypted with a rotating key."
  }

  assert {
    condition     = aws_cloudwatch_log_group.control_plane.name == "/aws/eks/test/cluster" && aws_cloudwatch_log_group.control_plane.retention_in_days == 30
    error_message = "The log group must use the name EKS writes to, and have a retention."
  }

  assert {
    condition     = contains(aws_eks_cluster.this.enabled_cluster_log_types, "audit")
    error_message = "Audit logs must be on by default."
  }
}

run "nodes_are_hardened" {
  assert {
    condition     = one(aws_launch_template.node.metadata_options).http_tokens == "required"
    error_message = "Nodes must require IMDSv2."
  }

  assert {
    condition     = one(one(aws_launch_template.node.block_device_mappings).ebs).encrypted == "true"
    error_message = "Node disks must be encrypted."
  }

  assert {
    condition     = one(one(aws_launch_template.node.block_device_mappings).ebs).volume_type == "gp3" && one(one(aws_launch_template.node.block_device_mappings).ebs).volume_size == 20
    error_message = "Node disks must use gp3 and node_disk_size_gib."
  }
}

run "installs_addons" {
  assert {
    condition     = keys(aws_eks_addon.core) == ["coredns", "eks-pod-identity-agent", "kube-proxy", "vpc-cni"]
    error_message = "The core add-ons must be managed by Terraform."
  }

  assert {
    condition     = one(aws_eks_addon.ebs_csi.pod_identity_association).service_account == "ebs-csi-controller-sa"
    error_message = "The EBS CSI driver must get its permissions through Pod Identity."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ebs_csi.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "The EBS CSI role must trust EKS Pod Identity."
  }
}

run "no_extra_admins_by_default" {
  assert {
    condition     = length(aws_eks_access_entry.admin) == 0
    error_message = "Only the cluster creator is admin by default."
  }
}

run "extra_admins" {
  variables {
    cluster_admin_principal_arns = ["arn:aws:iam::123456789012:role/admins"]
  }

  assert {
    condition     = aws_eks_access_entry.admin["arn:aws:iam::123456789012:role/admins"].principal_arn == "arn:aws:iam::123456789012:role/admins"
    error_message = "Each admin principal needs an access entry."
  }

  assert {
    condition     = aws_eks_access_policy_association.admin["arn:aws:iam::123456789012:role/admins"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "Each admin principal needs the cluster admin policy."
  }
}

run "rejects_desired_size_out_of_range" {
  command = plan

  variables {
    node_min_size     = 2
    node_desired_size = 1
    node_max_size     = 3
  }

  expect_failures = [var.node_desired_size]
}

run "rejects_invalid_capacity_type" {
  command = plan

  variables {
    node_capacity_type = "RESERVED"
  }

  expect_failures = [var.node_capacity_type]
}

run "rejects_invalid_version" {
  command = plan

  variables {
    kubernetes_version = "latest"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_one_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-1"]
  }

  expect_failures = [var.subnet_ids]
}
