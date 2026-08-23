terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # No backend block on purpose. This stack creates the state bucket, so the
  # first apply has to run against local state. Migrate afterwards:
  #
  #   terraform init -migrate-state \
  #     -backend-config=bucket=<created bucket> \
  #     -backend-config=key=aws/bootstrap/terraform.tfstate \
  #     -backend-config=region=<region>
}
