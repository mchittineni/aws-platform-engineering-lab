# ---------------------------------------------------------------------------
# AWS Backup for cluster persistent volumes
#
# An EBS volume provisioned by the CSI driver has no backup unless something
# takes one. AWS Backup selects volumes by tag, so a PVC only has to end up
# with the right tag to be protected, and the CSI driver can be told to apply
# it through the StorageClass.
#
# What this does NOT cover: Kubernetes object state. A snapshot restores the
# data, not the PVC that pointed at it. Recovering a namespace needs Velero or
# an equivalent, which is documented in docs/disaster-recovery.md.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# ---------------------------------------------------------------------------
# Vault
# ---------------------------------------------------------------------------

resource "aws_kms_key" "backup" {
  count = var.kms_key_arn == null ? 1 : 0

  description             = "Encrypts ${var.name} recovery points"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_kms_alias" "backup" {
  count = var.kms_key_arn == null ? 1 : 0

  name          = "alias/${var.name}-backup"
  target_key_id = aws_kms_key.backup[0].key_id
}

locals {
  kms_key_arn = var.kms_key_arn != null ? var.kms_key_arn : aws_kms_key.backup[0].arn
}

resource "aws_backup_vault" "this" {
  name        = var.name
  kms_key_arn = local.kms_key_arn

  tags = merge(var.tags, { Name = var.name })
}

# Ransomware and fat-finger protection: inside the retention window nobody can
# delete a recovery point, not even an administrator. In governance mode a
# principal holding backup:DisableVaultLock can lift it; compliance mode
# cannot be lifted by anyone, so it is opt in.
resource "aws_backup_vault_lock_configuration" "this" {
  count = var.vault_lock_min_retention_days > 0 ? 1 : 0

  backup_vault_name   = aws_backup_vault.this.name
  min_retention_days  = var.vault_lock_min_retention_days
  max_retention_days  = var.vault_lock_max_retention_days
  changeable_for_days = var.vault_lock_compliance_mode ? var.vault_lock_changeable_for_days : null
}

# ---------------------------------------------------------------------------
# Service role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  description        = "Service role AWS Backup assumes to snapshot and restore ${var.name} resources"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Attached up front. Discovering during an incident that the role can snapshot
# but not restore is not a discovery anyone wants to make.
resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

resource "aws_backup_plan" "this" {
  name = var.name

  dynamic "rule" {
    for_each = var.rules

    content {
      rule_name         = rule.key
      target_vault_name = aws_backup_vault.this.name
      schedule          = rule.value.schedule
      start_window      = rule.value.start_window_minutes
      completion_window = rule.value.completion_window_minutes

      # Continuous backup enables point in time restore for the services that
      # support it. EBS is not one of them, so it stays off by default.
      enable_continuous_backup = rule.value.continuous_backup

      lifecycle {
        cold_storage_after = rule.value.cold_storage_after_days
        delete_after       = rule.value.delete_after_days
      }

      dynamic "copy_action" {
        for_each = var.copy_destination_vault_arn == null ? [] : [1]

        content {
          destination_vault_arn = var.copy_destination_vault_arn

          lifecycle {
            delete_after = rule.value.copy_delete_after_days
          }
        }
      }

      recovery_point_tags = merge(var.tags, { BackupRule = rule.key })
    }
  }

  advanced_backup_setting {
    resource_type = "EC2"
    backup_options = {
      # Application consistent Windows snapshots. Harmless on Linux nodes and
      # required if a Windows node group is ever added.
      WindowsVSS = "disabled"
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Selection
#
# Tag based rather than ARN based, because the CSI driver creates and deletes
# volumes continuously. Nothing in Terraform knows their ARNs.
# ---------------------------------------------------------------------------

resource "aws_backup_selection" "this" {
  name         = "${var.name}-tagged"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.this.id

  resources = var.selection_resource_arns

  dynamic "selection_tag" {
    for_each = var.selection_tags

    content {
      type  = "STRINGEQUALS"
      key   = selection_tag.key
      value = selection_tag.value
    }
  }
}

# ---------------------------------------------------------------------------
# Notifications
#
# A backup job that has been failing silently for six weeks is worse than no
# backup, because it is believed.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Notification key
#
# The AWS managed alias/aws/sns key cannot be audited, rotated or revoked
# independently of the account, so the topic gets its own customer managed key.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "topic" {
  count = var.sns_kms_key_id == null ? 1 : 0

  description             = "Encrypts messages published to the ${var.name} backup event topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.topic_kms[0].json

  tags = merge(var.tags, { Name = "${var.name}-backup-events" })
}

resource "aws_kms_alias" "topic" {
  count = var.sns_kms_key_id == null ? 1 : 0

  name          = "alias/${var.name}-backup-events"
  target_key_id = aws_kms_key.topic[0].key_id
}

data "aws_iam_policy_document" "topic_kms" {
  count = var.sns_kms_key_id == null ? 1 : 0

  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  # Without this the publishing service can reach the topic but cannot
  # encrypt the message, and the publish fails with KMSAccessDenied.
  statement {
    sid       = "AllowPublishingServices"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

locals {
  topic_kms_key_id = var.sns_kms_key_id != null ? var.sns_kms_key_id : aws_kms_key.topic[0].arn
}

resource "aws_sns_topic" "backup" {
  count = var.create_sns_topic ? 1 : 0

  name              = "${var.name}-backup-events"
  kms_master_key_id = local.topic_kms_key_id

  tags = merge(var.tags, { Name = "${var.name}-backup-events" })
}

data "aws_iam_policy_document" "topic" {
  count = var.create_sns_topic ? 1 : 0

  statement {
    sid       = "AllowBackupPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.backup[0].arn]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "backup" {
  count = var.create_sns_topic ? 1 : 0

  arn    = aws_sns_topic.backup[0].arn
  policy = data.aws_iam_policy_document.topic[0].json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.create_sns_topic ? toset(var.notification_emails) : toset([])

  topic_arn = aws_sns_topic.backup[0].arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  notification_topic_arn = var.create_sns_topic ? aws_sns_topic.backup[0].arn : var.notification_topic_arn
}

resource "aws_backup_vault_notifications" "this" {
  count = local.notification_topic_arn == null ? 0 : 1

  backup_vault_name   = aws_backup_vault.this.name
  sns_topic_arn       = local.notification_topic_arn
  backup_vault_events = var.notification_events

  depends_on = [aws_sns_topic_policy.backup]
}
