# ===========================================================================
# AWS production environment
#
# Same modules as dev, different posture:
#
#   dev                              production
#   -----------------------------    ----------------------------------
#   one shared NAT gateway           one NAT gateway per zone
#   public API endpoint              private API endpoint
#   30 day log retention             365 day log retention
#   spot node pool                   on demand only for platform workloads
#   basic ECR scanning               Inspector enhanced continuous scanning
# ===========================================================================

locals {
  environment  = "production"
  cluster_name = "aws-platform-prod"

  common_tags = {
    Environment = local.environment
    Project     = "aws-platform-engineering-lab"
    ManagedBy   = "terraform"
    Owner       = var.owner
    Criticality = "high"
  }

  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr_block, 4, i)]
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr_block, 4, i + 8)]

  admin_access_entries = {
    for idx, role_arn in var.cluster_admin_role_arns :
    "admin-${idx}" => {
      principal_arn = role_arn
      policy_arns   = ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"]
    }
  }

  viewer_access_entries = {
    for idx, role_arn in var.cluster_viewer_role_arns :
    "viewer-${idx}" => {
      principal_arn = role_arn
      policy_arns   = ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"]
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  permissions_boundary_arn = var.permissions_boundary_arn

  name       = local.cluster_name
  cidr_block = var.vpc_cidr_block

  availability_zones   = local.availability_zones
  public_subnet_cidrs  = local.public_subnet_cidrs
  private_subnet_cidrs = local.private_subnet_cidrs

  # A shared NAT gateway makes one availability zone a single point of failure
  # for all egress traffic. Production pays for one per zone.
  single_nat_gateway = false

  enable_flow_logs        = true
  flow_log_retention_days = 365

  kubernetes_cluster_name = local.cluster_name

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------

module "eks" {
  source = "../../modules/eks"

  permissions_boundary_arn = var.permissions_boundary_arn

  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = var.endpoint_public_access
  public_access_cidrs     = var.api_public_access_cidrs

  cluster_log_retention_days = 365

  authentication_mode = "API"

  # Nobody keeps admin just because they ran the first apply.
  bootstrap_cluster_creator_admin_permissions = false

  access_entries = merge(local.admin_access_entries, local.viewer_access_entries)

  node_groups = {
    platform = {
      instance_types             = ["m6i.xlarge"]
      capacity_type              = "ON_DEMAND"
      desired_size               = 3
      min_size                   = 3
      max_size                   = 9
      disk_size                  = 100
      max_unavailable_percentage = 25
      labels = {
        "platform.aws/pool" = "platform"
      }
    }
  }

  enable_ebs_csi_driver     = true
  enable_pod_identity_agent = true

  # One switch drives both the add-on that produces the metrics and the alarms
  # that read them, so the two cannot drift apart.
  enable_cloudwatch_observability = var.enable_container_insights

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Platform controller IAM roles
# ---------------------------------------------------------------------------

module "platform_iam" {
  source = "../../modules/eks-platform-iam"

  permissions_boundary_arn = var.permissions_boundary_arn

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  enable_aws_load_balancer_controller = true
  enable_cluster_autoscaler           = true
  enable_external_secrets             = true
  enable_external_dns                 = true
  enable_cert_manager                 = true

  route53_hosted_zone_arns = var.route53_hosted_zone_arns

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Container registry
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  repositories = var.ecr_repositories
  name_prefix  = "${local.cluster_name}/"

  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true

  enable_registry_enhanced_scanning = true

  untagged_image_expiry_days = 3
  max_tagged_images          = 50

  pull_principal_arns = [module.eks.node_iam_role_arn]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Platform observability
# ---------------------------------------------------------------------------

module "observability" {
  source = "../../modules/observability"

  cluster_name           = module.eks.cluster_name
  cluster_log_group_name = module.eks.cluster_log_group_name
  nat_gateway_ids        = module.vpc.nat_gateway_ids

  notification_emails   = var.alert_emails
  additional_topic_arns = var.additional_alert_topic_arns

  # Production runs the amazon-cloudwatch-observability add-on, so the node
  # level metrics these alarms read actually exist.
  enable_container_insights_alarms = var.enable_container_insights

  enable_audit_log_alarms = true
  enable_composite_alarm  = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Persistent volume backup
#
# A PVC backed by an EBS volume has no backup unless something takes one. The
# plan selects volumes by tag, and the gp3 StorageClass is what applies that
# tag, so a workload opts in by choosing the class.
#
# This protects the data, not the Kubernetes objects. Restoring a namespace is
# a separate procedure: docs/disaster-recovery.md.
# ---------------------------------------------------------------------------

module "backup" {
  source = "../../modules/backup"

  permissions_boundary_arn = var.permissions_boundary_arn

  name = local.cluster_name

  rules = {
    daily = {
      schedule          = "cron(0 3 * * ? *)"
      delete_after_days = 35
    }
    weekly = {
      schedule                = "cron(0 4 ? * SUN *)"
      cold_storage_after_days = 30
      delete_after_days       = 365
    }
  }

  selection_tags = {
    "platform.aws/backup" = "true"
  }

  # Vault Lock in governance mode: inside the retention window a recovery
  # point cannot be deleted, and lifting the lock is itself an audited call.
  vault_lock_min_retention_days = var.backup_vault_lock_min_retention_days

  copy_destination_vault_arn = var.backup_copy_destination_vault_arn

  notification_emails = var.alert_emails

  tags = local.common_tags
}
