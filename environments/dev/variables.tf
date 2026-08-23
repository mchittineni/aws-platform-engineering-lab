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
  description = "VPC CIDR block"
  type        = string
  default     = "10.20.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.34"
}

variable "api_public_access_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the public Kubernetes API endpoint. Leaving
    this empty keeps the endpoint private, which means kubectl only works from
    inside the VPC. Set it to your own egress address to work from a laptop.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.api_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes the Kubernetes API to the entire internet. List your own egress CIDR instead."
  }
}

variable "cluster_admin_role_arns" {
  description = "IAM role ARNs granted cluster admin through EKS access entries, for example the CI deployment role"
  type        = list(string)
  default     = []
}

variable "ecr_repositories" {
  description = "ECR repositories created for this environment"
  type        = list(string)
  default     = ["demo-api", "demo-web"]
}

variable "owner" {
  description = "Owner tag value"
  type        = string
  default     = "platform-engineering"
}

variable "alert_emails" {
  description = "Email addresses subscribed to the platform alert topic. Each address must confirm by email."
  type        = list(string)
  default     = []
}
