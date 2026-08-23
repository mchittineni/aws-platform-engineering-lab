# Security Model

The controls this platform enforces, how each one is enforced, and — in the last
section — what it still does not do. Read the gaps section before treating any
of this as hardened for your own threat model.

A control is only listed here if something fails when it is violated. Anything
that is merely a convention belongs in
[CONTRIBUTING.md](../CONTRIBUTING.md), not here.

## Identity

### No long lived credentials

Nothing in this repository holds an AWS access key.

| Consumer | Credential |
| --- | --- |
| GitHub Actions | OIDC web identity, scoped to a ref or environment |
| Pods | IRSA, projected ServiceAccount token |
| Nodes | Instance profile, minimum managed policies |
| Operators | SSO or assumed role, no IAM users |

`modules/github-oidc` rejects a subject ending in `:*` through a variable
validation. `repo:org/repo:*` lets any branch — including a branch pushed to a
fork by an outside contributor — assume the role.

### Least privilege boundaries

- One IAM role per controller, never a shared platform role
- Node role holds only `AmazonEKSWorkerNodePolicy`,
  `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` and
  `AmazonSSMManagedInstanceCore`
- `permissions_boundary_arn` is available on every role-creating module
- The autoscaler's write actions are conditioned on
  `aws:ResourceTag/k8s.io/cluster-autoscaler/<cluster>` so it can only scale
  its own node groups
- The Load Balancer Controller's mutating actions are conditioned on
  `elbv2.k8s.aws/cluster` tags so it cannot touch load balancers it did not
  create

### Cluster access

EKS access entries, not `aws-auth`. `production` grants
`AmazonEKSClusterAdminPolicy` only to declared roles and
`AmazonEKSViewPolicy` to developers, and revokes the implicit
cluster-creator admin entry.

## Network

| Control | Implementation |
| --- | --- |
| No public node addresses | Nodes live in private subnets, `map_public_ip_on_launch = false` |
| No inbound SSH | No key pair, no port 22 rule; access is SSM Session Manager |
| Default security group | Left with zero rules, named `-default-do-not-use` |
| Private API endpoint | Default in the module, mandatory in production |
| Egress visibility | VPC flow logs to a KMS encrypted CloudWatch group |
| Reduced NAT exposure | Gateway endpoint for S3, interface endpoints for ECR, STS, logs and SSM |

Interface endpoints are protected by their own security group that only allows
443 from the VPC CIDR.

## Data at rest

Every KMS key in this environment is customer managed with rotation enabled and
a 30 day deletion window.

| Data | Key |
| --- | --- |
| Kubernetes Secrets in etcd | `alias/<cluster>-secrets` |
| Control plane logs | `alias/<cluster>-logs` |
| VPC flow logs | `alias/<vpc>-flow-logs` |
| EBS volumes from the CSI driver | `alias/<cluster>-ebs` |
| Container images | `alias/<prefix>` on the ECR repositories |
| Terraform state | `alias/<bucket>` |

Node root volumes are encrypted through the launch template.

## Supply chain

- ECR repositories are `IMMUTABLE`, so a tag cannot be repointed at different
  image content after it has been deployed
- `scan_on_push` in dev; Inspector `CONTINUOUS_SCAN` in production, which
  rescans images already in the registry as new CVEs are published
- Lifecycle policies expire untagged layers, which is also the largest ECR cost
  line in a busy repository

## Workload hardening

Every namespace in `kubernetes/platform/namespaces.yaml` carries a Pod Security
Admission label. That is deliberate rather than tidy: a namespace with **no**
PSA label runs at `privileged`, so an unlabelled namespace is the difference
between a policy and a hope.

- Application namespaces enforce `restricted`.
- `monitoring` enforces `baseline` and audits `restricted`, because
  node-exporter needs the host network and host paths that `restricted`
  forbids. That exception is visible in the manifest rather than hidden in a
  cluster-wide exemption.

The demo workload runs non-root with a read-only root filesystem, all
capabilities dropped and `RuntimeDefault` seccomp. The Checkov job in
`kubernetes-lint.yml` enforces that with an explicit allow list of container
isolation checks, so a regression fails the pull request.

Namespace resource governance is in the same directory as the workload it
governs: a `LimitRange` so a pod with no requests cannot land on a node and
starve it, and a `ResourceQuota` that caps CPU, memory, storage, pod count and
— importantly — sets `services.loadbalancers: "0"`, because an unbounded
LoadBalancer count is an unbounded bill.

### Network policy

`kubernetes/apps/nginx/network-policies.yaml` applies default-deny for both
ingress and egress, then allows exactly what is needed: DNS to CoreDNS, the ALB
subnet range to the workload port, and Prometheus from the `monitoring`
namespace.

The DNS allowance is not optional. A default-deny egress policy without it
breaks every name lookup in the namespace, which is the single most common way
a first NetworkPolicy rollout takes down a cluster.

Enforcement is the part worth verifying rather than assuming. The VPC CNI only
enforces NetworkPolicy when the add-on is configured with
`enableNetworkPolicy`, which `modules/eks` sets by default. Without it the API
server accepts every policy object and enforces none of them — worse than
having no policies, because it looks applied. The `eks_validate` role fails the
run if policy objects exist without the enforcing agent.

## Account baseline

`modules/security-baseline`, applied once per account by
`environments/bootstrap`.

| Control | What it gives you |
| --- | --- |
| CloudTrail, multi-region | The record of who changed what, with log file validation and a customer managed key |
| CloudTrail data events on the audit bucket | Reading or attempting to delete a record is itself recorded |
| AWS Config + 18 rules | The resulting *state*, which is what answers "was this ever open?" months later |
| GuardDuty, with EKS audit log analysis | Kubernetes specific attack patterns, read from the audit log AWS already collects |
| Security Hub, AWS FSBP standard | One score instead of a spreadsheet |
| IAM Access Analyzer | Resources reachable from outside the account |
| Account S3 public access block | Cannot be undone by whoever owns an individual bucket |
| EBS encryption by default | Catches the volume somebody creates by hand in the console |

Detection that only lands in a console tab is not detection. An EventBridge rule
forwards GuardDuty findings at or above the configured severity to an SNS topic,
and six CloudWatch metric filters over the trail alarm on root credential use, a
burst of authorization failures, IAM policy changes, trail tampering, KMS key
deletion and security group changes.

### The pipeline cannot hide its tracks

Both CI role types carry an inline deny policy covering
`cloudtrail:StopLogging`, `guardduty:DeleteDetector`,
`config:StopConfigurationRecorder`, `securityhub:DisableSecurityHub`, deletion
of any object in the audit bucket, and `kms:ScheduleKeyDeletion` on the state
and audit keys.

This matters because the apply roles hold `PowerUserAccess`. Without the deny, a
compromised or simply mistaken pipeline run could disable the audit trail — and
that deletion would be the last thing the trail ever recorded.

An inline deny only binds the role it is attached to, so on its own it is
walkable: with `IAMFullAccess` the apply role could create a second role
carrying `AdministratorAccess` and no deny policy, assume it, and stop the trail
from there. Two API calls, no deny statement violated.

What closes that is the permissions boundary in `aws_iam_policy.ci_boundary` —
the same deny statements plus a blanket allow, attached to both CI role types.
The guardrail additionally denies `iam:CreateRole` and `iam:CreateUser` unless
the new principal carries that exact boundary, denies detaching or replacing it,
and denies rewriting the boundary policy itself. That is what makes the denies
transitive: a role the pipeline creates inherits them whether or not anyone
remembered to attach the policy.

The cost is that every module creating an IAM role must accept and pass
`permissions_boundary_arn`, sourced from the bootstrap output
`ci_permissions_boundary_arn`. An environment that forgets it fails at apply
time rather than quietly creating an unconstrained role, which is the intended
failure mode.

The audit bucket's own policy denies `s3:DeleteObject` to every principal except
an explicitly listed set, defaulting to the account root alone. It deliberately
does **not** deny `s3:PutBucketPolicy`: denying that would lock Terraform out of
its own bucket policy and leave the deny with no way back.

## Backup

`modules/backup` creates an AWS Backup vault with a customer managed key, a
daily and weekly plan, and tag based selection — because the CSI driver creates
and deletes volumes continuously and nothing in Terraform knows their ARNs. A
PVC opts in by choosing the `gp3-backup` StorageClass, which stamps
`platform.aws/backup=true` onto the volume.

Production enables Vault Lock in governance mode: inside the retention window a
recovery point cannot be deleted, and lifting the lock is itself an audited API
call.

What this does **not** cover is Kubernetes object state. A snapshot restores the
data, not the PVC that pointed at it. See
[disaster-recovery.md](disaster-recovery.md).

## Terraform state

- Versioning, so a truncated or corrupted state can be rolled back
- SSE-KMS with a customer managed key
- Bucket policy denies non-TLS requests and unencrypted uploads
- Public access blocked at the bucket level
- Server access logging into a separate bucket with a 90 day expiry
- Locking through S3 conditional writes (`use_lockfile`), not DynamoDB
- Object access is scoped per environment to `aws/<env>/*`. The plan role gets
  `s3:GetObject` and `kms:Decrypt` only; `s3:PutObject` and `s3:DeleteObject`
  belong to the apply role alone. Neither can reach `aws/bootstrap/`, the state
  that defines the CI roles themselves.

## Pipeline controls

| Stage | Control |
| --- | --- |
| Every PR | `terraform fmt`, `validate`, `tflint`, `tfsec`, Checkov |
| Every PR | kubeconform against the 1.34 schemas, plus Checkov container isolation policies |
| Every PR | ansible-lint, and a syntax check of every environment's playbook |
| Every PR touching AWS | Read-only plan per environment, scoped to that environment's state prefix, as one sticky comment |
| Apply | Manual dispatch only, against a protected GitHub environment |
| Apply | Executes the saved plan file, so the reviewed change is the applied change |
| Daily | Scheduled read-only plan per environment; drift opens an issue and a clean plan closes it |
| Weekly | tfsec re-run on a schedule, because a finding can appear when a rule ships rather than when code changes |
| Weekly | Dependabot on GitHub Actions, Terraform providers and the Python requirements |

`gitleaks`, `actionlint`, `yamllint` and `markdownlint` run through
`.pre-commit-config.yaml` on a developer machine and are **not** enforced in CI:
the workflows that ran them have been removed. `make ci` still runs the
Terraform, Kubernetes and Ansible gates. Install the hooks with `pre-commit
install` — for secret scanning in particular, a hook that runs before the commit
is the only version that helps, because CI sees the secret after it is already
in the history.

tfsec results are uploaded as SARIF to code scanning as well as
failing the job, so an accepted finding stays visible instead of being silenced
by a `#tfsec:ignore` nobody revisits.

There are exactly seven such tfsec ignores in the repository, and 56 Checkov
skips across 25 rules, each with its reason on the line above it. The Checkov
set is larger for a mechanical reason rather than a security one: Checkov does
not follow a `count`-indexed resource reference, so a public access block,
versioning rule or lifecycle configuration attached that way is reported as
missing even though it is three resources further down the same file. One is the permissions boundary's blanket allow, which a
wildcard rule cannot distinguish from an over-broad grant. Five are variations
of the same fact: an S3 access log bucket
cannot log to itself, and the S3 log delivery service cannot write to a bucket
encrypted with a customer managed key.

## Known gaps

An honest list. Each entry says why it is still open, because "we know about it"
without a reason is how a gap becomes permanent.

- **Broad CI apply permissions.** The apply roles hold `PowerUserAccess` plus
  `IAMFullAccess`. This is the pragmatic starting point for a stack that creates
  its own IAM roles. What keeps that breadth from covering its own tracks is the
  guardrail deny policy *plus the permissions boundary* — the deny policy alone
  is not enough, because `IAMFullAccess` would otherwise let the apply role
  create a second role without the deny and assume it. It should still be
  narrowed to an explicit action list once the resource set stops changing.
- **Single account.** Dev, staging and production share one AWS account, so the
  isolation between them is IAM and VPC rather than an account boundary. A
  multi-account landing zone with AWS Organizations, SCPs and a delegated
  security account is the correct next step and is a larger change than it
  looks.
- **Single region.** Every environment lives in one region. The backup module
  accepts a cross-region copy destination vault, but no second region is
  provisioned, so a regional event is unrecovered.
- **No image signing or admission policy.** ECR immutability and Inspector
  scanning tell you what an image contains; nothing verifies who built it.
  Cosign plus a policy controller (Kyverno or Gatekeeper) would close this.
- **No Kubernetes object backup.** AWS Backup protects the volumes. Nothing
  captures the API objects, so recovering a namespace means re-syncing from Git
  and re-attaching volumes by hand. Velero is the usual answer.
- **Grafana has no authentication in front of it.** The ingress is `internal`
  and disabled by default, but there is no OIDC proxy. Do not expose it.
- **Secrets are read, not rotated.** External Secrets pulls from Secrets
  Manager; nothing rotates the underlying secret.
- **No runtime threat detection by default.** GuardDuty runtime monitoring is
  implemented but off, because it adds a per-vCPU charge. EKS audit log
  analysis, which is the higher value half, is on.
- **`api_public_access_cidrs` in dev.** Dev can opt into a public API endpoint
  for a named CIDR. That is a convenience for laptop access and it is a real
  reduction in posture; staging and production cannot do it.
