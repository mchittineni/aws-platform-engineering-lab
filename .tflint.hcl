# TFLint configuration
#
# The AWS ruleset catches things terraform validate cannot: invalid instance
# types, deprecated arguments, missing tags, malformed ARNs.

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Every module variable carries a description in this repository.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Modules are pinned by the caller, not inside the module.
rule "terraform_module_pinned_source" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# A variable without a type accepts anything, which turns a typo in a tfvars
# file into a confusing plan rather than an error.
rule "terraform_typed_variables" {
  enabled = true
}
