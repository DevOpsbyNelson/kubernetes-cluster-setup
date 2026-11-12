output "role_arn" {
  description = "ECR push role. Set this as the AWS_DEPLOY_ROLE_ARN repository secret in GitHub."
  value       = aws_iam_role.deploy.arn
}

output "role_name" {
  description = "Name of the ECR push role."
  value       = aws_iam_role.deploy.name
}

output "infrastructure_role_arn" {
  description = "Terraform role for infrastructure/. Set this as the AWS_INFRA_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.infrastructure.arn
}

output "eks_deploy_role_arn" {
  description = "EKS deploy role. Set this as the AWS_EKS_DEPLOY_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.eks_deploy.arn
}

output "ecr_registry" {
  description = "Registry host of the ECR repositories."
  value       = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "URL of each ECR repository, by repository name."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider (created or existing)."
  value       = local.oidc_provider_arn
}

output "allowed_subjects" {
  description = "GitHub token subjects allowed to assume the roles."
  value       = local.allowed_subjects
}
