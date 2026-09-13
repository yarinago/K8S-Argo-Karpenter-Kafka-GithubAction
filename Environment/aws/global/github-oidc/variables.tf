variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_org" {
  type    = string
  default = "yarinago"
}

variable "infra_repo" {
  description = "The infra repo allowed to assume the Terraform CI role. Deliberately NOT the app repo (splitwise-household-expenses) — that repo only ever needs GHCR push permissions, never AWS credentials, so it structurally cannot trigger a `terraform apply`."
  type        = string
  default     = "K8S-Argo-Karpenter-Kafka-GithubAction"
}
