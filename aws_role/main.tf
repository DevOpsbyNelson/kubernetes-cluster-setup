locals {
  github_oidc_host = "token.actions.githubusercontent.com"

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # GitHub puts "repo:<repository>:environment:<name>" in the token's sub claim for jobs that use
  # `environment:`, so only those jobs can assume the role. With GitHub's immutable subject
  # the repository part also carries the numeric IDs: "<owner>@<owner_id>/<repo>@<repo_id>".
  subject_repository = var.github_repository_id == null ? var.github_repository : format(
    "%s@%d/%s@%d",
    split("/", var.github_repository)[0], var.github_repository_owner_id,
    split("/", var.github_repository)[1], var.github_repository_id,
  )
  allowed_subjects = [for env in var.github_environments : "repo:${local.subject_repository}:environment:${env}"]
}

# One GitHub OIDC provider per AWS account. With create_oidc_provider = false the existing one is used.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://${local.github_oidc_host}"
}

# Holds the image built from service/. Shared by all stages, so one image can be promoted through them.
# Immutable tags stop a later push from replacing an image that is already deployed.
resource "aws_ecr_repository" "service" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  description          = "Assumed by GitHub Actions (${var.github_repository}) via OIDC to push images to ECR."
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsOIDC"
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.github_oidc_host}:aud" = "sts.amazonaws.com"
          "${local.github_oidc_host}:sub" = local.allowed_subjects
        }
      }
    }]
  })
}

# Least privilege: log in to ECR and push to the service repository only.
resource "aws_iam_role_policy" "deploy" {
  name = "${var.project_name}-ecr-push"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # This action has no resource-level permissions: AWS requires "*".
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.service.arn
      },
    ]
  })
}
