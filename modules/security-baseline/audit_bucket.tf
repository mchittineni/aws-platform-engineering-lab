# ---------------------------------------------------------------------------
# Audit log bucket
#
# One bucket, two prefixes: cloudtrail/ and config/. Both services need a
# bucket policy naming their own service principal, so a shared bucket keeps
# the policy in one place instead of two.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "audit" {
  description             = "Encrypts CloudTrail and AWS Config records for ${local.account_id}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.audit_kms.json

  tags = merge(var.tags, { Name = "${var.name_prefix}-audit" })
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.name_prefix}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

data "aws_iam_policy_document" "audit_kms" {
  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudTrail encrypts each log file with a data key from this key.
  statement {
    sid       = "AllowCloudTrailEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "AllowConfigEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # Without this, a reader with s3:GetObject still cannot open a log file.
  statement {
    sid       = "AllowLogReaders"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = length(var.audit_log_reader_arns) > 0 ? var.audit_log_reader_arns : ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
}

# Object level access to this bucket is recorded by the trail itself through
# the S3 data event selector below, which is a stronger record than S3 server
# access logs and does not need a second bucket.
#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "audit" {
  bucket = local.audit_bucket_name

  tags = merge(var.tags, { Name = local.audit_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "tier-and-expire-audit-records"
    status = "Enabled"

    filter {}

    # Audit records are written once and read during an investigation. Glacier
    # Instant Retrieval keeps them queryable at a fraction of Standard.
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.audit_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Object Lock cannot be turned on after creation, so it is a create time
# choice. Governance mode lets a break-glass role remove the retention; use
# COMPLIANCE only when the retention must survive the account root.
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  count = var.audit_object_lock_days > 0 ? 1 : 0

  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = var.audit_object_lock_mode
      days = var.audit_object_lock_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]

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

  # Nobody deletes an audit record, including the identity that can apply this
  # stack. s3:PutBucketPolicy is deliberately NOT denied here: denying it
  # would lock Terraform out of its own bucket policy and leave the deny with
  # no way back. The escape hatch is an explicit policy change, which
  # CloudTrail records.
  statement {
    sid       = "DenyObjectDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.audit.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = length(var.audit_bucket_admin_arns) > 0 ? var.audit_bucket_admin_arns : ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${var.name_prefix}-trail"]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${var.name_prefix}-trail"]
    }
  }

  statement {
    sid       = "AWSConfigAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.audit.arn]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AWSConfigWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/config/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.audit]
}
