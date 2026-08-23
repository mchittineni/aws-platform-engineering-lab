variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes minor version, for example 1.34"
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster is deployed into"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets used for the control plane ENIs and the worker nodes"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets attached to the cluster, used for internet facing load balancers"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# API endpoint exposure
# ---------------------------------------------------------------------------

variable "endpoint_private_access" {
  description = "Enable the private Kubernetes API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = <<-EOT
    Enable the public Kubernetes API endpoint. Defaults to false: a cluster
    that only answers inside the VPC is the safe starting point, and an
    environment that needs laptop access opts in explicitly.
  EOT
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. Required when endpoint_public_access is true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes the Kubernetes API to the entire internet. List the specific egress CIDRs that need access."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "service_ipv4_cidr" {
  description = "CIDR block for Kubernetes Service addresses. Must not overlap the VPC CIDR."
  type        = string
  default     = "172.20.0.0/16"
}

# ---------------------------------------------------------------------------
# Control plane observability and lifecycle
# ---------------------------------------------------------------------------

variable "enabled_cluster_log_types" {
  description = "Control plane log types shipped to CloudWatch Logs"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "CloudWatch Logs retention in days for control plane logs"
  type        = number
  default     = 90
}

variable "upgrade_policy_support_type" {
  description = "Cluster support type. STANDARD ends support at end of standard support, EXTENDED keeps the version running at a premium."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.upgrade_policy_support_type)
    error_message = "upgrade_policy_support_type must be STANDARD or EXTENDED."
  }
}

# ---------------------------------------------------------------------------
# Access management
# ---------------------------------------------------------------------------

variable "authentication_mode" {
  description = "Cluster authentication mode. API is the modern access entry based mode."
  type        = string
  default     = "API"

  validation {
    condition     = contains(["API", "API_AND_CONFIG_MAP", "CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be API, API_AND_CONFIG_MAP or CONFIG_MAP."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Grant the identity that created the cluster admin access through an implicit access entry"
  type        = bool
  default     = true
}

variable "access_entries" {
  description = <<-EOT
    Additional EKS access entries, keyed by an arbitrary name.

    Example:
      platform_admins = {
        principal_arn = "arn:aws:iam::111122223333:role/PlatformAdmin"
        policy_arns   = ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"]
      }
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    policy_arns       = optional(list(string), [])
    access_scope_type = optional(string, "cluster")
    namespaces        = optional(list(string))
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Node groups
# ---------------------------------------------------------------------------

variable "node_groups" {
  description = <<-EOT
    Managed node groups, keyed by node group name.

    Example:
      platform = {
        instance_types = ["m6i.large"]
        desired_size   = 3
        min_size       = 3
        max_size       = 6
      }
  EOT
  type = map(object({
    instance_types = optional(list(string), ["m6i.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    desired_size   = optional(number, 2)
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    disk_size      = optional(number, 50)
    disk_type      = optional(string, "gp3")
    labels         = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
    max_unavailable_percentage = optional(number, 33)
    subnet_ids                 = optional(list(string))
  }))
  default = {}
}

variable "node_extra_policy_arns" {
  description = "Additional IAM managed policy ARNs attached to the node instance role"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Add-ons
# ---------------------------------------------------------------------------

variable "addon_versions" {
  description = "Pin add-on versions by add-on name. Unset add-ons resolve to the default version for the cluster."
  type        = map(string)
  default     = {}
}

variable "enable_ebs_csi_driver" {
  description = "Install the EBS CSI driver add-on with a dedicated IRSA role"
  type        = bool
  default     = true
}

variable "enable_pod_identity_agent" {
  description = "Install the EKS Pod Identity agent add-on"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# VPC CNI behaviour
# ---------------------------------------------------------------------------

variable "enable_network_policy" {
  description = <<-EOT
    Let the VPC CNI enforce Kubernetes NetworkPolicy. Leaving this off means
    the API server accepts NetworkPolicy objects and enforces nothing, which
    is worse than having no policies at all.
  EOT
  type        = bool
  default     = true
}

variable "enable_prefix_delegation" {
  description = <<-EOT
    Assign /28 prefixes to node ENIs instead of individual addresses. Raises
    the pods per node ceiling substantially on the same instance type, at the
    cost of reserving more VPC addresses per node.
  EOT
  type        = bool
  default     = true
}

variable "vpc_cni_env" {
  description = "Additional environment variables for the VPC CNI add-on, merged over the defaults"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# CloudWatch observability
# ---------------------------------------------------------------------------

variable "enable_cloudwatch_observability" {
  description = <<-EOT
    Install the amazon-cloudwatch-observability add-on, which collects
    Container Insights metrics and optionally container logs. Required for the
    node level alarms in modules/observability to have any data.
  EOT
  type        = bool
  default     = false
}

variable "enable_enhanced_container_insights" {
  description = "Collect the enhanced Container Insights metric set. More granular, and charged per metric."
  type        = bool
  default     = false
}

variable "enable_container_logs" {
  description = "Ship container stdout and stderr to CloudWatch Logs. Charged per GB ingested, which is usually the largest line on an observability bill."
  type        = bool
  default     = false
}
