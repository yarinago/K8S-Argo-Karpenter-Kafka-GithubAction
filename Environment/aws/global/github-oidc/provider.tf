terraform {
  required_version = ">= 1.9.0"

  # Still applied by hand, never through CI — that protection comes from
  # CI's own workflow scripts simply never being written to touch this
  # root, not from where its state happens to live. State location and
  # "who's allowed to apply this" are independent questions; only
  # backend-bootstrap has an actual technical reason to stay local (it
  # creates this very bucket, so it can't use it yet).
  backend "s3" {
    bucket       = "splitwise-tfstate-398915901412"
    key          = "global/github-oidc/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}
