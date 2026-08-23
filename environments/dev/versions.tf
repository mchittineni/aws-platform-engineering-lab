terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Partial backend configuration. The bucket is created by
  # environments/bootstrap and supplied at init time:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # use_lockfile replaces the DynamoDB lock table with S3 conditional writes.
  backend "s3" {
    key          = "aws/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
