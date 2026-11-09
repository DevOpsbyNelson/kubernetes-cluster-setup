variable "aws_region" {
  description = "AWS region for the provider (IAM itself is global)."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the role, as \"owner/repo\"."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like \"owner/repo\"."
  }
}

variable "github_repository_owner_id" {
  description = "Numeric ID of the repository owner. Set together with github_repository_id when the repository uses GitHub's immutable OIDC subject (repo:<owner>@<owner_id>/<repo>@<repo_id>:...)."
  type        = number
  default     = null
}

variable "github_repository_id" {
  description = "Numeric ID of the repository (see github_repository_owner_id)."
  type        = number
  default     = null

  validation {
    condition     = (var.github_repository_id == null) == (var.github_repository_owner_id == null)
    error_message = "Set both github_repository_owner_id and github_repository_id, or neither."
  }
}

variable "github_environments" {
  description = "GitHub environments whose jobs may assume the role."
  type        = list(string)
  default     = ["development", "staging", "production"]

  validation {
    condition     = length(var.github_environments) > 0 && alltrue([for e in var.github_environments : can(regex("^[a-z0-9-]+$", e))])
    error_message = "github_environments must be a non-empty list of lowercase names (letters, numbers, hyphens)."
  }
}

variable "project_name" {
  description = "Project name used for the role policy name and the Project tag."
  type        = string
  default     = "eks-cluster"
}

variable "role_name" {
  description = "Name of the IAM role that GitHub Actions assumes."
  type        = string
  default     = "github-actions-ecr-push"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the image built from service/. It is created here and is the only repository the role can push to."
  type        = string
  default     = "eks-cluster/service"

  validation {
    condition     = length(var.ecr_repository_name) >= 2 && length(var.ecr_repository_name) <= 256 && can(regex("^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$", var.ecr_repository_name))
    error_message = "ecr_repository_name must be 2-256 lowercase characters: letters and numbers separated by '.', '_', '-' or '/'."
  }
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Set to false when the AWS account already has one (only one is allowed per account)."
  type        = bool
  default     = true
}

variable "max_session_duration" {
  description = "Maximum session length in seconds for the assumed role (3600-43200)."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}
