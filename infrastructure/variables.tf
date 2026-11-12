variable "aws_region" {
  description = "AWS region for the cluster and its network."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix of the resource names; the cluster is named <project_name>-<stage>. Lowercase letters, numbers and hyphens only."
  type        = string
  default     = "eks-cluster"

  # 24 chars keeps "<project>-<stage>-" within EKS's 37-char limit on node group name prefixes.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-24 chars of lowercase letters, numbers and hyphens."
  }
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint. Requests still need valid IAM credentials."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arns" {
  description = "IAM users/roles granted cluster-admin. Leave out the principal that creates the cluster: it is already an admin."
  type        = list(string)
  default     = []
}

variable "disable_deletion_protection" {
  description = "Turn off the cluster's deletion protection, overriding stages[*].deletion_protection. Set only to tear a stage down."
  type        = bool
  default     = false
}

variable "stage" {
  description = "Stage to use instead of the workspace name. Meant for `terraform test`, which always runs in the default workspace; leave unset otherwise."
  type        = string
  default     = null
}

# Per-stage settings. The active stage is selected by the Terraform workspace name:
#   terraform workspace select development|staging|production
variable "stages" {
  description = "Settings for each deployment stage, keyed by Terraform workspace name."
  type = map(object({
    kubernetes_version  = string       # upgrade one minor version at a time, development first
    support_type        = string       # STANDARD (auto-upgraded at end of support) or EXTENDED (costs more, stays on the version)
    vpc_cidr            = string       # /16 to /20
    az_count            = number       # 2 to 4 availability zones
    single_nat_gateway  = bool         # true is cheaper; false keeps egress working when one AZ fails
    node_instance_types = list(string) # several types make Spot capacity easier to find
    node_capacity_type  = string       # ON_DEMAND or SPOT
    node_min_size       = number
    node_desired_size   = number # initial size only; see lifecycle in modules/eks/nodes.tf
    node_max_size       = number
    node_disk_size_gib  = number
    log_retention_days  = number # control plane logs in CloudWatch
    deletion_protection = bool   # EKS refuses to delete the cluster while this is on
  }))

  default = {
    development = {
      kubernetes_version  = "1.37"
      support_type        = "STANDARD"
      vpc_cidr            = "10.10.0.0/16"
      az_count            = 2
      single_nat_gateway  = true
      node_instance_types = ["t3.medium", "t3a.medium"]
      node_capacity_type  = "SPOT"
      node_min_size       = 1
      node_desired_size   = 2
      node_max_size       = 3
      node_disk_size_gib  = 20
      log_retention_days  = 7
      deletion_protection = false
    }
    staging = {
      kubernetes_version  = "1.37"
      support_type        = "STANDARD"
      vpc_cidr            = "10.20.0.0/16"
      az_count            = 2
      single_nat_gateway  = true
      node_instance_types = ["t3.large"]
      node_capacity_type  = "ON_DEMAND"
      node_min_size       = 2
      node_desired_size   = 2
      node_max_size       = 4
      node_disk_size_gib  = 30
      log_retention_days  = 14
      deletion_protection = false
    }
    # Sized for a practice project: the smallest setup that runs the service and the observability
    # stack, at the lowest cost. One Spot node fits every pod in cluster/; there is no zone redundancy.
    production = {
      kubernetes_version  = "1.37"
      support_type        = "STANDARD"
      vpc_cidr            = "10.30.0.0/16"
      az_count            = 2    # EKS needs subnets in at least 2 zones
      single_nat_gateway  = true # one NAT gateway instead of one per zone
      node_instance_types = ["t3.medium", "t3a.medium"]
      node_capacity_type  = "SPOT"
      node_min_size       = 1
      node_desired_size   = 1
      node_max_size       = 2
      node_disk_size_gib  = 20
      log_retention_days  = 7
      deletion_protection = false
    }
  }
}
