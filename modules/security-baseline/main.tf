# ---------------------------------------------------------------------------
# Account security baseline
#
# Account wide controls that no single environment can own, because they are
# singletons: one CloudTrail, one Config recorder, one GuardDuty detector, one
# password policy. They are applied by the bootstrap stack.
#
# The rule of thumb for what belongs here: if two environments both tried to
# create it, the second apply would fail.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  audit_bucket_name = coalesce(
    var.audit_bucket_name,
    "${var.name_prefix}-audit-${local.account_id}-${local.region}",
  )
}

# ---------------------------------------------------------------------------
# Block public S3 at the account level
#
# Per bucket settings can be undone by whoever owns the bucket. This one
# cannot, which is why it is worth setting even when every bucket is already
# private.
# ---------------------------------------------------------------------------

resource "aws_s3_account_public_access_block" "this" {
  count = var.enable_s3_account_public_access_block ? 1 : 0

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Encrypt every new EBS volume, including ones Terraform never sees
#
# The EKS launch templates already ask for encryption. This catches the volume
# someone creates by hand in the console.
# ---------------------------------------------------------------------------

resource "aws_ebs_encryption_by_default" "this" {
  count = var.enable_ebs_encryption_by_default ? 1 : 0

  enabled = true
}

# ---------------------------------------------------------------------------
# Console password policy
#
# Only relevant for break-glass IAM users. Every day to day identity should be
# federated, and CI uses OIDC.
# ---------------------------------------------------------------------------

resource "aws_iam_account_password_policy" "this" {
  count = var.enable_password_policy ? 1 : 0

  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
  hard_expiry                    = false
}
