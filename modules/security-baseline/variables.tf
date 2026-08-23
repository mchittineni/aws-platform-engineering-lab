variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module"
  type        = string
  default     = "aws-platform-lab"
}

# ---------------------------------------------------------------------------
# Audit storage
# ---------------------------------------------------------------------------

variable "audit_bucket_name" {
  description = "Name of the bucket holding CloudTrail and Config records. Leave null to derive one from the account and region."
  type        = string
  default     = null
}

variable "audit_log_retention_days" {
  description = "Delete audit records after this many days. Keep at least 365 for anything an auditor will ask about."
  type        = number
  default     = 730

  validation {
    condition     = var.audit_log_retention_days >= 90
    error_message = "An audit trail shorter than 90 days is not useful during an investigation."
  }
}

variable "audit_object_lock_mode" {
  description = "Object Lock retention mode. GOVERNANCE lets a break-glass role remove retention; COMPLIANCE cannot be overridden by anyone, including the account root."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.audit_object_lock_mode)
    error_message = "audit_object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "audit_object_lock_days" {
  description = "Object Lock retention in days. Set to 0 to skip Object Lock, which is the only way to change it later: it cannot be added to an existing bucket."
  type        = number
  default     = 0
}

variable "audit_bucket_admin_arns" {
  description = "Principals exempt from the audit bucket object deletion deny. Defaults to the account root only."
  type        = list(string)
  default     = []
}

variable "audit_log_reader_arns" {
  description = "Principals granted kms:Decrypt on the audit key so they can read log files. Defaults to the account root only."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Account controls
# ---------------------------------------------------------------------------

variable "enable_s3_account_public_access_block" {
  description = "Block public S3 access for the whole account, overriding any per bucket setting"
  type        = bool
  default     = true
}

variable "enable_ebs_encryption_by_default" {
  description = "Encrypt every new EBS volume in the region, including volumes created outside Terraform"
  type        = bool
  default     = true
}

variable "enable_password_policy" {
  description = "Set the IAM console password policy. Only affects break-glass IAM users."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# CloudTrail
# ---------------------------------------------------------------------------

variable "enable_cloudtrail" {
  description = "Create the multi region management event trail"
  type        = bool
  default     = true
}

variable "cloudtrail_cloudwatch_retention_days" {
  description = "CloudWatch Logs retention for the trail copy that the alarms read. The S3 copy is the long term record."
  type        = number
  default     = 90
}

variable "enable_cloudtrail_alarms" {
  description = "Create metric filters and alarms for root usage, IAM changes, trail tampering and similar events"
  type        = bool
  default     = true
}

variable "security_metric_namespace" {
  description = "CloudWatch namespace for the security metric filters"
  type        = string
  default     = "PlatformSecurity"
}

variable "alarm_topic_arns" {
  description = "SNS topics notified when a security alarm fires"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# AWS Config
# ---------------------------------------------------------------------------

variable "enable_config" {
  description = "Enable the AWS Config recorder, delivery channel and rule set"
  type        = bool
  default     = true
}

variable "config_snapshot_frequency" {
  description = "How often Config writes a full configuration snapshot"
  type        = string
  default     = "TwentyFour_Hours"

  validation {
    condition = contains([
      "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours",
    ], var.config_snapshot_frequency)
    error_message = "config_snapshot_frequency must be one of One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}

# ---------------------------------------------------------------------------
# GuardDuty
# ---------------------------------------------------------------------------

variable "enable_guardduty" {
  description = "Enable the GuardDuty detector"
  type        = bool
  default     = true
}

variable "guardduty_publishing_frequency" {
  description = "How often GuardDuty publishes updated findings"
  type        = string
  default     = "FIFTEEN_MINUTES"

  validation {
    condition     = contains(["FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"], var.guardduty_publishing_frequency)
    error_message = "guardduty_publishing_frequency must be FIFTEEN_MINUTES, ONE_HOUR or SIX_HOURS."
  }
}

variable "guardduty_eks_protection" {
  description = "Analyse the EKS control plane audit log. The single most valuable GuardDuty feature for a Kubernetes platform."
  type        = bool
  default     = true
}

variable "guardduty_s3_protection" {
  description = "Analyse S3 data events"
  type        = bool
  default     = true
}

variable "guardduty_malware_protection" {
  description = "Scan EBS snapshots of an instance GuardDuty has flagged"
  type        = bool
  default     = true
}

variable "guardduty_runtime_monitoring" {
  description = "Deploy the GuardDuty runtime agent to EKS as a managed add-on. Adds per vCPU cost; catches in-container behaviour the audit log cannot show."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Security Hub
# ---------------------------------------------------------------------------

variable "enable_security_hub" {
  description = "Enable Security Hub and subscribe to the standards below"
  type        = bool
  default     = true
}

variable "security_hub_standards" {
  description = <<-EOT
    Standards ARNs to subscribe to. Leave empty to subscribe to the AWS
    Foundational Security Best Practices standard for the current region.
    Adding CIS on day one produces hundreds of findings and teaches the team
    to ignore the console, so it is opt in:

      arn:aws:securityhub:<region>::standards/cis-aws-foundations-benchmark/v/3.0.0
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Access Analyzer and Inspector
# ---------------------------------------------------------------------------

variable "enable_access_analyzer" {
  description = "Create the external access IAM Access Analyzer"
  type        = bool
  default     = true
}

variable "enable_unused_access_analyzer" {
  description = "Also create the unused access analyzer, which finds permissions that were granted and never used. Charged per IAM role analysed."
  type        = bool
  default     = false
}

variable "unused_access_age_days" {
  description = "Report a permission as unused after this many days without use"
  type        = number
  default     = 90
}

variable "enable_inspector" {
  description = "Enable Amazon Inspector for the resource types below"
  type        = bool
  default     = false
}

variable "inspector_resource_types" {
  description = "Resource types Inspector scans. EC2 covers the node AMIs, ECR the container images."
  type        = list(string)
  default     = ["EC2", "ECR"]

  validation {
    condition     = alltrue([for t in var.inspector_resource_types : contains(["EC2", "ECR", "LAMBDA", "LAMBDA_CODE"], t)])
    error_message = "inspector_resource_types entries must be EC2, ECR, LAMBDA or LAMBDA_CODE."
  }
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
