variable "repositories" {
  description = "ECR repository names to create"
  type        = list(string)
}

variable "image_tag_mutability" {
  description = "IMMUTABLE stops a tag from being repointed at different image content, which is what makes a GitOps digest pin trustworthy."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Run a vulnerability scan whenever an image is pushed"
  type        = bool
  default     = true
}

variable "enable_registry_enhanced_scanning" {
  description = "Switch the whole registry to Inspector enhanced scanning, which adds continuous rescanning of existing images"
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for repository encryption. Leave null to create one."
  type        = string
  default     = null
}

variable "untagged_image_expiry_days" {
  description = "Delete untagged images after this many days"
  type        = number
  default     = 7
}

variable "max_tagged_images" {
  description = "Keep at most this many images per release tag prefix"
  type        = number
  default     = 30
}

variable "release_tag_prefixes" {
  description = "Tag prefixes treated as releases and retained by the lifecycle policy"
  type        = list(string)
  default     = ["v", "release", "main"]
}

variable "pull_principal_arns" {
  description = "IAM principals (for example the EKS node role) granted pull access through the repository policy"
  type        = list(string)
  default     = []
}

variable "name_prefix" {
  description = "Prefix prepended to every repository name"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
