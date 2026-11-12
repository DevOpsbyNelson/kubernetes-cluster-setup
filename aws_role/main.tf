data "aws_caller_identity" "current" {}

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  account_id       = data.aws_caller_identity.current.account_id

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # GitHub puts "repo:<repository>:environment:<name>" in the token's sub claim for jobs that use
  # `environment:`, so only those jobs can assume the roles. With GitHub's immutable subject
  # the repository part also carries the numeric IDs: "<owner>@<owner_id>/<repo>@<repo_id>".
  subject_repository = var.github_repository_id == null ? var.github_repository : format(
    "%s@%d/%s@%d",
    split("/", var.github_repository)[0], var.github_repository_owner_id,
    split("/", var.github_repository)[1], var.github_repository_id,
  )
  allowed_subjects = [for env in var.github_environments : "repo:${local.subject_repository}:environment:${env}"]

  # Every role here trusts the same GitHub jobs.
  github_trust_policy = jsonencode({
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

  # Names that infrastructure/ gives its clusters, IAM roles and log groups: <project_name>-<stage>...
  cluster_arn_pattern  = "arn:aws:eks:${var.aws_region}:${local.account_id}:cluster/${var.project_name}-*"
  cluster_role_pattern = "arn:aws:iam::${local.account_id}:role/${var.project_name}-*"
  cluster_logs_pattern = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/eks/${var.project_name}-*"
  state_bucket_arn     = "arn:aws:s3:::${var.state_bucket_name}"
  region_condition     = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
  cluster_role_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]
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

# --- ECR repositories --------------------------------------------------------------------------

# One repository per image: service/ and each folder in observability/. Shared by all stages, so
# one image can be promoted through them. Immutable tags stop a later push from replacing an image
# that is already deployed.
resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.ecr_namespace}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# The service repository existed before the observability ones; keep it instead of replacing it.
moved {
  from = aws_ecr_repository.service
  to   = aws_ecr_repository.this["service"]
}

# --- Role that pushes images -------------------------------------------------------------------

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  description          = "Assumed by GitHub Actions (${var.github_repository}) via OIDC to push images to ECR."
  max_session_duration = var.max_session_duration
  assume_role_policy   = local.github_trust_policy
}

# Least privilege: log in to ECR and push to this project's repositories only.
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
        Resource = [for repo in aws_ecr_repository.this : repo.arn]
      },
    ]
  })
}

# --- Role that runs Terraform in infrastructure/ -----------------------------------------------

resource "aws_iam_role" "infrastructure" {
  name                 = var.infrastructure_role_name
  description          = "Assumed by GitHub Actions (${var.github_repository}) via OIDC to run Terraform in infrastructure/."
  max_session_duration = var.max_session_duration
  assume_role_policy   = local.github_trust_policy
}

# What infrastructure/ creates: a VPC, an EKS cluster with its node group and add-ons, a KMS key,
# a log group and the cluster's IAM roles. IAM is limited to roles named <project_name>-*, and only
# the AWS managed policies the cluster uses can be attached. The role can still write inline
# policies on those roles, so treat it as highly privileged: keep the environments protected.
resource "aws_iam_role_policy" "infrastructure" {
  name = "${var.project_name}-infrastructure"
  role = aws_iam_role.infrastructure.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TerraformStateList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = local.state_bucket_arn
      },
      {
        # One state per workspace (env:/<stage>/...) and its lock file. Other keys in the bucket,
        # such as this folder's own state, stay out of reach.
        Sid      = "TerraformStateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.state_bucket_arn}/env:/*"
      },
      {
        Sid       = "Network"
        Effect    = "Allow"
        Action    = ["ec2:*"]
        Resource  = "*"
        Condition = local.region_condition
      },
      {
        Sid       = "Eks"
        Effect    = "Allow"
        Action    = ["eks:*"]
        Resource  = "*"
        Condition = local.region_condition
      },
      {
        # Before a destroy, infrastructure/scripts/delete-k8s-resources.sh deletes the load balancers
        # Kubernetes created for the cluster: Terraform doesn't track them, and they would block
        # deleting the VPC. (Volumes and security groups are covered by ec2:* above.)
        Sid    = "KubernetesLoadBalancers"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroups",
        ]
        Resource  = "*"
        Condition = local.region_condition
      },
      {
        # Manage the key that encrypts Kubernetes secrets, without using it to encrypt or decrypt.
        Sid    = "SecretsKey"
        Effect = "Allow"
        Action = [
          "kms:CreateAlias",
          "kms:CreateGrant",
          "kms:CreateKey",
          "kms:DeleteAlias",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateAlias",
        ]
        Resource  = "*"
        Condition = local.region_condition
      },
      {
        Sid      = "ControlPlaneLogs"
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = local.cluster_logs_pattern
      },
      {
        Sid      = "ControlPlaneLogsRead"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "ClusterRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRolePolicies",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
        ]
        Resource = local.cluster_role_pattern
      },
      {
        Sid       = "ClusterRolePolicies"
        Effect    = "Allow"
        Action    = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource  = local.cluster_role_pattern
        Condition = { ArnEquals = { "iam:PolicyARN" = local.cluster_role_policies } }
      },
      {
        Sid       = "PassClusterRoles"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = local.cluster_role_pattern
        Condition = { StringEquals = { "iam:PassedToService" = ["eks.amazonaws.com", "pods.eks.amazonaws.com"] } }
      },
      {
        # EKS, its node groups and Spot capacity each need a service-linked role the first time.
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "autoscaling.amazonaws.com",
              "eks.amazonaws.com",
              "eks-nodegroup.amazonaws.com",
              "spot.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid      = "ServiceLinkedRolesRead"
        Effect   = "Allow"
        Action   = ["iam:GetRole"]
        Resource = "arn:aws:iam::${local.account_id}:role/aws-service-role/*"
      },
    ]
  })
}

# --- Role that deploys to the clusters ---------------------------------------------------------

# Only finds the clusters. What it may do inside them comes from an EKS access entry, which
# infrastructure/ creates when this role's ARN is in cluster_admin_principal_arns.
resource "aws_iam_role" "eks_deploy" {
  name                 = var.eks_deploy_role_name
  description          = "Assumed by GitHub Actions (${var.github_repository}) via OIDC to deploy to the EKS clusters."
  max_session_duration = var.max_session_duration
  assume_role_policy   = local.github_trust_policy
}

resource "aws_iam_role_policy" "eks_deploy" {
  name = "${var.project_name}-eks-deploy"
  role = aws_iam_role.eks_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "FindClusters"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = local.cluster_arn_pattern
    }]
  })
}
