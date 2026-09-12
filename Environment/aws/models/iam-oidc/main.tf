data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- Karpenter controller -----------------------------------------------
# Actions per Karpenter's own getting-started IAM policy — verify against
# https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/
# before first apply; these are revised across Karpenter minor versions.
data "aws_iam_policy_document" "karpenter" {
  statement {
    sid    = "AllowScopedEC2InstanceActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowScopedEC2DescribeActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowPricing"
    effect    = "Allow"
    actions   = ["pricing:GetProducts", "ssm:GetParameter"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowPassingInstanceRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.node_iam_role_arn]
  }

  statement {
    sid    = "AllowInstanceProfileManagement"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowEKSClusterRead"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = ["arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.cluster_name}-karpenter"]
  }
}

module "karpenter_irsa" {
  source            = "../iam-oidc/irsa-role"
  role_name         = "${var.cluster_name}-karpenter-controller"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  namespace         = "kube-system"
  service_account   = "karpenter"
  policy_json       = data.aws_iam_policy_document.karpenter.json
}

# --- external-dns ---------------------------------------------------------
data "aws_iam_policy_document" "external_dns" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [var.hosted_zone_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

module "external_dns_irsa" {
  source            = "../iam-oidc/irsa-role"
  role_name         = "${var.cluster_name}-external-dns"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  namespace         = "infrastructure"
  service_account   = "external-dns"
  policy_json       = data.aws_iam_policy_document.external_dns.json
}

# --- external-secrets -------------------------------------------------
# Scoped to this cluster's own environment path only — the dev cluster's
# ESO role cannot read splitwise/prod/* secrets and vice versa, since each
# cluster has an entirely separate OIDC provider/role, not just a namespace
# boundary.
data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_path_prefix}*"]
  }
}

module "external_secrets_irsa" {
  source            = "../iam-oidc/irsa-role"
  role_name         = "${var.cluster_name}-external-secrets"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  namespace         = "external-secrets"
  service_account   = "external-secrets"
  policy_json       = data.aws_iam_policy_document.external_secrets.json
}

# --- AWS Load Balancer Controller -----------------------------------------
# Policy JSON is NOT hand-written here — it's ~40 statements maintained
# upstream and revised with each controller release. Fetch the canonical
# version once before first apply:
#   curl -o files/alb-controller-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# and re-fetch it whenever the controller's Helm chart version bumps.
module "alb_controller_irsa" {
  source            = "../iam-oidc/irsa-role"
  role_name         = "${var.cluster_name}-alb-controller"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url
  namespace         = "infrastructure"
  service_account   = "aws-load-balancer-controller"
  policy_json       = file("${path.module}/files/alb-controller-policy.json")
}
