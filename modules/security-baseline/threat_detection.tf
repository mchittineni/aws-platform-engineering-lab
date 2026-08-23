# ---------------------------------------------------------------------------
# GuardDuty
#
# EKS audit log monitoring is the feature that matters most for this
# platform: it reads the control plane audit log AWS already collects and
# flags the Kubernetes specific attack patterns.
# ---------------------------------------------------------------------------

resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:The detector is enabled here, behind a count
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = var.guardduty_publishing_frequency

  tags = var.tags
}

locals {
  guardduty_features = var.enable_guardduty ? {
    S3_DATA_EVENTS         = var.guardduty_s3_protection ? "ENABLED" : "DISABLED"
    EKS_AUDIT_LOGS         = var.guardduty_eks_protection ? "ENABLED" : "DISABLED"
    EBS_MALWARE_PROTECTION = var.guardduty_malware_protection ? "ENABLED" : "DISABLED"
  } : {}
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = local.guardduty_features

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  status      = each.value
}

# Runtime monitoring is configured separately because it also manages the
# agent that runs on the nodes.
resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  count = var.enable_guardduty && var.guardduty_runtime_monitoring ? 1 : 0

  detector_id = aws_guardduty_detector.this[0].id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

# ---------------------------------------------------------------------------
# Security Hub
#
# Aggregates GuardDuty, Config, Inspector and Access Analyzer findings and
# scores them against a published benchmark, so "are we compliant" has an
# answer that is not a spreadsheet.
# ---------------------------------------------------------------------------

resource "aws_securityhub_account" "this" {
  count = var.enable_security_hub ? 1 : 0

  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

locals {
  # The FSBP ARN is region qualified, so it cannot be a variable default.
  # Passing security_hub_standards explicitly overrides this.
  security_hub_standards = length(var.security_hub_standards) > 0 ? var.security_hub_standards : [
    "arn:${local.partition}:securityhub:${local.region}::standards/aws-foundational-security-best-practices/v/1.0.0",
  ]
}

resource "aws_securityhub_standards_subscription" "this" {
  for_each = var.enable_security_hub ? toset(local.security_hub_standards) : toset([])

  standards_arn = each.value

  depends_on = [aws_securityhub_account.this]
}

# ---------------------------------------------------------------------------
# IAM Access Analyzer
#
# Two analyzers: one finds resources reachable from outside the account, the
# other finds permissions that were granted and never used.
# ---------------------------------------------------------------------------

resource "aws_accessanalyzer_analyzer" "external_access" {
  count = var.enable_access_analyzer ? 1 : 0

  analyzer_name = "${var.name_prefix}-external-access"
  type          = "ACCOUNT"

  tags = var.tags
}

resource "aws_accessanalyzer_analyzer" "unused_access" {
  count = var.enable_access_analyzer && var.enable_unused_access_analyzer ? 1 : 0

  analyzer_name = "${var.name_prefix}-unused-access"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = var.unused_access_age_days
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Inspector
#
# Scans the node AMIs and the container images in ECR for known CVEs. ECR
# enhanced scanning in the ecr module is the registry half of this.
# ---------------------------------------------------------------------------

resource "aws_inspector2_enabler" "this" {
  count = var.enable_inspector ? 1 : 0

  account_ids    = [local.account_id]
  resource_types = var.inspector_resource_types
}
