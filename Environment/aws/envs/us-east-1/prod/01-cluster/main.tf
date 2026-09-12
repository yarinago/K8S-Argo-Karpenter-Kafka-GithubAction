locals {
  cluster_name = "splitwise-prod"
}

# Both of these ARNs are fully deterministic from the account ID and the
# fixed resource names global/*'s Terraform already gives them — no need to
# copy outputs between root modules by hand. If either resource is ever
# renamed in global/, update the two literals below to match.
data "aws_caller_identity" "current" {}

locals {
  admin_iam_user_arn      = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/terraform-bootstrap"
  github_actions_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/github-actions-terraform"
}

# Reads global/dns's own state directly — no domain_name variable needed
# here at all. dns already resolved the hosted zone once; every downstream
# root just reads its output instead of re-deriving or re-typing it.
data "terraform_remote_state" "dns" {
  backend = "s3"
  config = {
    bucket = "splitwise-tfstate-398915901412"
    key    = "global/dns/terraform.tfstate"
    region = "us-east-1"
  }
}

module "vpc" {
  source       = "../../../../models/vpc"
  name         = local.cluster_name
  cluster_name = local.cluster_name
  # Different /16 than dev's 10.0.0.0/16 — the two VPCs are never peered
  # (fully separate clusters, on purpose), but non-overlapping CIDRs cost
  # nothing now and avoid a real headache if they're ever connected later.
  vpc_cidr = "10.1.0.0/16"
}

module "eks" {
  source                  = "../../../../models/eks"
  cluster_name             = local.cluster_name
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  bootstrap_instance_type  = "t3.large"
  admin_principal_arn      = [local.admin_iam_user_arn, local.github_actions_role_arn]
}

module "karpenter" {
  source       = "../../../../models/karpenter"
  cluster_name = local.cluster_name
}

module "secrets" {
  source       = "../../../../models/secrets"
  path_prefix  = "splitwise/prod"
  secret_names = ["kafka-credentials", "app-config"]
  # jsonencode happens here so whoever supplies splitwise_app_config (via
  # a gitignored terraform.tfvars or TF_VAR_splitwise_app_config) just
  # writes a normal flat HCL map — no manual JSON-string-escaping — and
  # it lands in Secrets Manager as the JSON blob the app repo's
  # ExternalSecret (k8s/overlays/aws-prod) expects to extract keys from.
  secret_values = length(var.splitwise_app_config) == 0 ? {} : {
    "app-config" = jsonencode(var.splitwise_app_config)
  }
}

module "iam_oidc" {
  source               = "../../../../models/iam-oidc"
  cluster_name          = local.cluster_name
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = module.eks.oidc_provider_url
  node_iam_role_arn     = module.karpenter.node_iam_role_arn
  secrets_path_prefix   = "splitwise/prod/"
  hosted_zone_arn       = "arn:aws:route53:::hostedzone/${data.terraform_remote_state.dns.outputs.hosted_zone_id}"
}

# Standalone, not inside models/eks's cluster_addons — see the comment on
# that module's cluster_addons block for why (needs module.iam_oidc's
# role, which needs this same cluster's OIDC provider, which doesn't
# exist until the cluster itself is created).
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.iam_oidc.ebs_csi_driver_role_arn
}
