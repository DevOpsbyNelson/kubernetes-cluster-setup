variable "name" {
  description = "Cluster name, also the prefix of its related resources (e.g. \"eks-cluster-development\")."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.37\"."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like \"1.37\"."
  }
}

variable "support_type" {
  description = "EKS support policy. STANDARD: auto-upgraded when standard support ends. EXTENDED: stays on the version for longer, at a higher hourly price."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.support_type)
    error_message = "support_type must be STANDARD or EXTENDED."
  }
}

variable "subnet_ids" {
  description = "Private subnets for the control plane network interfaces and the nodes, in at least 2 availability zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS needs subnets in at least 2 availability zones."
  }
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. Requests still need valid IAM credentials."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.public_access_cidrs) > 0 && alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "public_access_cidrs must be a non-empty list of CIDR blocks."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM users/roles granted cluster-admin. Leave out the principal that creates the cluster: it is already an admin."
  type        = list(string)
  default     = []
}

variable "control_plane_log_types" {
  description = "Control plane components that send logs to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  description = "Days to keep control plane logs."
  type        = number
  default     = 30
}

variable "deletion_protection" {
  description = "Make EKS refuse to delete the cluster."
  type        = bool
  default     = false
}

variable "ami_type" {
  description = "AMI family of the nodes; must match the CPU architecture of node_instance_types."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_instance_types" {
  description = "EC2 instance types of the nodes. Changing them replaces the node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum number of nodes."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be at least 1: CoreDNS and the add-ons need a node to become active."
  }
}

variable "node_desired_size" {
  description = "Number of nodes when the node group is created. Later changes are ignored, so an autoscaler can manage it."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
    error_message = "node_desired_size must be between node_min_size and node_max_size."
  }
}

variable "node_max_size" {
  description = "Maximum number of nodes."
  type        = number
  default     = 3
}

variable "node_disk_size_gib" {
  description = "Size of each node's root volume in GiB."
  type        = number
  default     = 20
}
