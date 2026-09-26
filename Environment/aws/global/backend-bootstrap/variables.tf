variable "region" {
  description = "AWS region for the shared Terraform backend."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used as a naming prefix for shared resources."
  type        = string
  default     = "splitwise"
}
