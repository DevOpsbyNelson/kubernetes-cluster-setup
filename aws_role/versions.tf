terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Remote state in S3. bucket, key and region are supplied at init time
  # (-backend-config=...), e.g. by .github/workflows/create_role.yml.
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Component = "github-actions-oidc"
      ManagedBy = "terraform"
    }
  }
}
