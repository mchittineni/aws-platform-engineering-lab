# ---------------------------------------------------------------------------
# GitHub Actions OIDC
#
# Replaces long lived AWS access keys in GitHub secrets with short lived
# credentials minted per workflow run and scoped to a specific ref or
# environment.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub rotates this certificate. Since mid 2023 IAM validates the OIDC
  # provider against the host trust store, so the thumbprint is no longer the
  # security control, but the API still requires a value.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = merge(var.tags, { Name = "github-actions" })
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn
}

data "aws_iam_policy_document" "assume_role" {
  for_each = var.roles

  statement {
    sid     = "AllowGitHubActionsWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name                  = each.key
  description           = coalesce(each.value.description, "GitHub Actions deployment role")
  assume_role_policy    = data.aws_iam_policy_document.assume_role[each.key].json
  max_session_duration  = each.value.max_session_duration
  permissions_boundary  = var.permissions_boundary_arn
  force_detach_policies = true

  tags = var.tags
}

locals {
  managed_attachments = merge([
    for role_name, role in var.roles : {
      for policy_arn in role.managed_policy_arns :
      "${role_name}/${basename(policy_arn)}" => {
        role_name  = role_name
        policy_arn = policy_arn
      }
    }
  ]...)

  inline_attachments = merge([
    for role_name, role in var.roles : {
      for policy_name, policy_json in role.inline_policies :
      "${role_name}/${policy_name}" => {
        role_name   = role_name
        policy_name = policy_name
        policy_json = policy_json
      }
    }
  ]...)
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = local.managed_attachments

  role       = aws_iam_role.this[each.value.role_name].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "inline" {
  for_each = local.inline_attachments

  name   = each.value.policy_name
  role   = aws_iam_role.this[each.value.role_name].id
  policy = each.value.policy_json
}
