variable "name" {
  description = "Name prefix applied to every VPC resource"
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "Availability zones used for subnet placement. Three AZs are required for a highly available control plane."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required for high availability."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks, one per availability zone"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks, one per availability zone"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Deploy a single shared NAT gateway instead of one per availability zone. Cheaper, but not zone resilient."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention in days for VPC flow logs"
  type        = number
  default     = 30
}

variable "enable_s3_gateway_endpoint" {
  description = "Create a gateway VPC endpoint for S3. Removes NAT gateway data charges for S3 and ECR layer traffic."
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = <<-EOT
    Interface VPC endpoints to create in the private subnets, without the
    `com.amazonaws.<region>.` prefix. Keeps node and pod traffic to these
    services off the NAT gateway. Set to [] to disable.
  EOT
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "logs",
    "ec2messages",
    "ssm",
    "ssmmessages",
  ]
}

variable "kubernetes_cluster_name" {
  description = "EKS cluster name used for subnet discovery tags. Leave null to skip Kubernetes tags."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary applied to every IAM role this module creates. The CI apply role is denied iam:CreateRole without it, so this is required in any environment applied by the pipeline."
  type        = string
  default     = null
}
