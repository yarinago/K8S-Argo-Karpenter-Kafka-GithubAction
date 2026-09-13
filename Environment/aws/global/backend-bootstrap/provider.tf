terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # No backend block here on purpose: this is the one Terraform root that
  # creates the remote backend, so it can't use it. State for this root
  # stays local (terraform.tfstate in this directory, gitignored) and is
  # applied by hand, rarely, never through CI.
}

provider "aws" {
  region = var.region
}
