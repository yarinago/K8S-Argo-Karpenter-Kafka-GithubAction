data "aws_caller_identity" "current" {}

# Standard "delegate to IAM" key policy — functionally equivalent to what
# AWS applies by default when no policy is given (full account-root
# access), just made explicit rather than implicit. Real permission
# decisions still happen via IAM (AdministratorAccess for admins), not
# here; this just satisfies the requirement that a KMS key actually
# define a policy instead of relying on an implicit default.
data "aws_iam_policy_document" "tfstate_kms" {
  #checkov:skip=CKV_AWS_356:This is AWS's own standard "enable IAM user permissions" statement -- literally what the AWS Console generates by default for every new KMS key. It doesn't itself grant anyone any permission; it only delegates the decision to IAM, where AdministratorAccess (for admins) is the actual grant. Removing this "*" would make the key policy MORE restrictive than IAM, which is the opposite of the point.
  #checkov:skip=CKV_AWS_109:Same reasoning -- this statement enables IAM to manage permissions on the key, it doesn't perform permissions management itself.
  #checkov:skip=CKV_AWS_111:Same reasoning -- "kms:*" here is the standard delegation-to-IAM grant, not an unconstrained write grant to a principal; actual write access still requires a separate IAM allow.
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "tfstate" {
  description             = "Customer-managed key for the shared Terraform state bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.tfstate_kms.json
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

# One state bucket, shared by every root via distinct state keys
# (envs/us-east-1/dev/01-cluster/terraform.tfstate,
# global/dns/terraform.tfstate, etc.) set in each root's own backend
# block, mirroring that root's own directory path under Environment/aws. Locking uses S3's native
# lockfile mechanism (use_lockfile = true in each backend block) rather
# than a separate DynamoDB table — one less resource to create/destroy.
# Deleting an environment never touches this bucket; only
# destroy_environment.sh --nuke-backend does, and only after both
# environments are already destroyed.
resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_18:Access logging needs a second, separate logging-target bucket (never log to the bucket being logged) -- real setup cost for a Terraform state bucket only this project's own CI/CLI ever touches, not a public-facing data store with third-party access to audit.
  #checkov:skip=CKV_AWS_144:Cross-region replication is for data that's genuinely irreplaceable. This bucket only holds Terraform state, which is fully reconstructable by re-applying -- not worth doubling storage cost and a second region's infra to protect it.
  #checkov:skip=CKV2_AWS_62:Event notifications need an SNS/SQS/Lambda target with its own IAM wiring -- real setup cost with no clear consumer for "a Terraform state object changed" events in a solo-account project.
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # force_destroy = true, and intentionally no lifecycle
  # { prevent_destroy = true } — this project is explicitly
  # destroy/recreate-friendly by design. Versioning means every past state
  # write leaves an object version behind; without force_destroy, Terraform
  # refuses to delete a bucket that isn't truly empty (old versions
  # included), which is exactly the state a "destroy everything" run
  # leaves this bucket in.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Noncurrent state versions past 90 days are pure accumulated cost with no
# real recovery value this far out — versioning's actual safety net is the
# last few revisions, not a permanent, unbounded history.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    # Routes encrypt/decrypt through one cached per-bucket key rather than
    # a KMS API call on every single object read/write — directly targets
    # the per-request cost that's the real tradeoff of using a
    # customer-managed key over the AWS-managed default.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# terraform-bootstrap: the human admin identity this whole project
# authenticates as for every by-hand `terraform apply` (this root and
# global/github-oidc's first apply — see ../README.md) and the admin
# principal envs/*/01-cluster grants EKS console/kubectl access to. No
# access key is created here on purpose: this project has no long-lived,
# CI-facing credential anywhere — every workflow after this root and
# github-oidc's first apply authenticates via OIDC instead. Whatever
# key/session you already use locally (`aws configure`, SSO, CloudShell)
# to run the two by-hand applies is the only credential this identity ever
# needs.
#
# Almost certainly already exists by the time this runs, since it's the
# identity you're applying with. Creating an IAM user with a name that
# already exists is a hard AWS error (EntityAlreadyExists) — if you're
# adopting a pre-existing terraform-bootstrap user into this state for the
# first time, run this first:
#   terraform import aws_iam_user.terraform_bootstrap terraform-bootstrap
resource "aws_iam_user" "terraform_bootstrap" {
  #checkov:skip=CKV_AWS_273:This IS the identity that bootstraps SSO/OIDC for everything else in the project (github-oidc's first apply has nothing else to authenticate as yet -- see ../README.md's "Account Bootstrap"). A chicken-and-egg an IAM Identity Center policy can't resolve: something has to exist before any federated auth exists at all.
  name = "terraform-bootstrap"
}

# Idempotent at the AWS API level even if this policy is already attached
# out-of-band (AttachUserPolicy on an already-attached ARN just succeeds),
# so this needs no import step of its own.
resource "aws_iam_user_policy_attachment" "terraform_bootstrap_admin" {
  #checkov:skip=CKV_AWS_40:Attaching to a group would just be an extra layer of indirection for a group of exactly one user -- no real least-privilege benefit for a solo-account project's one bootstrap identity.
  #checkov:skip=CKV_AWS_274:Same reasoning as github-oidc's identical attachment (see that file) -- the real access boundary for this identity is that it's the one human operator's own credential, not a hand-written policy that would just drift out of sync with every new resource type this project adds.
  user       = aws_iam_user.terraform_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
