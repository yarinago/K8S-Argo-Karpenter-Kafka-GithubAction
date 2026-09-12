output "karpenter_controller_role_arn" {
  value = module.karpenter_irsa.role_arn
}

output "external_dns_role_arn" {
  value = module.external_dns_irsa.role_arn
}

output "external_secrets_role_arn" {
  value = module.external_secrets_irsa.role_arn
}

output "alb_controller_role_arn" {
  value = module.alb_controller_irsa.role_arn
}
