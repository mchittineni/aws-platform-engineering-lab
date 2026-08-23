variable "role_name" {
  description = "IAM role name"
  type        = string
}

variable "description" {
  description = "IAM role description"
  type        = string
  default     = "IAM role for a Kubernetes service account"
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the EKS cluster"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL of the EKS cluster, without the https:// scheme"
  type        = string
}

variable "service_accounts" {
  description = <<-EOT
    Service accounts allowed to assume the role, as `namespace/name` pairs.
    `name` may be `*` to allow every service account in the namespace, which
    switches the trust condition from StringEquals to StringLike.

    Example: ["kube-system/aws-load-balancer-controller"]
  EOT
  type        = list(string)

  validation {
    condition     = length(var.service_accounts) > 0
    error_message = "At least one service account must be allowed to assume the role."
  }

  validation {
    condition     = alltrue([for sa in var.service_accounts : length(split("/", sa)) == 2])
    error_message = "Each service account must be written as namespace/name."
  }
}

variable "managed_policy_arns" {
  description = "AWS managed or customer managed policy ARNs attached to the role"
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline policies attached to the role, keyed by policy name, with the JSON policy document as the value"
  type        = map(string)
  default     = {}
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds"
  type        = number
  default     = 3600
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary applied to the role"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the role"
  type        = map(string)
  default     = {}
}
