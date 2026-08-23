variable "cluster_name" {
  description = "EKS cluster these alarms belong to. Used for names, dimensions and the audit log group."
  type        = string
}

variable "cluster_log_group_name" {
  description = <<-EOT
    CloudWatch log group holding the control plane logs, from the eks module's
    cluster_log_group_name output. Passing it rather than deriving the name is
    what makes Terraform order the log group before the metric filters that
    read it.
  EOT
  type        = string
  default     = null
}

variable "nat_gateway_ids" {
  description = "NAT gateway IDs to alarm on. Take these from the VPC module."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

variable "create_sns_topic" {
  description = "Create the SNS topic alarms publish to"
  type        = bool
  default     = true
}

variable "sns_kms_key_id" {
  description = "Existing KMS key ARN or alias encrypting the alert topic. Leave null to create a customer managed key with the right service grants."
  type        = string
  default     = null
}

variable "additional_topic_arns" {
  description = "Existing SNS topics notified in addition to the one created here, for example a PagerDuty or Chatbot integration"
  type        = list(string)
  default     = []
}

variable "notification_emails" {
  description = "Email addresses subscribed to the alert topic. Each address must confirm by email."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# What to alarm on
# ---------------------------------------------------------------------------

variable "enable_control_plane_alarms" {
  description = "Alarm on EKS API server failed requests"
  type        = bool
  default     = true
}

variable "api_server_error_threshold" {
  description = "Failed API server requests in a five minute window before alarming"
  type        = number
  default     = 10
}

variable "enable_nat_alarms" {
  description = "Alarm on NAT gateway port allocation errors and dropped packets"
  type        = bool
  default     = true
}

variable "nat_packet_drop_threshold" {
  description = "Dropped packets in a five minute window before alarming"
  type        = number
  default     = 100
}

variable "enable_container_insights_alarms" {
  description = <<-EOT
    Alarm on node CPU, memory, disk and NotReady count. These metrics only
    exist once the amazon-cloudwatch-observability add-on is collecting them.
    Enabling this without the agent leaves the alarms in INSUFFICIENT_DATA.
  EOT
  type        = bool
  default     = false
}

variable "node_cpu_threshold" {
  description = "Average node CPU percentage before alarming"
  type        = number
  default     = 85
}

variable "node_memory_threshold" {
  description = "Average node memory percentage before alarming"
  type        = number
  default     = 85
}

variable "node_disk_threshold" {
  description = "Average node filesystem percentage before alarming. The kubelet starts evicting pods at 85 percent by default."
  type        = number
  default     = 80
}

variable "enable_audit_log_alarms" {
  description = "Create metric filters and alarms over the EKS control plane audit log. Requires the audit log type to be enabled on the cluster."
  type        = bool
  default     = true
}

variable "audit_metric_namespace" {
  description = "CloudWatch namespace for the audit log metrics"
  type        = string
  default     = "PlatformAudit"
}

variable "forbidden_response_threshold" {
  description = "403 responses in a five minute window before alarming. Set high enough to ignore a controller with a stale cache."
  type        = number
  default     = 50
}

variable "secret_list_threshold" {
  description = "Successful cross namespace Secret list calls in a five minute window before alarming"
  type        = number
  default     = 10
}

variable "enable_composite_alarm" {
  description = "Create one composite alarm covering the paging-worthy alarms, so on-call subscribes to a single thing"
  type        = bool
  default     = true
}

variable "create_dashboard" {
  description = "Create the platform CloudWatch dashboard"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
