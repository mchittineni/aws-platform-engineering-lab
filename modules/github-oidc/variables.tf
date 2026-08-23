variable "create_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Only one may exist per AWS account, so set this to false in every account that already has one."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider, required when create_oidc_provider is false"
  type        = string
  default     = null
}

variable "roles" {
  description = <<-EOT
    Deployment roles keyed by role name.

    `subjects` are GitHub OIDC subject claims. Scope them as tightly as the
    workflow allows:

      repo:org/repo:ref:refs/heads/main      a single branch
      repo:org/repo:environment:production   a protected environment
      repo:org/repo:pull_request             pull request runs, plan only

    Never use `repo:org/repo:*` for a role that can apply.
  EOT
  type = map(object({
    subjects             = list(string)
    managed_policy_arns  = optional(list(string), [])
    inline_policies      = optional(map(string), {})
    max_session_duration = optional(number, 3600)
    description          = optional(string)
  }))

  validation {
    condition = alltrue(flatten([
      for role in var.roles : [
        for subject in role.subjects : !endswith(subject, ":*")
      ]
    ]))
    error_message = "Wildcard subjects such as repo:org/repo:* let any branch or fork assume the role. Scope subjects to a ref, environment or pull_request."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary applied to every role"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}
