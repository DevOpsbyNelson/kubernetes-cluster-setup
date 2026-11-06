terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Remote state in S3. bucket, key, region (and optional credentials/endpoint) are supplied
  # at init time by scripts/terraform-init.sh. Each workspace gets its own state file at
  # env:/<workspace>/<key> in the bucket.
  backend "s3" {
    use_lockfile = true # S3-native state locking, no DynamoDB table needed
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = terraform.workspace
      ManagedBy   = "terraform"
    }
  }
}
