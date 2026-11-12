variable "aws_region" {
  description = "Region of the ECR repositories and the EKS clusters (IAM itself is global)."
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
  description = "project_name of infrastructure/. Its clusters, IAM roles and log groups are named <project_name>-<stage>..., which scopes the infrastructure and EKS deploy roles. Also used for policy names and the Project tag."
  type        = string
  default     = "eks-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-24 chars of lowercase letters, numbers and hyphens, like infrastructure/'s project_name."
  }
}

variable "role_name" {
  description = "Name of the IAM role that pushes images to ECR."
  type        = string
  default     = "github-actions-ecr-push"
}

variable "infrastructure_role_name" {
  description = "Name of the IAM role that runs Terraform in infrastructure/."
  type        = string
  default     = "github-actions-eks-infrastructure"
}

variable "eks_deploy_role_name" {
  description = "Name of the IAM role that deploys to the EKS clusters."
  type        = string
  default     = "github-actions-eks-deploy"
}

variable "ecr_namespace" {
  description = "Prefix of the ECR repository names: <ecr_namespace>/<repository>."
  type        = string
  default     = "eks-cluster"

  validation {
    condition     = can(regex("^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$", var.ecr_namespace))
    error_message = "ecr_namespace must be lowercase letters and numbers separated by '.', '_', '-' or '/'."
  }
}

variable "ecr_repositories" {
  description = "ECR repositories to create, one per image: service/ and each folder in observability/. The push role can push to these only."
  type        = list(string)
  default     = ["service", "alertmanager", "alloy", "grafana", "loki", "prometheus", "tempo"]

  validation {
    condition     = contains(var.ecr_repositories, "service") && alltrue([for r in var.ecr_repositories : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", r))])
    error_message = "ecr_repositories must include \"service\", and each name must be lowercase letters and numbers separated by '.', '_' or '-'."
  }
}

variable "state_bucket_name" {
  description = "S3 bucket with infrastructure/'s Terraform state (REMOTE_STORAGE_AWS_S3_BUCKET). The infrastructure role may only use its env:/ workspace states."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name."
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
