terraform {
  required_version = ">= 1.9.0"

  backend "s3" {
    bucket       = "splitwise-tfstate-398915901412"
    key          = "envs/us-east-1/prod/01-cluster/terraform.tfstate"
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
  region = "us-east-1"
}
