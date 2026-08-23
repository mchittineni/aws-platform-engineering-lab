# ---------------------------------------------------------------------------
# Terraform state backend
#
# Bootstrap resource: apply this once with a local state file, then migrate the
# local state into the bucket it just created.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "state" {
  # No explicit key policy, so the default applies: the account root holds
  # kms:*, and access is governed by the IAM policies on the roles that use the
  # key. That is the model this repository uses deliberately — see the note in
  # docs/security.md. Writing an explicit policy incorrectly makes a key
  # permanently unusable, so it is a considered follow-up, not a quick fix.
  #checkov:skip=CKV2_AWS_64:Access is governed by IAM; default key policy is deliberate
  description             = "Encrypts Terraform state in ${var.bucket_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = var.bucket_name })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV2_AWS_62:Event notifications are not part of this design
  bucket = var.bucket_name

  tags = merge(var.tags, { Name = var.bucket_name })
}

# ---------------------------------------------------------------------------
# Access logs
#
# A separate bucket, because logging a bucket into itself makes every log
# write generate another log entry.
# ---------------------------------------------------------------------------

# The log bucket cannot log to itself without every log write producing
# another log entry, and it cannot use a customer managed key because the S3
# log delivery service has no access to one.
#tfsec:ignore:aws-s3-enable-bucket-logging
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket" "access_logs" {
  # An access log bucket is the end of the logging chain, so several bucket
  # checks cannot be satisfied by definition:
  #   - it cannot log to itself (CKV_AWS_18)
  #   - the S3 log delivery service cannot write to a CMK-encrypted bucket, so
  #     it stays on SSE-S3 (CKV_AWS_145)
  # The remaining three are resolution failures, not gaps: the public access
  # block, versioning and lifecycle all exist below, attached through a
  # count-indexed reference that Checkov does not follow.
  #checkov:skip=CKV_AWS_18:An access log bucket cannot log to itself
  #checkov:skip=CKV_AWS_145:S3 log delivery cannot write to a CMK-encrypted bucket
  #checkov:skip=CKV_AWS_21:Versioning is configured below, count-indexed
  #checkov:skip=CKV2_AWS_6:Public access block is configured below, count-indexed
  #checkov:skip=CKV2_AWS_61:Lifecycle configuration is defined below, count-indexed
  #checkov:skip=CKV2_AWS_62:Event notifications are not part of this design
  #checkov:skip=CKV_AWS_144:Single region is a documented known gap
  count = var.enable_access_logging ? 1 : 0

  bucket = "${var.bucket_name}-access-logs"

  tags = merge(var.tags, { Name = "${var.bucket_name}-access-logs" })
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    # The log delivery service writes with the bucket owner as the object
    # owner, which is what BucketOwnerEnforced requires.
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3 rather than SSE-KMS: the log delivery service cannot write to a
# bucket encrypted with a customer managed key.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    # The state bucket already does this. An abandoned multipart upload is
    # billed as storage but is invisible to a bucket listing, so without this
    # the access log bucket accrues cost nothing ever shows.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "state" {
  count = var.enable_access_logging ? 1 : 0

  bucket = aws_s3_bucket.state.id

  target_bucket = aws_s3_bucket.access_logs[0].id
  target_prefix = "state-access/"
}

# Versioning is what makes a corrupted or truncated state recoverable.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse any request that is not TLS or not using the state KMS key.
data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyUnencryptedObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# Cross region replication
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "replication_assume_role" {
  count = var.enable_replication ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  count = var.enable_replication ? 1 : 0

  name               = "${var.bucket_name}-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume_role[0].json

  tags = var.tags
}

data "aws_iam_policy_document" "replication" {
  count = var.enable_replication ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = ["${var.replica_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  count = var.enable_replication ? 1 : 0

  name   = "replication"
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "state" {
  count = var.enable_replication ? 1 : 0

  bucket = aws_s3_bucket.state.id
  role   = aws_iam_role.replication[0].arn

  rule {
    id     = "replicate-state"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = var.replica_bucket_arn
      storage_class = "STANDARD_IA"
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# ---------------------------------------------------------------------------
# Legacy DynamoDB state lock
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "lock" {
  count = var.enable_dynamodb_lock_table ? 1 : 0

  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(var.tags, { Name = var.dynamodb_table_name })
}
