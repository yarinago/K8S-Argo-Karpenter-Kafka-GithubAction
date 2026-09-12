resource "kubernetes_namespace" "infrastructure" {
  metadata {
    name = "infrastructure"
  }
}

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

# --- Karpenter -------------------------------------------------------------
# Runs in kube-system on the bootstrap node group — the only node that
# exists before Karpenter itself can provision anything. No taint/
# toleration dance needed here since models/eks deliberately left the
# bootstrap node group untainted (see its main.tf comment for why).
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version

  set {
    name  = "settings.clusterName"
    value = local.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = data.terraform_remote_state.cluster.outputs.karpenter_interruption_queue_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.cluster.outputs.karpenter_controller_role_arn
  }
}

# Two capacity profiles per Milestone 6 — general (everyday workloads:
# Splitwise app, Kafka, monitoring) and batch (compute-heavy, sized for
# splitwise-loadgen). Schema verified against the real, current example
# manifests in aws/karpenter-provider-aws (karpenter.sh/v1 +
# karpenter.k8s.aws/v1, EC2NodeClass.spec.role takes a role NAME), not
# assumed from training data.
resource "kubectl_manifest" "ec2nodeclass_general" {
  depends_on = [helm_release.karpenter]
  yaml_body  = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: general
    spec:
      role: ${data.terraform_remote_state.cluster.outputs.karpenter_node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      amiSelectorTerms:
        - alias: al2023@latest
  YAML
}

resource "kubectl_manifest" "nodepool_general" {
  depends_on = [kubectl_manifest.ec2nodeclass_general]
  yaml_body  = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: general
    spec:
      template:
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["m", "c"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: general
      limits:
        cpu: "${var.general_nodepool_cpu_limit}"
        memory: "${var.general_nodepool_memory_limit}"
  YAML
}

resource "kubectl_manifest" "ec2nodeclass_batch" {
  depends_on = [helm_release.karpenter]
  yaml_body  = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: batch
    spec:
      role: ${data.terraform_remote_state.cluster.outputs.karpenter_node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      amiSelectorTerms:
        - alias: al2023@latest
  YAML
}

resource "kubectl_manifest" "nodepool_batch" {
  depends_on = [kubectl_manifest.ec2nodeclass_batch]
  yaml_body  = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: batch
    spec:
      template:
        metadata:
          labels:
            workload-type: batch
        spec:
          taints:
            - key: workload-type
              value: batch
              effect: NoSchedule
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: batch
      limits:
        cpu: "${var.batch_nodepool_cpu_limit}"
        memory: "${var.batch_nodepool_memory_limit}"
  YAML
}

# --- AWS Load Balancer Controller ------------------------------------------
resource "helm_release" "alb_controller" {
  depends_on = [kubernetes_namespace.infrastructure]
  name       = "aws-load-balancer-controller"
  namespace  = kubernetes_namespace.infrastructure.metadata[0].name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version

  set {
    name  = "clusterName"
    value = local.cluster_name
  }

  set {
    name  = "region"
    value = "us-east-1"
  }

  set {
    name  = "vpcId"
    value = data.terraform_remote_state.cluster.outputs.vpc_id
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.cluster.outputs.alb_controller_role_arn
  }
}

# --- external-dns ------------------------------------------------------
resource "helm_release" "external_dns" {
  depends_on = [kubernetes_namespace.infrastructure]
  name       = "external-dns"
  namespace  = kubernetes_namespace.infrastructure.metadata[0].name
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version

  set {
    name  = "provider"
    value = "aws"
  }

  set {
    name  = "txtOwnerId"
    value = local.cluster_name
  }

  set {
    name  = "domainFilters[0]"
    value = var.domain_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.cluster.outputs.external_dns_role_arn
  }
}

# --- external-secrets --------------------------------------------------
resource "helm_release" "external_secrets" {
  depends_on = [kubernetes_namespace.external_secrets]
  name       = "external-secrets"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.external_secrets_chart_version

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.cluster.outputs.external_secrets_role_arn
  }
}

# Scoped to this cluster's own env path only (splitwise/prod/*) — see the
# IRSA policy in models/iam-oidc. This cluster's own OIDC provider/role
# means it can never resolve to dev's secret ARNs, and vice versa — not
# just a namespace boundary, a completely separate credential.
resource "kubectl_manifest" "cluster_secret_store" {
  depends_on = [helm_release.external_secrets]
  yaml_body  = <<-YAML
    apiVersion: external-secrets.io/v1
    kind: ClusterSecretStore
    metadata:
      name: aws-secrets-manager
    spec:
      provider:
        aws:
          service: SecretsManager
          region: us-east-1
          auth:
            jwt:
              serviceAccountRef:
                name: external-secrets
                namespace: ${kubernetes_namespace.external_secrets.metadata[0].name}
  YAML
}

# --- Argo CD -------------------------------------------------------------
# Mirrors the local bootstrap pattern: install Argo CD, then a root
# Application that fans out into everything else via app-of-apps. Points
# at root_app_path, which does not have real content yet (see
# ../../argocd/apps/README.md) — Argo CD will show it as an empty/erroring
# sync until that's built, the same way local's very first bootstrap did
# before Environment/local/argocd/apps existed.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
}

resource "kubectl_manifest" "argocd_root_app" {
  depends_on = [helm_release.argocd]
  yaml_body  = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: aws-bootstrap-root
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: ${var.infra_repo_url}
        targetRevision: ${var.gitops_revision}
        path: ${var.root_app_path}
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  YAML
}
