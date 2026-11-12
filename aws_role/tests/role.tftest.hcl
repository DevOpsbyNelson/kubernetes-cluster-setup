# Unit tests for the ECR repositories and the GitHub Actions OIDC roles. The AWS provider is mocked:
# no credentials needed, nothing is created. Run from aws_role/: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/existing"
    }
  }
}

variables {
  github_repository = "acme/site"
  state_bucket_name = "acme-tfstate"
}

run "trust_policy_is_limited_to_repo_environments" {
  assert {
    condition = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:acme/site:environment:development",
      "repo:acme/site:environment:staging",
      "repo:acme/site:environment:production",
    ]
    error_message = "Only the repo's development/staging/production environments may assume the role."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The token audience must be sts.amazonaws.com."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "The role must be assumed with a web identity token."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github[0].arn
    error_message = "By default the OIDC provider is created and trusted."
  }

  assert {
    condition = (
      aws_iam_role.infrastructure.assume_role_policy == aws_iam_role.deploy.assume_role_policy &&
      aws_iam_role.eks_deploy.assume_role_policy == aws_iam_role.deploy.assume_role_policy
    )
    error_message = "All roles must trust the same GitHub jobs."
  }

  assert {
    condition = (
      aws_iam_role.deploy.name == "github-actions-ecr-push" &&
      aws_iam_role.infrastructure.name == "github-actions-eks-infrastructure" &&
      aws_iam_role.eks_deploy.name == "github-actions-eks-deploy" &&
      aws_iam_role.deploy.max_session_duration == 3600
    )
    error_message = "Role names and session length must use the defaults."
  }
}

run "reuses_existing_oidc_provider" {
  variables {
    create_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "No provider may be created when create_oidc_provider = false."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/existing"
    error_message = "The existing provider must be trusted."
  }
}

run "ecr_repositories_are_hardened" {
  assert {
    condition = toset([for repo in aws_ecr_repository.this : repo.name]) == toset([
      "eks-cluster/alertmanager",
      "eks-cluster/alloy",
      "eks-cluster/grafana",
      "eks-cluster/loki",
      "eks-cluster/prometheus",
      "eks-cluster/service",
      "eks-cluster/tempo",
    ])
    error_message = "There must be one repository for the service and each observability image."
  }

  assert {
    condition     = alltrue([for repo in aws_ecr_repository.this : repo.image_tag_mutability == "IMMUTABLE"])
    error_message = "Image tags must be immutable."
  }

  assert {
    condition     = alltrue([for repo in aws_ecr_repository.this : repo.image_scanning_configuration[0].scan_on_push])
    error_message = "Images must be scanned on push."
  }

  assert {
    condition     = output.ecr_registry == "123456789012.dkr.ecr.us-east-1.amazonaws.com" && length(output.ecr_repository_urls) == 7
    error_message = "The registry and repository URLs must be exposed."
  }
}

run "push_policy_is_scoped" {
  assert {
    condition     = toset(one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "EcrPush"])) == toset([for repo in aws_ecr_repository.this : repo.arn])
    error_message = "Push permissions must be limited to this project's repositories."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Action if s.Resource == "*"]) == ["ecr:GetAuthorizationToken"]
    error_message = "Only ecr:GetAuthorizationToken may use Resource \"*\"."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : alltrue([for a in s.Action : startswith(a, "ecr:") && a != "ecr:*"])])
    error_message = "The push role may only have specific ECR actions."
  }
}

run "infrastructure_policy_is_scoped" {
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.infrastructure.policy).Statement : s.Resource if s.Sid == "TerraformStateObjects"]) == "arn:aws:s3:::acme-tfstate/env:/*"
    error_message = "State access must be limited to infrastructure/'s workspace states."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.infrastructure.policy).Statement :
      alltrue([for r in flatten([s.Resource]) : r == "arn:aws:iam::123456789012:role/eks-cluster-*"])
      if anytrue([for a in s.Action : startswith(a, "iam:") && !contains(["iam:CreateServiceLinkedRole", "iam:GetRole"], a)])
    ])
    error_message = "IAM changes must be limited to roles named eks-cluster-*."
  }

  assert {
    condition = toset(one([
      for s in jsondecode(aws_iam_role_policy.infrastructure.policy).Statement :
      s.Condition.ArnEquals["iam:PolicyARN"] if s.Sid == "ClusterRolePolicies"
      ])) == toset([
      "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
      "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    ])
    error_message = "Only the cluster's AWS managed policies may be attached."
  }

  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.infrastructure.policy).Statement :
      anytrue([for a in s.Action : contains(["iam:*", "s3:*", "kms:*", "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "iam:CreateUser", "iam:CreatePolicy"], a)])
    ])
    error_message = "The infrastructure role must not get broad IAM, S3 or KMS data permissions."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.infrastructure.policy).Statement :
      try(s.Condition.StringEquals["aws:RequestedRegion"], "") == "us-east-1"
      if contains(["Network", "Eks", "SecretsKey", "KubernetesLoadBalancers"], s.Sid)
    ])
    error_message = "EC2, EKS, KMS and load balancer permissions must be limited to the configured region."
  }

  assert {
    condition = toset(one([
      for s in jsondecode(aws_iam_role_policy.infrastructure.policy).Statement : s.Action if s.Sid == "KubernetesLoadBalancers"
      ])) == toset([
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTargetGroups",
    ])
    error_message = "Before a destroy, the infrastructure role must be able to find and delete the load balancers Kubernetes created, and nothing more."
  }
}

run "eks_deploy_policy_only_finds_clusters" {
  assert {
    condition     = jsondecode(aws_iam_role_policy.eks_deploy.policy).Statement[0].Action == ["eks:DescribeCluster"] && length(jsondecode(aws_iam_role_policy.eks_deploy.policy).Statement) == 1
    error_message = "The EKS deploy role may only describe clusters; Kubernetes access comes from access entries."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.eks_deploy.policy).Statement[0].Resource == "arn:aws:eks:us-east-1:123456789012:cluster/eks-cluster-*"
    error_message = "The EKS deploy role must be limited to this project's clusters."
  }
}

run "custom_environments" {
  variables {
    github_environments = ["prod"]
  }

  assert {
    condition     = output.allowed_subjects == ["repo:acme/site:environment:prod"]
    error_message = "allowed_subjects must follow github_environments."
  }
}

run "immutable_subject_uses_numeric_ids" {
  variables {
    github_repository_owner_id = 111
    github_repository_id       = 222
  }

  assert {
    condition = output.allowed_subjects == [
      "repo:acme@111/site@222:environment:development",
      "repo:acme@111/site@222:environment:staging",
      "repo:acme@111/site@222:environment:production",
    ]
    error_message = "Immutable subjects must include the owner and repository IDs."
  }
}

run "rejects_only_one_repository_id" {
  command = plan

  variables {
    github_repository_id = 222
  }

  expect_failures = [var.github_repository_id]
}

run "rejects_invalid_repository" {
  command = plan

  variables {
    github_repository = "not-a-repo"
  }

  expect_failures = [var.github_repository]
}

run "rejects_empty_environments" {
  command = plan

  variables {
    github_environments = []
  }

  expect_failures = [var.github_environments]
}

run "rejects_repositories_without_service" {
  command = plan

  variables {
    ecr_repositories = ["grafana"]
  }

  expect_failures = [var.ecr_repositories]
}

run "rejects_invalid_state_bucket" {
  command = plan

  variables {
    state_bucket_name = "Not_A_Bucket"
  }

  expect_failures = [var.state_bucket_name]
}
