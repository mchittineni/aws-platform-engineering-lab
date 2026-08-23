# ===========================================================================
# AWS dev environment
#
# The lowest environment: a working cluster with the cheapest posture that is
# still representative of production. Every module here is the same module
# production uses; only the variables differ, so a change can be proven here
# before it reaches production.
# ===========================================================================

locals {
  environment  = "dev"
  cluster_name = "aws-platform-dev"

  common_tags = {
    Environment = local.environment
    Project     = "aws-platform-engineering-lab"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }

  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  # /20 per subnet leaves room for the VPC CNI to hand every pod a real VPC
  # address without renumbering later.
  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr_block, 4, i)]
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr_block, 4, i + 8)]
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

  name       = local.cluster_name
  cidr_block = var.vpc_cidr_block

  availability_zones   = local.availability_zones
  public_subnet_cidrs  = local.public_subnet_cidrs
  private_subnet_cidrs = local.private_subnet_cidrs

  # One NAT gateway keeps the dev bill down. Production uses one per zone.
  single_nat_gateway = true

  enable_flow_logs        = true
  flow_log_retention_days = 30

  kubernetes_cluster_name = local.cluster_name

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  endpoint_private_access = true

  # The public endpoint turns on only when an allow list was supplied, so an
  # empty variable can never mean "open to the internet".
  endpoint_public_access = length(var.api_public_access_cidrs) > 0
  public_access_cidrs    = var.api_public_access_cidrs

  cluster_log_retention_days = 30

  authentication_mode = "API"

  access_entries = {
    for idx, role_arn in var.cluster_admin_role_arns :
    "admin-${idx}" => {
      principal_arn = role_arn
      policy_arns   = ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"]
    }
  }

  node_groups = {
    platform = {
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      desired_size   = 2
      min_size       = 2
      max_size       = 4
      disk_size      = 50
      labels = {
        "platform.aws/pool" = "platform"
      }
    }

    # Spot capacity for anything that tolerates interruption. The taint keeps
    # workloads off it unless they opt in.
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

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Platform controller IAM roles
# ---------------------------------------------------------------------------

module "platform_iam" {
  source = "../../modules/eks-platform-iam"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  enable_aws_load_balancer_controller = true
  enable_cluster_autoscaler           = true
  enable_external_secrets             = true
  enable_external_dns                 = false
  enable_cert_manager                 = false

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

  untagged_image_expiry_days = 7
  max_tagged_images          = 20

  pull_principal_arns = [module.eks.node_iam_role_arn]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Platform observability
#
# Prometheus lives in the cluster, so it cannot report that the cluster is
# gone. These alarms sit outside it.
# ---------------------------------------------------------------------------

module "observability" {
  source = "../../modules/observability"

  cluster_name           = module.eks.cluster_name
  cluster_log_group_name = module.eks.cluster_log_group_name
  nat_gateway_ids        = module.vpc.nat_gateway_ids

  notification_emails = var.alert_emails

  # Node level metrics need the CloudWatch agent, which dev does not run.
  enable_container_insights_alarms = false

  enable_audit_log_alarms = true

  tags = local.common_tags
}
