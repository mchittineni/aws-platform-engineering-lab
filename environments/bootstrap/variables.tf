variable "region" {
  description = "AWS region for the state bucket and the IAM resources"
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the deployment roles, as org/repo"
  type        = string

  validation {
    condition     = length(split("/", var.github_repository)) == 2
    error_message = "github_repository must be written as org/repo."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set to false if the account already has one."
  type        = bool
  default     = true
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, required when create_github_oidc_provider is false"
  type        = string
  default     = null
}

variable "owner" {
  description = "Owner tag value"
  type        = string
  default     = "platform-engineering"
}


# ---------------------------------------------------------------------------
# Security baseline
# ---------------------------------------------------------------------------

variable "audit_log_retention_days" {
  description = "How long CloudTrail and Config records are kept in the audit bucket"
  type        = number
  default     = 730
}

variable "audit_object_lock_days" {
  description = <<-EOT
    Object Lock retention for audit records, in days. 0 skips Object Lock.

    This is a create time decision: Object Lock cannot be added to an existing
    bucket, so turning it on later means creating a second audit bucket and
    repointing the trail.
  EOT
  type        = number
  default     = 0
}

variable "enable_config" {
  description = "Enable the AWS Config recorder and rule set. Charged per configuration item recorded."
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "Enable Security Hub and subscribe to the standards below"
  type        = bool
  default     = true
}

variable "security_hub_standards" {
  description = "Standards ARNs to subscribe to. Empty subscribes to AWS Foundational Security Best Practices for this region."
  type        = list(string)
  default     = []
}

variable "enable_inspector" {
  description = "Enable Amazon Inspector for EC2 and ECR. Charged per instance and per image scanned."
  type        = bool
  default     = false
}

variable "guardduty_notify_severity" {
  description = "Minimum GuardDuty finding severity that produces a notification. 7.0 is High, 4.0 is Medium."
  type        = number
  default     = 7.0
}

variable "security_notification_emails" {
  description = "Email addresses subscribed to the security alert topic. Each address must confirm by email."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Cost controls
# ---------------------------------------------------------------------------

variable "monthly_budget_usd" {
  description = "Monthly account budget in USD. Set to 0 to skip the account budget."
  type        = number
  default     = 500
}

variable "environment_budgets_usd" {
  description = "Per environment monthly budgets in USD, keyed by the Environment tag value"
  type        = map(number)
  default = {
    dev        = 250
    staging    = 350
    production = 1200
  }
}

variable "cost_notification_emails" {
  description = "Email addresses subscribed to the cost alert topic"
  type        = list(string)
  default     = []
}
