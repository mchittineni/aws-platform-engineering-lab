variable "name" {
  description = "Name of the vault, plan and service role"
  type        = string
}

variable "kms_key_arn" {
  description = "Customer managed KMS key encrypting the recovery points. Leave null to create one."
  type        = string
  default     = null
}

variable "rules" {
  description = <<-EOT
    Backup rules keyed by rule name. `schedule` is a cron expression in UTC.

    Cold storage has a 90 day minimum billing period, so `delete_after_days`
    must be at least `cold_storage_after_days + 90` or the plan is rejected.
  EOT
  type = map(object({
    schedule                  = string
    start_window_minutes      = optional(number, 60)
    completion_window_minutes = optional(number, 360)
    cold_storage_after_days   = optional(number)
    delete_after_days         = optional(number, 35)
    copy_delete_after_days    = optional(number, 90)
    continuous_backup         = optional(bool, false)
  }))

  default = {
    daily = {
      schedule          = "cron(0 3 * * ? *)"
      delete_after_days = 35
    }
    weekly = {
      schedule                = "cron(0 4 ? * SUN *)"
      cold_storage_after_days = 30
      delete_after_days       = 365
    }
  }

  validation {
    condition = alltrue([
      for r in var.rules :
      r.cold_storage_after_days == null || r.delete_after_days >= r.cold_storage_after_days + 90
    ])
    error_message = "Cold storage has a 90 day minimum, so delete_after_days must be at least cold_storage_after_days + 90."
  }

  validation {
    condition     = alltrue([for r in var.rules : startswith(r.schedule, "cron(") || startswith(r.schedule, "rate(")])
    error_message = "schedule must be a cron() or rate() expression."
  }
}

variable "selection_tags" {
  description = <<-EOT
    Tags a resource must carry to be backed up, as a map of key to value. The
    EBS CSI driver applies StorageClass `tagSpecification_N` parameters to the
    volumes it creates, which is how a PVC ends up selected.
  EOT
  type        = map(string)
  default     = { "platform.aws/backup" = "true" }

  validation {
    condition     = length(var.selection_tags) > 0
    error_message = "At least one selection tag is required, otherwise the plan backs up nothing."
  }
}

variable "selection_resource_arns" {
  description = "Resource ARNs to back up in addition to the tag selection. Defaults to every supported resource, narrowed by the tags."
  type        = list(string)
  default     = ["*"]
}

variable "copy_destination_vault_arn" {
  description = "Vault in a second region to copy recovery points to. A single region backup does not survive a regional event."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Vault lock
# ---------------------------------------------------------------------------

variable "vault_lock_min_retention_days" {
  description = "Minimum retention enforced by Vault Lock. Set to 0 to skip the lock entirely."
  type        = number
  default     = 0
}

variable "vault_lock_max_retention_days" {
  description = "Maximum retention Vault Lock permits"
  type        = number
  default     = 1095
}

variable "vault_lock_compliance_mode" {
  description = "Move the lock to compliance mode after the grace period below. Once compliance mode takes effect nobody can shorten retention or delete a recovery point, including the account root."
  type        = bool
  default     = false
}

variable "vault_lock_changeable_for_days" {
  description = "Grace period during which a compliance mode lock can still be removed. AWS requires at least 3 days."
  type        = number
  default     = 3

  validation {
    condition     = var.vault_lock_changeable_for_days >= 3
    error_message = "AWS requires a grace period of at least 3 days before a compliance mode lock becomes permanent."
  }
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

variable "create_sns_topic" {
  description = "Create an SNS topic for backup job events"
  type        = bool
  default     = true
}

variable "sns_kms_key_id" {
  description = "Existing KMS key ARN or alias encrypting the notification topic. Leave null to create a customer managed key with the right service grants."
  type        = string
  default     = null
}

variable "notification_topic_arn" {
  description = "Existing SNS topic for backup events, used when create_sns_topic is false"
  type        = string
  default     = null
}

variable "notification_emails" {
  description = "Email addresses subscribed to the backup topic"
  type        = list(string)
  default     = []
}

variable "notification_events" {
  description = "Vault events published to SNS. Failures matter more than successes, but COMPLETED is how you prove the plan ran."
  type        = list(string)
  default = [
    "BACKUP_JOB_FAILED",
    "BACKUP_JOB_EXPIRED",
    "COPY_JOB_FAILED",
    "RESTORE_JOB_FAILED",
    "RESTORE_JOB_COMPLETED",
  ]
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
