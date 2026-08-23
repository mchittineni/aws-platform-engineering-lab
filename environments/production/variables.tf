variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "availability_zones" {
  description = "Availability zones to use. Leave empty to take the first three in the region."
  type        = list(string)
  default     = []
}

variable "vpc_cidr_block" {
  description = "VPC CIDR block. Must not overlap the dev VPC if the two are ever peered."
  type        = string
  default     = "10.30.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.34"
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly. Keep false and reach the API through a VPN or SSM port forward."
  type        = bool
  default     = false
}

variable "api_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint when endpoint_public_access is true"
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.api_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not an acceptable production API allow list."
  }
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs granted cluster admin through EKS access entries"
  type        = list(string)
  default     = []
}

variable "cluster_viewer_role_arns" {
  description = "IAM role ARNs granted read only cluster access"
  type        = list(string)
  default     = []
}

variable "route53_hosted_zone_arns" {
  description = "Hosted zones external-dns and cert-manager may write to"
  type        = list(string)
  default     = []
}

variable "ecr_repositories" {
  description = "ECR repositories created for this environment"
  type        = list(string)
  default     = []
}

variable "owner" {
  description = "Owner tag value"
  type        = string
  default     = "platform-engineering"
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "alert_emails" {
  description = "Email addresses subscribed to the platform alert and backup topics"
  type        = list(string)
  default     = []
}

variable "additional_alert_topic_arns" {
  description = "Existing SNS topics notified alongside the one created here, for example a PagerDuty integration"
  type        = list(string)
  default     = []
}

variable "enable_container_insights" {
  description = <<-EOT
    Create the node level CloudWatch alarms. These read ContainerInsights
    metrics, which only exist once the amazon-cloudwatch-observability add-on
    is running in the cluster. Enabling this first leaves the alarms in
    INSUFFICIENT_DATA rather than failing loudly.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

variable "backup_vault_lock_min_retention_days" {
  description = "Minimum retention Vault Lock enforces on recovery points. 0 disables the lock."
  type        = number
  default     = 7
}

variable "backup_copy_destination_vault_arn" {
  description = "Vault in a second region that recovery points are copied to. A single region backup does not survive a regional event."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = <<-EOT
    Permissions boundary applied to every IAM role this environment creates.
    Take it from the bootstrap output `ci_permissions_boundary_arn`.

    Required when the environment is applied by CI: the apply role is denied
    `iam:CreateRole` unless the new role carries this boundary, which is what
    makes the audit guardrail apply to roles the pipeline creates rather than
    only to the pipeline role itself.
  EOT
  type        = string
  default     = null
}
