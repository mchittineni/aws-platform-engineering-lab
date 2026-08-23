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
  description = "VPC CIDR block. Must not overlap dev or production if the VPCs are ever peered."
  type        = string
  default     = "10.25.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Upgrade staging first; production follows once staging has run the version for a week."
  type        = string
  default     = "1.34"
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly. Keep false so staging exercises the same access path as production."
  type        = bool
  default     = false
}

variable "api_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint when endpoint_public_access is true"
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.api_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes the Kubernetes API to the entire internet. List the specific egress CIDRs that need access."
  }
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs granted cluster admin through EKS access entries, typically the CI apply role and the platform team role"
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
  description = "ECR repositories created for this environment. Leave empty to pull the images production will run."
  type        = list(string)
  default     = []
}

variable "alert_emails" {
  description = "Email addresses subscribed to the platform alert and backup topics"
  type        = list(string)
  default     = []
}

variable "enable_container_insights" {
  description = "Create the node level CloudWatch alarms. Requires the amazon-cloudwatch-observability add-on in the cluster."
  type        = bool
  default     = false
}

variable "owner" {
  description = "Owner tag value"
  type        = string
  default     = "platform-engineering"
}
