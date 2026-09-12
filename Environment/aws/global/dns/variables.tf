variable "region" {
  type    = string
  default = "us-east-1"
}

variable "domain_name" {
  description = "The registered domain. Must already exist as a Route53 hosted zone before applying this module. Defaulted (not just an example) since this is now a fixed, known value for this project — an unset required variable with no default meant every apply/destroy prompted interactively for it, which is how a stray \"yes\" (meant as the destroy confirmation) once got typed in here as the domain name instead, and failed the Route53 zone lookup on a zone literally named \"yes\"."
  type        = string
  default     = "splitwise.click"
}
