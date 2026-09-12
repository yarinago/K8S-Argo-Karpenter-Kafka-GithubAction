terraform {
  required_version = ">= 1.9.0"

  # Unlike backend-bootstrap (creates this backend, so it can't use it
  # yet), dns has no technical reason to stay local — same as
  # github-oidc, it's still applied by hand (domain registration is a
  # manual, real-money action either way), but "applied by hand" is about
  # who runs apply, not where state lives. Storing it in the shared
  # backend lets other roots (envs/*/01-cluster) read
  # hosted_zone_id/certificate_arn via terraform_remote_state instead of
  # taking domain_name as a redundant variable of their own.
  backend "s3" {
    bucket       = "splitwise-tfstate-398915901412"
    key          = "global/dns/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}
