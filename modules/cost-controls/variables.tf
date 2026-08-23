variable "name_prefix" {
  description = "Prefix applied to every budget, monitor and topic name"
  type        = string
  default     = "aws-platform-lab"
}

variable "monthly_budget_usd" {
  description = "Monthly account budget in USD. Set to 0 to skip the account budget."
  type        = number
  default     = 500
}

variable "environment_budgets_usd" {
  description = <<-EOT
    Per environment monthly budgets in USD, keyed by the Environment tag value.

    Example: { dev = 300, staging = 400, production = 1500 }
  EOT
  type        = map(number)
  default     = {}
}

variable "actual_spend_thresholds" {
  description = "Percentages of the budget at which an actual spend alert fires"
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = alltrue([for t in var.actual_spend_thresholds : t > 0 && t <= 200])
    error_message = "Each threshold must be a percentage between 1 and 200."
  }
}

variable "forecast_threshold" {
  description = "Percentage of the budget the month end forecast must exceed before alerting"
  type        = number
  default     = 100
}

variable "enable_anomaly_detection" {
  description = "Create a per service Cost Anomaly Detection monitor and subscription"
  type        = bool
  default     = true
}

variable "anomaly_impact_threshold_usd" {
  description = "Only report anomalies whose absolute impact reaches this many USD"
  type        = number
  default     = 25
}

variable "create_sns_topic" {
  description = "Create the SNS topic that budgets and anomaly detection publish to"
  type        = bool
  default     = true
}

variable "sns_kms_key_id" {
  description = "Existing KMS key ARN or alias encrypting the topic. Leave null to create a customer managed key with the right service grants."
  type        = string
  default     = null
}

variable "additional_topic_arns" {
  description = "Existing SNS topics to notify in addition to the one created here"
  type        = list(string)
  default     = []
}

variable "notification_emails" {
  description = "Email addresses subscribed to the cost topic. Each address must confirm the subscription by email."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
