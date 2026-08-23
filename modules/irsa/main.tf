locals {
  subjects = [for sa in var.service_accounts : "system:serviceaccount:${split("/", sa)[0]}:${split("/", sa)[1]}"]

  # A wildcard anywhere in the list forces StringLike for the whole condition.
  # StringLike is a superset of StringEquals for literal values, so exact
  # subjects keep matching.
  uses_wildcard = length([for s in local.subjects : s if strcontains(s, "*")]) > 0
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowServiceAccountWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = local.uses_wildcard ? "StringLike" : "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = local.subjects
    }

    # Without the audience check any web identity token issued by the provider
    # would satisfy the trust policy.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                  = var.role_name
  description           = var.description
  assume_role_policy    = data.aws_iam_policy_document.assume_role.json
  max_session_duration  = var.max_session_duration
  permissions_boundary  = var.permissions_boundary_arn
  force_detach_policies = true

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.id
  policy = each.value
}
