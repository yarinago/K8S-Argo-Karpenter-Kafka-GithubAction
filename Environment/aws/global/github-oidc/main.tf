data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# Trust policy is scoped to this exact repo, any branch — a fork, or any
# other repo (including the app repo), has no path to assume this role at
# all, but any branch of THIS repo can, on purpose: dev is deployable from
# any branch (terraform-aws-envs.yaml, target_dev), so the branch-level
# restriction that used to live here can't also express "prod only from
# main" — IAM has no visibility into which env a workflow run picked, only
# which ref it ran on. That check lives at the workflow level instead (see
# terraform-aws-envs.yaml's "Restrict prod to main" guard step) — this
# trust policy is deliberately not the enforcement point for it anymore.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.infra_repo}:ref:refs/heads/*",
        # Pull requests need plan (read-only) access too — the PR-plan
        # workflow (terraform-aws-validate.yaml) never applies or destroys
        # anything regardless of what this trust policy allows.
        "repo:${var.github_org}/${var.infra_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_terraform" {
  name               = "github-actions-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# Pragmatic choice for a solo-account project: the real access boundary is
# the trust policy above (which repo/branch can even assume this role), not
# fine-grained IAM here. A hand-written least-privilege policy covering
# VPC/EKS/IAM/Karpenter/Secrets Manager/Route53/ACM/SQS/Budgets would be
# hundreds of lines and drift out of sync with every new resource type this
# project adds. Revisit if this ever becomes a shared/team account.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
