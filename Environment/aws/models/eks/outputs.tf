output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  # Without the https:// scheme, as required by the IRSA trust-policy
  # condition keys in models/iam-oidc.
  value = module.eks.oidc_provider
}

output "node_iam_role_arn" {
  value = module.eks.eks_managed_node_groups["bootstrap"].iam_role_arn
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}
