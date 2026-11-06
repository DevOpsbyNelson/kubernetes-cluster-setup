output "stage" {
  description = "Deployment stage (Terraform workspace) these outputs belong to."
  value       = local.stage
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "URL of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate of the cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "kubernetes_version" {
  description = "Kubernetes version of the control plane."
  value       = module.eks.kubernetes_version
}

output "vpc_id" {
  description = "ID of the cluster's VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets, used by the nodes and internal load balancers."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnets, used by NAT gateways and internet-facing load balancers."
  value       = module.vpc.public_subnet_ids
}

output "configure_kubectl" {
  description = "Command that adds this cluster to your kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
