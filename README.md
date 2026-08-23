# AWS Platform Engineering Lab

A production-shaped AWS platform, built entirely as code: EKS across three
availability zones, GitOps delivery, observability inside and outside the
cluster, an account security baseline that is enforced rather than documented,
and three environments that differ only in variables.

AWS is the only target. There is no abstraction layer over other providers,
which means every module can use the right AWS primitive instead of the lowest
common denominator.

## What it builds

```text
                        Internet
                            |
                   Internet gateway
                            |
        +-------------------+-------------------+
        |                   |                   |
   public subnet a     public subnet b     public subnet c
   ALB, NAT gw a       ALB, NAT gw b       ALB, NAT gw c
        |                   |                   |
   private subnet a    private subnet b    private subnet c
        |                   |                   |
   managed node group  managed node group  managed node group
        |                   |                   |
        +-------------------+-------------------+
                            |
                 +----------------------+
                 |   EKS control plane  |
                 |  AWS managed, 3 AZ   |
                 +----------------------+
```

| Layer | What |
| --- | --- |
| Network | 3-AZ VPC, public and private subnets, NAT, S3 gateway endpoint plus 7 interface endpoints, KMS-encrypted flow logs |
| Kubernetes | EKS with Secret envelope encryption, all 5 log types, access-entry auth, IMDSv2-only launch templates |
| Identity | IRSA per controller, GitHub OIDC for CI, permissions boundary on every role CI creates. No long-lived AWS credential anywhere |
| Storage | EBS CSI driver, gp3 as the cluster default, gp3-retain and gp3-backup classes |
| Ingress | AWS Load Balancer Controller, one shared ALB per environment |
| Delivery | Argo CD, prune and self-heal on, values layered per environment |
| Observability | kube-prometheus-stack in cluster; CloudWatch alarms, audit-log detections and a dashboard outside it |
| Security | CloudTrail, Config, GuardDuty with EKS audit analysis, Security Hub, Access Analyzer, plus a deny the pipeline cannot lift |
| Cost | Per-environment budgets, forecast alerts, cost anomaly detection |
| Recovery | AWS Backup with tag selection and Vault Lock, versioned Terraform state |

## Three tools, three jobs

```text
Terraform  ──►  AWS API           VPC, EKS, IAM, KMS, ECR, alarms, backup
Ansible    ──►  Kubernetes API    controllers, storage class, Argo CD itself
Argo CD    ──►  Kubernetes API    everything else, reconciled from Git
```

The boundary is which API is being called, and it is a hard line. Terraform
state never holds Kubernetes objects; Ansible never creates AWS resources. Once
Argo CD is running, neither of them is how the cluster changes.

Reasoning, and the alternatives rejected, in
[ADR 0001](docs/adr/0001-terraform-ansible-argocd-split.md).

## Repository layout

```text
environments/
├── bootstrap/     # state backend, CI roles, security baseline, budgets
├── dev/           # cheapest posture that still exercises the same code
├── staging/       # production shaped, so production changes are boring
└── production/    # private API, per-zone NAT, backup, vault lock

modules/
├── vpc/                 ├── security-baseline/   # CloudTrail, Config, GuardDuty
├── eks/                 ├── observability/       # CloudWatch alarms, dashboard
├── eks-platform-iam/    ├── cost-controls/       # budgets, anomaly detection
├── irsa/                ├── backup/              # AWS Backup vault and plan
├── ecr/                 ├── tf-state-backend/
└── github-oidc/

ansible/
├── inventory/<env>/     # group_vars per environment, plus aws_ec2 discovery
├── roles/               # eks_kubeconfig, eks_platform, eks_storage,
│                        # argocd, argocd_bootstrap, eks_validate
└── playbooks/site.yml   # the whole bootstrap, tagged per stage

kubernetes/
├── platform/            # namespaces with PSA labels, priority classes
├── apps/nginx/          # a workload, with its quota and network policies
├── monitoring/          # kube-prometheus-stack values, base + per env
└── storage/             # gp3-retain, gp3-backup StorageClasses

docs/                    # architecture, runbooks, security model, ADRs
```

## Quick start

```bash
make deps       # python packages + ansible collections
make validate   # fmt + terraform validate on every stack and module
make ci         # everything CI runs
```

Then follow [docs/bootstrap.md](docs/bootstrap.md), which is the real entry
point. In outline:

```bash
# 1. Once per AWS account
cd environments/bootstrap && terraform init && terraform apply

# 2. Per environment
make init ENV=dev && make plan ENV=dev && make apply ENV=dev

# 3. The platform layer
make bootstrap ENV=dev

# 4. Confirm it is actually healthy
make verify ENV=dev
```

Roughly 20 minutes for step 2, most of it the control plane.

## Environments

Every environment calls the same modules. Only variables differ, so the entire
difference between dev and production is readable in one file each.

| Setting | dev | staging | production |
| --- | --- | --- | --- |
| VPC CIDR | `10.20.0.0/16` | `10.25.0.0/16` | `10.30.0.0/16` |
| NAT gateways | 1 shared | 1 per zone | 1 per zone |
| API endpoint | private, public opt-in per CIDR | private only | private only |
| Node pools | on demand + spot | on demand + spot | on demand |
| Creator admin access | granted | revoked | revoked |
| Control plane logs | 30 days | 90 days | 365 days |
| ECR scanning | scan on push | scan on push | Inspector continuous |
| Argo CD | single replica | HA | HA |
| Backup | none | 7 day | 35 / 365 day, vault lock |

Staging keeps the API endpoint private on purpose: if staging is reachable from
a laptop and production is not, staging never exercises the access path
production uses.

## Security posture

Not a list of intentions — each of these fails a build, a plan, or an API call
when violated.

- **No long-lived AWS credentials.** CI uses the GitHub OIDC provider, pods use
  IRSA. Subjects are validated against a closed allowlist of the three shapes
  GitHub issues, and any subject containing `*` is rejected — a trailing-`:*`
  check would still admit `repo:org/*` and a bare `*`.
- **No SSH.** No key pair, no inbound port 22. Access is Session Manager, which
  is IAM-authenticated and recorded in CloudTrail.
- **The pipeline cannot hide its tracks.** Both CI role types carry a deny policy
  covering `cloudtrail:StopLogging`, `guardduty:DeleteDetector`, deletion of any
  audit record, and `kms:ScheduleKeyDeletion` on the state and audit keys — and
  a permissions boundary that makes those denies transitive. Without the
  boundary the deny is walkable: `IAMFullAccess` would let the apply role create
  an unconstrained second role and assume it.
- **A plan cannot write state.** The plan role holds `s3:GetObject` and
  `kms:Decrypt` on its own environment's `aws/<env>/*` prefix only. `PutObject`
  and `DeleteObject` belong to the apply role, so a pull request cannot overwrite
  production state, and neither role can reach the bootstrap state that defines
  them.
- **`0.0.0.0/0` on the Kubernetes API is rejected** by variable validation, not
  by review.
- **Every KMS key is customer managed** with rotation and a 30 day deletion
  window.
- **NetworkPolicy is actually enforced.** The VPC CNI add-on is configured with
  `enableNetworkPolicy`, and the validation role fails the run if policy objects
  exist without the enforcing agent — because a policy the API server accepts
  and nothing enforces is worse than no policy.
- **tfsec and Checkov pass with zero findings.** The seven `#tfsec:ignore` and
  56 `#checkov:skip` comments each carry their reason on the line above.

The model, including the gaps that are known and accepted — single account,
single region, broad CI apply permissions, no image signing — is in
[docs/security.md](docs/security.md). Read the gaps section before treating this
as hardened for your own threat model.

## Pipeline

| When | What runs |
| --- | --- |
| Every PR | `terraform fmt`, `validate`, `tflint`, `tfsec`, Checkov, gitleaks, actionlint |
| Every PR | kubeconform against the 1.34 schemas, Checkov container isolation policies |
| Every PR | ansible-lint, plus a playbook syntax check for all three environments |
| Every PR touching AWS | Read-only plan per environment, scoped to that environment's state prefix, posted as one sticky comment |
| Apply | Manual dispatch against a protected GitHub environment, executing the **saved** plan |
| Daily | Read-only plan per environment; drift opens an issue, a clean plan closes it |
| Weekly | tfsec on a schedule, and Dependabot on actions, providers and Python deps |

The apply role trusts only `repo:<org>/<repo>:environment:aws-<env>`. GitHub only
issues a token with that subject after the environment's protection rules are
satisfied, so those rules are enforced by STS rather than by convention.

## Verification

`make ci` runs what CI runs. Everything in this repository currently passes:

| Check | Status |
| --- | --- |
| `terraform validate` | 15 stacks and modules |
| `terraform fmt -recursive` | clean |
| `tfsec` | 0 findings, 7 justified ignores |
| `checkov` | 0 failures, 56 justified skips across 25 rules |
| `ansible-lint` | 0 failures, 56 `var-naming` warnings left visible |
| `yamllint` | 0 errors |
| Secret scan | 0 findings |
| YAML parse | every Ansible, Kubernetes and workflow file |

Every Checkov skip and tfsec ignore carries its reason on the line above it.
Most are resolution failures rather than gaps — Checkov does not follow a
`count`-indexed reference, so a public access block or lifecycle rule attached
that way reads as absent. The rest are documented accepted risks: single
region, and an access log bucket that cannot log to itself.

The bootstrap playbook ends with a validation role that asserts enough nodes are
`Ready`, that they span at least two zones, that there is **exactly one** default
StorageClass, that each required controller has a ready replica, that every Argo
CD Application is `Synced` and `Healthy`, and that NetworkPolicy enforcement is
live if any policy exists.

## Documentation

| Document | For |
| --- | --- |
| [architecture.md](docs/architecture.md) | How it fits together, and what is a singleton |
| [bootstrap.md](docs/bootstrap.md) | Standing it up from an empty account |
| [eks-cluster.md](docs/eks-cluster.md) | Every EKS design decision and why |
| [gitops.md](docs/gitops.md) | Argo CD applications, values layering, sync policy |
| [observability.md](docs/observability.md) | The two monitoring layers, and what is missing |
| [security.md](docs/security.md) | Controls, enforcement, and the honest gap list |
| [cost-optimization.md](docs/cost-optimization.md) | Where the money goes and the levers that matter |
| [operations.md](docs/operations.md) | Day two: alarms, drift, failures, rotation, upgrades |
| [disaster-recovery.md](docs/disaster-recovery.md) | RPO, RTO, and the procedures behind them |
| [adr/](docs/adr/) | The five decisions worth not re-litigating |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How a change reaches production |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability |

## Roadmap

Completed:

- [x] Remote state with KMS, versioning, access logging and TLS-only policy
- [x] Keyless GitHub Actions OIDC roles, per environment, with an audit guardrail and a permissions boundary
- [x] 3-AZ VPC, flow logs, S3 gateway and 7 interface endpoints
- [x] EKS with Secret envelope encryption and managed control plane log retention
- [x] Access entries instead of `aws-auth`; creator admin revoked outside dev
- [x] Managed node groups with IMDSv2, hop limit 2, encrypted gp3 roots
- [x] IRSA per controller, with the `:aud` claim asserted
- [x] VPC CNI network policy enforcement and prefix delegation
- [x] gp3 default, gp3-retain and gp3-backup StorageClasses
- [x] ECR with immutable tags, scanning and lifecycle policies
- [x] Argo CD with prune, self-heal, finalizers and per-environment values
- [x] kube-prometheus-stack tuned for a managed control plane
- [x] CloudWatch alarms, audit-log detections, composite alarm, dashboard
- [x] CloudTrail, Config, GuardDuty, Security Hub, Access Analyzer
- [x] Budgets, forecast alerts and cost anomaly detection
- [x] AWS Backup with tag selection and Vault Lock
- [x] Three environments with a real promotion path
- [x] Drift detection that opens and closes its own issues
- [x] Post-bootstrap validation that fails rather than reporting success

Open, with the reasoning recorded rather than left implicit:

- [ ] Multi-account landing zone — [ADR 0004](docs/adr/0004-single-account-multiple-environments.md)
- [ ] Karpenter instead of the cluster autoscaler — [ADR 0003](docs/adr/0003-cluster-autoscaler-over-karpenter.md)
- [ ] Second region for backup copies and state replication — both modules accept it, neither is wired
- [ ] Velero, for Kubernetes object backup rather than only volumes
- [ ] Image signing and an admission policy controller
- [ ] SLOs and error budgets, rather than alarms on symptoms
- [ ] Log aggregation and tracing
- [ ] An OIDC proxy in front of Grafana and Argo CD

## License

See [LICENSE](LICENSE).
