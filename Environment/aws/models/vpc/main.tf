# One NAT gateway total, not one per AZ — the resilience of per-AZ NAT
# doesn't matter for infra that's intentionally destroyed and recreated
# per test session, and it would double the NAT cost line for no benefit
# here. If this ever needs to look more production-like, flip
# single_nat_gateway to false.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS control plane needs to discover these to place ENIs / provision
  # internal vs internet-facing load balancers correctly.
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    # Karpenter's EC2NodeClass discovers subnets by this tag at the
    # environment level (models/karpenter sets subnetSelectorTerms to match
    # it) — keeps NodePool definitions free of hardcoded subnet IDs.
    "karpenter.sh/discovery" = var.cluster_name
  }
}
