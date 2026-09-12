data "aws_caller_identity" "current" {}

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

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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
  name = "terraform-bootstrap"
}

# Idempotent at the AWS API level even if this policy is already attached
# out-of-band (AttachUserPolicy on an already-attached ARN just succeeds),
# so this needs no import step of its own.
resource "aws_iam_user_policy_attachment" "terraform_bootstrap_admin" {
  user       = aws_iam_user.terraform_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
