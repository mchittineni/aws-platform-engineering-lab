# ===========================================================================
# AWS bootstrap
#
# Run this once per AWS account, before any environment. It owns everything
# that is a singleton at the account level:
#
#   1. the encrypted, versioned S3 bucket that holds every other state file
#   2. the GitHub Actions OIDC provider and the CI roles, so no AWS access key
#      ever has to be stored in a GitHub secret
#   3. the security baseline: CloudTrail, Config, GuardDuty, Security Hub,
#      Access Analyzer, and the account level guardrails
#   4. budgets and cost anomaly detection
#
# The test for whether something belongs here: if two environments both tried
# to create it, the second apply would fail.
# ===========================================================================

locals {
  name_prefix = "aws-platform-lab"

  environments = ["dev", "staging", "production"]

  # The boundary policy has to name its own ARN in the deny statements that
  # stop it being detached or rewritten. Referencing aws_iam_policy.ci_boundary
  # from its own document would be a dependency cycle, so the ARN is composed
  # from the account and partition instead.
  ci_boundary_name = "${local.name_prefix}-ci-boundary"
  ci_boundary_arn  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name_prefix}-ci-boundary"

  common_tags = {
    Environment = "shared"
    Project     = "aws-platform-engineering-lab"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Remote state
# ---------------------------------------------------------------------------

module "state_backend" {
  source = "../../modules/tf-state-backend"

  bucket_name = var.state_bucket_name

  # Terraform 1.10+ locks through S3 conditional writes, so the DynamoDB table
  # is no longer needed.
  enable_dynamodb_lock_table = false

  noncurrent_version_expiration_days = 365

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# CI roles
#
# Two roles per environment. The plan role is read only and reachable from any
# pull request. The apply role can change infrastructure and is reachable only
# from the protected GitHub environment of the same name.
# ---------------------------------------------------------------------------

# State access is granted per environment, not per bucket. Every environment
# keys its state under aws/<env>/, so scoping the object actions to that prefix
# is what stops the dev pipeline from reading production state — and stops any
# CI role from reaching aws/bootstrap/, the state that defines these roles.
#
# ListBucket stays at the bucket level deliberately: the S3 backend lists to
# discover whether the state object exists, and an s3:prefix condition breaks
# init for the sake of hiding key names that reveal nothing on their own.
data "aws_iam_policy_document" "state_read" {
  for_each = toset(local.environments)

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [module.state_backend.bucket_arn]
  }

  statement {
    sid       = "ReadOwnState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.state_backend.bucket_arn}/aws/${each.key}/*"]
  }

  statement {
    sid    = "DecryptState"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [module.state_backend.kms_key_arn]
  }
}

# The apply role adds the write half. A plan never needs it: both workflows that
# use the plan role run `terraform plan -lock=false`, which reads state and the
# lock file without writing either.
data "aws_iam_policy_document" "state_write" {
  for_each = toset(local.environments)

  source_policy_documents = [data.aws_iam_policy_document.state_read[each.key].json]

  statement {
    sid    = "WriteOwnState"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${module.state_backend.bucket_arn}/aws/${each.key}/*"]
  }

  statement {
    sid    = "EncryptState"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [module.state_backend.kms_key_arn]
  }
}

# The pipeline provisions the platform; it does not get to dismantle the
# record of what it did. An apply role with PowerUserAccess could otherwise
# stop the trail, delete the GuardDuty detector, or empty the audit bucket —
# and the deletion would be the last thing the trail recorded.
data "aws_iam_policy_document" "audit_guardrail" {
  statement {
    sid    = "DenyDisablingAuditAndDetection"
    effect = "Deny"
    actions = [
      "cloudtrail:DeleteTrail",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "config:DeleteConfigurationRecorder",
      "config:DeleteDeliveryChannel",
      "config:StopConfigurationRecorder",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "guardduty:UpdateDetector",
      "securityhub:DisableSecurityHub",
      "securityhub:DeleteMembers",
      "accessanalyzer:DeleteAnalyzer",
      "s3:PutAccountPublicAccessBlock",
      "ec2:DisableEbsEncryptionByDefault",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyTouchingAuditRecords"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [
      module.security_baseline.audit_bucket_arn,
      "${module.security_baseline.audit_bucket_arn}/*",
    ]
  }

  # Deleting the state bucket, or the key that decrypts it, is not a recovery
  # path — it is the end of one.
  statement {
    sid    = "DenyDestroyingRemoteState"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketVersioning",
    ]
    resources = [module.state_backend.bucket_arn]
  }

  statement {
    sid       = "DenySchedulingKeyDeletion"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
    resources = [module.state_backend.kms_key_arn, module.security_baseline.audit_kms_key_arn]
  }

  # Everything above only binds the role it is attached to. With IAMFullAccess
  # the apply role could otherwise create a second role with AdministratorAccess
  # and no deny policy, assume it, and stop the trail from there — two API calls
  # to walk around every statement above.
  #
  # Requiring the boundary on any new principal is what makes these denies
  # transitive: a role the pipeline creates inherits them whether or not anyone
  # remembered to attach this policy to it.
  statement {
    sid    = "DenyCreatingPrincipalsWithoutTheBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:CreateUser",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.ci_boundary_arn]
    }
  }

  # Setting a boundary is allowed only when the boundary being set is this one,
  # which also blocks swapping it for a permissive policy.
  statement {
    sid    = "DenyReplacingTheBoundary"
    effect = "Deny"
    actions = [
      "iam:PutRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.ci_boundary_arn]
    }
  }

  statement {
    sid    = "DenyDetachingTheBoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }

  # A boundary that the constrained role can rewrite is not a boundary.
  statement {
    sid    = "DenyRewritingTheBoundaryPolicy"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
    ]
    resources = [local.ci_boundary_arn]
  }
}

# The boundary is the guardrail plus a blanket allow. A permissions boundary is
# intersected with the role's own policies, so the allow is what keeps the role
# functional while the deny statements it inherits are the part that bites.
data "aws_iam_policy_document" "ci_boundary" {
  # Every wildcard finding below is the same fact: a permissions boundary is
  # intersected with the role's own policies and grants nothing by itself, so
  # its allow has to be broad or it would subtract permissions the roles need.
  # The deny statements inherited from audit_guardrail are the operative half.
  # A wildcard rule cannot tell a boundary from an over-broad grant.
  #checkov:skip=CKV_AWS_1:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_49:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_107:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_108:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_109:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_110:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_111:Boundary allow is intersected, not granted
  #checkov:skip=CKV_AWS_356:Boundary allow is intersected, not granted
  #checkov:skip=CKV2_AWS_40:Boundary allow is intersected, not granted
  source_policy_documents = [data.aws_iam_policy_document.audit_guardrail.json]

  # A permissions boundary is intersected with the role's own policies, so it
  # grants nothing on its own — the allow has to be broad or the boundary would
  # subtract permissions the roles legitimately need. The deny statements
  # inherited above are the operative half.
  #tfsec:ignore:aws-iam-no-policy-wildcards
  statement {
    sid       = "AllowAnythingNotExplicitlyDenied"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ci_boundary" {
  name        = local.ci_boundary_name
  description = "Permissions boundary for CI roles and anything they create"
  policy      = data.aws_iam_policy_document.ci_boundary.json

  tags = local.common_tags
}

locals {
  # A plan role that can read its own environment's state and describe
  # resources, and nothing else. It gets the read half only: the write half
  # would let any pull request overwrite production state.
  plan_roles = {
    for env in local.environments :
    "${local.name_prefix}-${env}-plan" => {
      description = "Read only Terraform plan role for ${env}"
      subjects    = ["repo:${var.github_repository}:pull_request"]
      managed_policy_arns = [
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess",
      ]
      inline_policies = {
        "terraform-state-read"   = data.aws_iam_policy_document.state_read[env].json
        "protect-audit-controls" = data.aws_iam_policy_document.audit_guardrail.json
      }
    }
  }

  # Scope this down once the resource set stops changing. PowerUserAccess plus
  # explicit IAM permissions is the pragmatic starting point for a stack that
  # creates its own IAM roles; the guardrail policy above is what keeps that
  # breadth from being able to hide its own tracks.
  apply_roles = {
    for env in local.environments :
    "${local.name_prefix}-${env}-apply" => {
      description = "Terraform apply role for ${env}"
      subjects    = ["repo:${var.github_repository}:environment:aws-${env}"]
      managed_policy_arns = [
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess",
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/IAMFullAccess",
      ]
      inline_policies = {
        "terraform-state-write"  = data.aws_iam_policy_document.state_write[env].json
        "protect-audit-controls" = data.aws_iam_policy_document.audit_guardrail.json
      }
      max_session_duration = 7200
    }
  }
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  create_oidc_provider = var.create_github_oidc_provider
  oidc_provider_arn    = var.existing_github_oidc_provider_arn

  roles = merge(local.plan_roles, local.apply_roles)

  permissions_boundary_arn = aws_iam_policy.ci_boundary.arn

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Security baseline
# ---------------------------------------------------------------------------

module "security_baseline" {
  source = "../../modules/security-baseline"

  name_prefix = local.name_prefix

  audit_log_retention_days = var.audit_log_retention_days

  # Object Lock cannot be added to an existing bucket, so it is a create time
  # decision. Turning it on later means creating a new audit bucket.
  audit_object_lock_days = var.audit_object_lock_days

  enable_cloudtrail        = true
  enable_config            = var.enable_config
  enable_guardduty         = true
  enable_security_hub      = var.enable_security_hub
  enable_access_analyzer   = true
  enable_inspector         = var.enable_inspector
  security_hub_standards   = var.security_hub_standards
  guardduty_eks_protection = true

  # Same region as the alarms. A CloudWatch alarm cannot publish to a topic in
  # another region, which rules out reusing the us-east-1 cost topic here.
  alarm_topic_arns = [aws_sns_topic.security_alerts.arn]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Security alert routing
# ---------------------------------------------------------------------------

# The AWS managed alias/aws/sns key cannot be audited, rotated or revoked
# independently of the account, so the security topic gets its own key.
resource "aws_kms_key" "security_alerts" {
  description             = "Encrypts messages published to the ${local.name_prefix} security alert topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Without this the alarm reaches the topic but cannot encrypt the
        # message, and the publish fails with KMSAccessDenied.
        Sid       = "AllowPublishingServices"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-security-alerts" })
}

resource "aws_kms_alias" "security_alerts" {
  name          = "alias/${local.name_prefix}-security-alerts"
  target_key_id = aws_kms_key.security_alerts.key_id
}

resource "aws_sns_topic" "security_alerts" {
  name              = "${local.name_prefix}-security-alerts"
  kms_master_key_id = aws_kms_key.security_alerts.arn

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-security-alerts" })
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

resource "aws_sns_topic_subscription" "security_email" {
  for_each = toset(var.security_notification_emails)

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# GuardDuty and Security Hub findings reach the same topic
#
# A finding that only appears in a console tab nobody opens is not a
# detection. EventBridge is what turns it into a notification.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${local.name_prefix}-guardduty-high-severity"
  description = "GuardDuty findings at severity 7.0 and above"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", var.guardduty_notify_severity] }]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "guardduty_findings" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "security-alerts"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      description = "$.detail.description"
      region      = "$.region"
      account     = "$.account"
    }

    input_template = "\"GuardDuty <severity>: <type> in <account>/<region> — <description>\""
  }
}

# ---------------------------------------------------------------------------
# Cost controls
#
# Budgets and Cost Anomaly Detection are global services that only answer in
# us-east-1, which is why this module gets the aliased provider.
# ---------------------------------------------------------------------------

module "cost_controls" {
  source = "../../modules/cost-controls"

  providers = {
    aws = aws.us_east_1
  }

  name_prefix        = local.name_prefix
  monthly_budget_usd = var.monthly_budget_usd

  environment_budgets_usd = var.environment_budgets_usd

  notification_emails = var.cost_notification_emails

  tags = local.common_tags
}
