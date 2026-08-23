# ===========================================================================
# aws-platform-engineering-lab
#
# One entry point for the checks CI runs, so a pull request does not have to
# be the place you find out something is broken.
#
#   make help
# ===========================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV ?= dev

ENVIRONMENTS := bootstrap dev staging production
MODULES      := vpc eks eks-platform-iam irsa ecr tf-state-backend github-oidc \
                security-baseline cost-controls observability backup

TF_STACKS := $(addprefix environments/,$(ENVIRONMENTS)) $(addprefix modules/,$(MODULES))

INVENTORY := ansible/inventory/$(ENV)/hosts.yml
PLAYBOOK  := ansible/playbooks/site.yml

# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  ENV=$(ENV)  (override with: make apply ENV=staging)"

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

.PHONY: fmt
fmt: ## Format every Terraform file in place
	terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is unformatted
	terraform fmt -check -recursive .

.PHONY: init
init: ## terraform init the current ENV against the remote backend
	terraform -chdir=environments/$(ENV) init -input=false \
	  -backend-config=backend.hcl

.PHONY: validate
validate: fmt-check ## Validate every stack and module without credentials
	@for dir in $(TF_STACKS); do \
	  printf '%-38s' "$$dir"; \
	  terraform -chdir=$$dir init -backend=false -input=false >/dev/null; \
	  terraform -chdir=$$dir validate -no-color | tr -d '\n'; \
	  echo; \
	done

.PHONY: plan
plan: ## Plan the current ENV
	terraform -chdir=environments/$(ENV) plan -input=false -out=tfplan

.PHONY: apply
apply: ## Apply the saved plan for the current ENV
	@test -f environments/$(ENV)/tfplan \
	  || { echo "No saved plan. Run: make plan ENV=$(ENV)" >&2; exit 1; }
	terraform -chdir=environments/$(ENV) apply -input=false tfplan

.PHONY: output
output: ## Show the Terraform outputs for the current ENV
	terraform -chdir=environments/$(ENV) output

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------

.PHONY: security
security: ## Run tfsec and Checkov over the Terraform
	tfsec .
	checkov --directory . --framework terraform --quiet --compact

.PHONY: lint
lint: ## Run tflint over every stack and module
	tflint --init
	@for dir in $(TF_STACKS); do \
	  printf '%-38s' "$$dir"; \
	  tflint --chdir=$$dir --format=compact && echo ok; \
	done

.PHONY: secrets
secrets: ## Scan the working tree and history for committed secrets
	gitleaks detect --redact --verbose

# ---------------------------------------------------------------------------
# Ansible
# ---------------------------------------------------------------------------

.PHONY: deps
deps: ## Install the Python packages and Ansible collections
	python3 -m pip install -r ansible/requirements.txt
	ansible-galaxy collection install -r ansible/requirements.yml

.PHONY: ansible-lint
ansible-lint: ## Lint the Ansible content
	ansible-lint

.PHONY: ansible-syntax
ansible-syntax: ## Parse every play, role and template for the current ENV
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --syntax-check

.PHONY: ansible-check
ansible-check: ## Dry run the bootstrap against the current ENV
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --check --diff

.PHONY: bootstrap
bootstrap: ## Run the platform bootstrap against the current ENV
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK)

.PHONY: verify
verify: ## Run only the validation play against the current ENV
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --tags validate

.PHONY: kubeconfig
kubeconfig: ## Write a kubeconfig for the current ENV
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --tags eks_kubeconfig

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------

.PHONY: kube-validate
kube-validate: ## Validate the Kubernetes manifests against the 1.34 schemas
	find kubernetes -type f \( -name '*.yaml' -o -name '*.yml' \) \
	  -not -name 'values*.yaml' -print0 \
	| xargs -0 kubeconform -summary -strict -ignore-missing-schemas \
	    -kubernetes-version 1.34.0

# ---------------------------------------------------------------------------
# Everything
# ---------------------------------------------------------------------------

.PHONY: ci
ci: validate lint security kube-validate ansible-lint ## Run everything CI runs

.PHONY: clean
clean: ## Remove Terraform working directories and saved plans
	find . -type d -name '.terraform' -prune -exec rm -rf {} +
	find . -type f -name 'tfplan' -delete
	find . -type f -name 'plan.txt' -delete
