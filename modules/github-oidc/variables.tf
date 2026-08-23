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

    Subjects are validated against that closed set of shapes. A subject
    containing `*` is rejected outright: the trust policy matches `sub` with
    `StringLike`, so a single `*` in the wrong place widens the role from one
    branch to every repository on GitHub.
  EOT
  type = map(object({
    subjects             = list(string)
    managed_policy_arns  = optional(list(string), [])
    inline_policies      = optional(map(string), {})
    max_session_duration = optional(number, 3600)
    description          = optional(string)
  }))

  # Rejecting `*` anywhere, rather than only a trailing `:*`, is the point.
  # `endswith(subject, ":*")` catches `repo:org/repo:*` but lets through
  # `repo:org/*`, `repo:org/repo:ref:refs/heads/*` and a bare `*` — each of
  # which is broader than the subject it was meant to block.
  validation {
    condition = alltrue(flatten([
      for role in var.roles : [
        for subject in role.subjects : !strcontains(subject, "*")
      ]
    ]))
    error_message = "OIDC subjects must not contain '*'. The trust policy matches sub with StringLike, so any wildcard widens the role beyond the intended branch, environment or repository."
  }

  # An allowlist of the three shapes GitHub actually issues, so a malformed or
  # creatively-scoped subject fails at plan time rather than becoming a trust
  # policy nobody re-reads.
  validation {
    condition = alltrue(flatten([
      for role in var.roles : [
        for subject in role.subjects : can(regex(
          "^repo:[^/*:]+/[^/*:]+:(pull_request|environment:[^*]+|ref:refs/(heads|tags)/[^*]+)$",
          subject
        ))
      ]
    ]))
    error_message = "Each OIDC subject must be one of repo:org/repo:pull_request, repo:org/repo:environment:NAME, or repo:org/repo:ref:refs/heads/BRANCH (refs/tags/TAG also accepted)."
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
