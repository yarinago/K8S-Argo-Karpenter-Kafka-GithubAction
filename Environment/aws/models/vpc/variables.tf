variable "name" {
  description = "Name prefix, e.g. \"splitwise-dev\"."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name that will live in this VPC — used for the subnet discovery tags Karpenter and the AWS Load Balancer Controller rely on."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Two AZs is enough for a demo environment that gets destroyed between test sessions — a third AZ has no real payoff here and only adds cost surface."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
