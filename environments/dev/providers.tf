provider "aws" {
  region = var.region

  # Every resource in this environment carries these tags, which is what makes
  # cost allocation and orphan detection possible later.
  default_tags {
    tags = local.common_tags
  }
}
