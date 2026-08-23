variable "bucket_name" {
  description = "S3 bucket holding Terraform state. Must be globally unique."
  type        = string
}

variable "enable_dynamodb_lock_table" {
  description = <<-EOT
    Create a DynamoDB lock table. Terraform 1.10 and later can lock through S3
    itself with `use_lockfile = true`, which is the preferred approach. Keep
    this enabled only while older Terraform versions still use the backend.
  EOT
  type        = bool
  default     = false
}

variable "dynamodb_table_name" {
  description = "DynamoDB lock table name"
  type        = string
  default     = "terraform-state-lock"
}

variable "noncurrent_version_expiration_days" {
  description = "Delete superseded state versions after this many days. Keep a long window; state history is the recovery path after a bad apply."
  type        = number
  default     = 365
}

variable "enable_access_logging" {
  description = <<-EOT
    Create a companion bucket and record S3 server access logs for the state
    bucket. This is the only record of who read or wrote state, so it is worth
    the few cents a month.
  EOT
  type        = bool
  default     = true
}

variable "access_log_retention_days" {
  description = "Delete access log objects after this many days"
  type        = number
  default     = 90
}

variable "enable_replication" {
  description = "Replicate state to a second region. Recommended once the backend holds production state."
  type        = bool
  default     = false
}

variable "replica_bucket_arn" {
  description = "ARN of an existing destination bucket in another region, required when enable_replication is true"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
