output "cluster_name" {
  description = "Name of the cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate of the cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "kubernetes_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group EKS created for the control plane and nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "ARN of the nodes' IAM role."
  value       = aws_iam_role.node.arn
}

output "node_group_name" {
  description = "Name of the managed node group."
  value       = aws_eks_node_group.default.node_group_name
}

output "deletion_protection" {
  description = "Whether EKS refuses to delete the cluster."
  value       = aws_eks_cluster.this.deletion_protection
}
