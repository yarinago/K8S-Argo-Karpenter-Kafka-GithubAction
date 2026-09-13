output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "infrastructure_namespace" {
  value = kubernetes_namespace.infrastructure.metadata[0].name
}

output "external_secrets_namespace" {
  value = kubernetes_namespace.external_secrets.metadata[0].name
}

# Retrieve the initial Argo CD admin password after apply with:
#   aws eks update-kubeconfig --name splitwise-dev --region us-east-1
#   kubectl -n argocd get secret argocd-initial-admin-secret \
#     -o jsonpath="{.data.password}" | base64 -d; echo
