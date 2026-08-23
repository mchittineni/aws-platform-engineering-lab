provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# Budgets, Cost Anomaly Detection and Cost Explorer are global services whose
# API endpoints only exist in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}
