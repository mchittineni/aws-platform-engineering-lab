# Bootstrap Runbook

End to end procedure for standing up an environment from an empty AWS account.

Read [architecture.md](architecture.md) first if you have not: the order of the
steps below only makes sense once the Terraform / Ansible / Argo CD boundary is
clear.

## Prerequisites

- An AWS account, plus credentials with administrator access **for the first
  bootstrap apply only**. Everything afterwards runs as a scoped role.
- Terraform matching `.terraform-version`
- AWS CLI v2, `kubectl`, `helm`, `jq`
- Python and Ansible

```bash
make deps          # python packages + ansible collections
make validate      # confirm the checkout is sound before touching AWS
```

## Step 1 — Bootstrap the account

Creates the Terraform state bucket and its KMS key, the GitHub Actions OIDC
provider, the CI roles, the security baseline (CloudTrail, Config, GuardDuty,
Security Hub, Access Analyzer) and the budgets.

This is the only stack that ever runs with local state, because it is the stack
that creates the bucket the others use.

```bash
cd environments/bootstrap
cp terraform.tfvars.example terraform.tfvars
```

Set at minimum:

| Variable | Notes |
| --- | --- |
| `state_bucket_name` | Globally unique across all of S3 |
| `github_repository` | `org/repo`, exactly — validated |
| `security_notification_emails` | Each address must confirm the SNS subscription |
| `cost_notification_emails` | Same |
| `audit_object_lock_days` | **Decide now.** Object Lock cannot be added to an existing bucket |

```bash
terraform init
terraform apply
```

Record the outputs:

```bash
terraform output backend_hcl
terraform output -json ci_role_arns
terraform output audit_bucket_name
terraform output security_alert_topic_arn
```

Then migrate this stack's own state into the bucket it just created:

```bash
terraform init -migrate-state \
  -backend-config="bucket=$(terraform output -raw state_bucket_name)" \
  -backend-config="key=aws/bootstrap/terraform.tfstate" \
  -backend-config="region=eu-central-1"
```

Confirm the SNS email subscriptions from your inbox. An unconfirmed
subscription means the alarms fire into nothing.

### Wire up GitHub

Set these as **repository variables** (Settings, Secrets and variables,
Actions, Variables). They are not secrets: a role ARN is useless without a
matching OIDC trust policy, and putting them in secrets only makes the workflow
logs harder to read.

| Variable | Value |
| --- | --- |
| `AWS_REGION` | The region used above |
| `AWS_TF_STATE_BUCKET` | `state_bucket_name` output |
| `AWS_DEV_PLAN_ROLE_ARN` | `aws-platform-lab-dev-plan` |
| `AWS_STAGING_PLAN_ROLE_ARN` | `aws-platform-lab-staging-plan` |
| `AWS_PRODUCTION_PLAN_ROLE_ARN` | `aws-platform-lab-production-plan` |

Then create three GitHub **environments** — `aws-dev`, `aws-staging`,
`aws-production` — and in each one set:

| Environment variable | Value |
| --- | --- |
| `AWS_APPLY_ROLE_ARN` | `aws-platform-lab-<env>-apply` |

Add required reviewers to `aws-staging` and `aws-production`.

This is the whole access control story, so it is worth being precise about why
it works: each apply role trusts only the OIDC subject
`repo:<org>/<repo>:environment:aws-<env>`. GitHub only issues a token with that
subject to a job that declares `environment: aws-<env>`, and it only starts such
a job after the environment's protection rules are satisfied. So the
environment protection rules are not advisory — they are the thing that gates a
production apply, enforced by STS.

`modules/github-oidc` rejects any subject ending in `:*` through variable
validation, because `repo:org/repo:*` would let any branch in any fork assume
the role.

## Step 2 — Provision the environment

Start with `dev`. Do not skip ahead to production: the point of three
environments is that the same change is proven twice before it matters.

```bash
cd environments/dev
cp backend.hcl.example backend.hcl        # values from: terraform output backend_hcl
cp terraform.tfvars.example terraform.tfvars

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Roughly 15 minutes: the control plane takes about 10, the node groups another 3
to 5.

Or through the Makefile:

```bash
make init ENV=dev
make plan ENV=dev
make apply ENV=dev
```

For `staging` and `production`, set `cluster_admin_role_arns` to the CI apply
role for that environment. Production also sets
`bootstrap_cluster_creator_admin_permissions = false` in the module call, so
whoever ran the first apply does not keep cluster admin afterwards — the access
entries are the only way in.

## Step 3 — Bootstrap the platform

The Ansible inventory reads ARNs from the environment rather than from a
committed file, because an ARN carries the account ID.

```bash
cd environments/dev

export EKS_VPC_ID=$(terraform output -raw vpc_id)
export EBS_KMS_KEY_ARN=$(terraform output -raw ebs_kms_key_arn)

ROLES=$(terraform output -json platform_controller_role_arns)
export ALB_CONTROLLER_ROLE_ARN=$(jq -r '."aws-load-balancer-controller"' <<<"$ROLES")
export CLUSTER_AUTOSCALER_ROLE_ARN=$(jq -r '."cluster-autoscaler"' <<<"$ROLES")
export EXTERNAL_SECRETS_ROLE_ARN=$(jq -r '."external-secrets" // ""' <<<"$ROLES")
export EXTERNAL_DNS_ROLE_ARN=$(jq -r '."external-dns" // ""' <<<"$ROLES")
export CERT_MANAGER_ROLE_ARN=$(jq -r '."cert-manager" // ""' <<<"$ROLES")

export GITOPS_REPO_URL="https://github.com/<org>/aws-platform-engineering-lab.git"

cd ../..
make bootstrap ENV=dev
```

Dry run first if you want to see what would change:

```bash
make ansible-check ENV=dev
```

Individual stages re-run by tag:

```bash
ansible-playbook -i ansible/inventory/dev/hosts.yml ansible/playbooks/site.yml \
  --tags eks_platform
```

Available tags: `eks_kubeconfig`, `eks_platform`, `eks_storage`, `argocd`,
`argocd_bootstrap`, `eks_validate`.

## Step 4 — Validate

The playbook's last stage validates the cluster and fails if it is not sound, so
a green run already means the checks below passed. Run it on its own at any
time:

```bash
make verify ENV=dev
```

It asserts:

- enough nodes are `Ready`, and they span at least two availability zones
- there is **exactly one** default StorageClass — two makes PVC binding
  non-deterministic, none leaves every unqualified PVC `Pending` forever
- `coredns`, the ALB controller, `metrics-server` and `ebs-csi-controller` each
  have a ready replica
- every Argo CD Application is `Synced` and `Healthy`
- if any NetworkPolicy object exists, the VPC CNI is actually enforcing it

That last one is the check worth having. Without `enableNetworkPolicy` on the
vpc-cni add-on, the API server accepts every NetworkPolicy and enforces none of
them, which is worse than having no policies: it looks applied.

By hand:

```bash
export KUBECONFIG=~/.kube/aws-platform-dev.config

kubectl get nodes -o wide
kubectl get storageclass
kubectl -n argocd get applications
kubectl -n demo get ingress          # ADDRESS should hold an ALB hostname
kubectl top nodes                    # proves metrics-server works
```

## Step 5 — Promote

```text
dev  →  staging  →  production
```

Apply through the `Terraform Apply` workflow, not from a laptop: a laptop has
no path to the apply role. For each environment, read the plan the workflow
prints before approving, and look specifically for anything being **replaced**
rather than updated. A replaced node group is a rolling outage and a replaced
KMS key is data loss, and neither looks different from an update in the diff.

## Reaching a private API endpoint

`staging` and `production` keep the endpoint private. The nodes carry
`AmazonSSMManagedInstanceCore`, so there is no bastion and no SSH key:

```bash
CLUSTER=aws-platform-prod

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.endpoint' --output text | sed 's|https://||')

aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ENDPOINT,portNumber=443,localPortNumber=8443"
```

Then point kubectl at `https://localhost:8443`. Note that the certificate is
issued for the real endpoint hostname, so a `/etc/hosts` entry or
`--insecure-skip-tls-verify` is needed — prefer the hosts entry, since skipping
verification on the production API server is a habit worth not forming.

## Teardown

Order matters. Kubernetes creates AWS resources Terraform does not know about,
and a VPC will not delete while an orphaned load balancer still holds an ENI in
it.

```bash
# 1. Let the controllers delete what they created
kubectl delete ingress --all -A
kubectl delete svc -A --field-selector spec.type=LoadBalancer
kubectl delete pvc --all -A

# 2. Wait until the load balancers and volumes are actually gone
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-volumes --filters Name=status,Values=available

# 3. Then
cd environments/dev
terraform destroy
```

Two things will refuse to be destroyed, deliberately:

- **The audit bucket.** Its policy denies object deletion. Emptying it is a
  separate, explicit act, and the policy change is itself recorded.
- **A backup vault with Vault Lock.** Recovery points cannot be deleted inside
  the retention window. That is the point of the lock.

The `bootstrap` stack is deliberately left standing. Destroying it deletes the
bucket holding every other state file, and the state is the only record of what
was created.
