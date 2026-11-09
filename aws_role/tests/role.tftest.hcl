# Unit tests for the GitHub Actions OIDC role that pushes to ECR. The AWS provider is mocked: no
# credentials needed, nothing is created. Run from aws_role/: terraform init -backend=false && terraform test

mock_provider "aws" {
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

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/eks-cluster/service"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/eks-cluster/service"
    }
  }
}

variables {
  github_repository = "acme/site"
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
    condition     = aws_iam_role.deploy.name == "github-actions-ecr-push" && aws_iam_role.deploy.max_session_duration == 3600
    error_message = "Role name and session length must use the defaults."
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

run "ecr_repository_is_hardened" {
  assert {
    condition     = aws_ecr_repository.service.name == "eks-cluster/service"
    error_message = "The repository must use the default name."
  }

  assert {
    condition     = aws_ecr_repository.service.image_tag_mutability == "IMMUTABLE"
    error_message = "Image tags must be immutable."
  }

  assert {
    condition     = aws_ecr_repository.service.image_scanning_configuration[0].scan_on_push
    error_message = "Images must be scanned on push."
  }

  assert {
    condition     = output.ecr_repository_url == "123456789012.dkr.ecr.us-east-1.amazonaws.com/eks-cluster/service"
    error_message = "The repository URL must be exposed for the push workflow."
  }
}

run "push_policy_is_scoped" {
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "EcrPush"]) == "arn:aws:ecr:us-east-1:123456789012:repository/eks-cluster/service"
    error_message = "Push permissions must be limited to the service repository."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Action if s.Resource == "*"]) == ["ecr:GetAuthorizationToken"]
    error_message = "Only ecr:GetAuthorizationToken may use Resource \"*\"."
  }

  assert {
    condition = contains(
      one([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Action if s.Sid == "EcrPush"]),
      "ecr:PutImage",
    )
    error_message = "The role must be able to push images."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : alltrue([for a in s.Action : startswith(a, "ecr:") && a != "ecr:*"])])
    error_message = "The role may only have specific ECR actions."
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

run "rejects_invalid_ecr_repository_name" {
  command = plan

  variables {
    ecr_repository_name = "Not/A_Valid-Name-"
  }

  expect_failures = [var.ecr_repository_name]
}
