locals {
  core_addons = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"])
}

# The version EKS recommends for this Kubernetes version (most_recent = false), so add-ons move
# along with a cluster upgrade and not at random.
data "aws_eks_addon_version" "this" {
  for_each = setunion(local.core_addons, ["aws-ebs-csi-driver"])

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = false
}

# Add-ons run on nodes and only become active once they have somewhere to run.
resource "aws_eks_addon" "core" {
  for_each = local.core_addons

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.value
  addon_version = data.aws_eks_addon_version.this[each.value].version

  # EKS pre-installs some of these; take them over on create, but keep manual tuning on update.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.default]
}

# Needed for PersistentVolumes on EBS. Gets its AWS permissions through the Pod Identity agent.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [aws_eks_addon.core, aws_iam_role_policy_attachment.ebs_csi]
}
