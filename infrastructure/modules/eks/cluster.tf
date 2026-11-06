# Customer-managed key for Kubernetes secrets. Deleting it makes the cluster's secrets unreadable,
# hence the longest waiting period.
resource "aws_kms_key" "secrets" {
  description             = "Encrypts Kubernetes secrets of EKS cluster ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-eks-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# EKS would create this log group itself, without retention and outside of Terraform.
resource "aws_cloudwatch_log_group" "control_plane" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "this" {
  name                      = var.name
  version                   = var.kubernetes_version
  role_arn                  = aws_iam_role.cluster.arn
  enabled_cluster_log_types = var.control_plane_log_types
  deletion_protection       = var.deletion_protection

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # Access is managed with access entries only, not the aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  upgrade_policy {
    support_type = var.support_type
  }

  # The role must keep its permissions until the cluster is gone, and the log group must
  # exist before EKS starts logging.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_secrets_key,
    aws_cloudwatch_log_group.control_plane,
  ]
}

# --- Additional cluster admins -----------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin[each.value].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
