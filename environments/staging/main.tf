# ===========================================================================
# AWS staging environment
#
# Staging exists to make production changes boring. It therefore matches the
# production posture wherever a difference would hide a failure, and only
# saves money where the difference cannot:
#
#   dev                      staging                    production
#   ----------------------   ------------------------   ----------------------
#   one shared NAT gateway   one NAT gateway per zone   one NAT gateway per zone
#   public API opt in        private API endpoint       private API endpoint
#   30 day log retention     90 day log retention       365 day log retention
#   2 on demand nodes        2 on demand + spot pool    3 on demand nodes
#   no backup plan           7 day backup retention     35 / 365 day retention
#
# The private API endpoint is the important one: if staging can be reached
# from a laptop and production cannot, staging never exercises the access path
# production actually uses.
# ===========================================================================

locals {
  environment  = "staging"
  cluster_name = "aws-platform-staging"

  common_tags = {
    Environment = local.environment
    Project     = "aws-platform-engineering-lab"
    ManagedBy   = "terraform"
    Owner       = var.owner
    Criticality = "medium"
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

  # Matches production. A shared NAT gateway in staging would hide the
  # per zone routing behaviour production depends on.
  single_nat_gateway = false

  enable_flow_logs        = true
  flow_log_retention_days = 90

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

  cluster_log_retention_days = 90

  authentication_mode = "API"

  # Same as production: nobody keeps admin because they ran the first apply.
  bootstrap_cluster_creator_admin_permissions = false

  access_entries = merge(local.admin_access_entries, local.viewer_access_entries)

  node_groups = {
    platform = {
      instance_types             = ["m6i.large"]
      capacity_type              = "ON_DEMAND"
      desired_size               = 2
      min_size                   = 2
      max_size                   = 6
      disk_size                  = 50
      max_unavailable_percentage = 25
      labels = {
        "platform.aws/pool" = "platform"
      }
    }

    # Staging keeps a spot pool so that spot interruption handling is
    # exercised somewhere other than production.
    spot = {
      instance_types = ["m6i.large", "m6a.large", "m5.large"]
      capacity_type  = "SPOT"
      desired_size   = 1
      min_size       = 0
      max_size       = 6
      labels = {
        "platform.aws/pool" = "spot"
      }
      taints = {
        spot = {
          key    = "platform.aws/spot"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
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
#
# Staging pulls the images production will run, so it points at the production
# registry rather than building its own. Set ecr_repositories to create
# staging-only repositories instead.
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  repositories = var.ecr_repositories
  name_prefix  = "${local.cluster_name}/"

  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true

  untagged_image_expiry_days = 7
  max_tagged_images          = 30

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

  notification_emails = var.alert_emails

  enable_container_insights_alarms = var.enable_container_insights
  enable_audit_log_alarms          = true
  enable_composite_alarm           = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Persistent volume backup
#
# Short retention on purpose. The point of a backup plan in staging is not the
# data, it is proving that the restore procedure in
# docs/disaster-recovery.md still works before it is needed in production.
# ---------------------------------------------------------------------------

module "backup" {
  source = "../../modules/backup"

  permissions_boundary_arn = var.permissions_boundary_arn

  name = local.cluster_name

  rules = {
    daily = {
      schedule          = "cron(0 3 * * ? *)"
      delete_after_days = 7
    }
  }

  selection_tags = {
    "platform.aws/backup" = "true"
  }

  # No vault lock: staging is where a restore is rehearsed, which sometimes
  # means cleaning up afterwards.
  vault_lock_min_retention_days = 0

  notification_emails = var.alert_emails

  tags = local.common_tags
}
