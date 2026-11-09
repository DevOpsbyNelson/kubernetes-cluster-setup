output "role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN secret in GitHub."
  value       = aws_iam_role.deploy.arn
}

output "role_name" {
  description = "Name of the ECR push role."
  value       = aws_iam_role.deploy.name
}

output "ecr_repository_url" {
  description = "URL to tag and push the service image to."
  value       = aws_ecr_repository.service.repository_url
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider (created or existing)."
  value       = local.oidc_provider_arn
}

output "allowed_subjects" {
  description = "GitHub token subjects allowed to assume the role."
  value       = local.allowed_subjects
}
