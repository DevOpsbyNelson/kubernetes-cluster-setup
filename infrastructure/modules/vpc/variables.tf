variable "name" {
  description = "Name prefix for the network resources (e.g. \"eks-cluster-development\")."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster that uses this network; subnets are tagged for its load balancers."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC, /16 to /20."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20, false)
    error_message = "vpc_cidr must be a valid CIDR block between /16 and /20."
  }
}

variable "az_count" {
  description = "Number of availability zones to use. EKS requires at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4 && floor(var.az_count) == var.az_count
    error_message = "az_count must be a whole number from 2 to 4."
  }
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway between all private subnets (cheaper) instead of one per availability zone (survives an AZ failure)."
  type        = bool
  default     = true
}
