output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.oidc_provider_url
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "karpenter_node_iam_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue_name" {
  value = module.karpenter.interruption_queue_name
}

output "karpenter_controller_role_arn" {
  value = module.iam_oidc.karpenter_controller_role_arn
}

output "external_dns_role_arn" {
  value = module.iam_oidc.external_dns_role_arn
}

output "external_secrets_role_arn" {
  value = module.iam_oidc.external_secrets_role_arn
}

output "alb_controller_role_arn" {
  value = module.iam_oidc.alb_controller_role_arn
}

output "secret_arns" {
  value = module.secrets.secret_arns
}
