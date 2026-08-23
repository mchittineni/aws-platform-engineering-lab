# Platform Architecture

An AWS-only Kubernetes platform: EKS across three availability zones, GitOps
delivery, observability inside and outside the cluster, and an account security
baseline that is enforced rather than documented.

Three tools, three clearly separated jobs:

| Tool | Owns | Boundary |
| --- | --- | --- |
| Terraform | Everything reachable through the AWS API | Stops at the Kubernetes API |
| Ansible | The bootstrap steps that need the Kubernetes API | Stops once Argo CD is running |
| Argo CD | Everything in the cluster after that | Reconciles from Git, not from a laptop |

The boundary matters more than the tools. Anything Terraform can own, Terraform
owns, because state and a plan are better than an idempotent script. Ansible
exists for the handful of steps that need a Kubernetes API that does not exist
until Terraform has finished. After Argo CD is up, neither of them is how the
cluster changes.

## Topology

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

   VPC endpoints (private subnets): s3 (gateway),
   ecr.api, ecr.dkr, sts, logs, ssm, ssmmessages, ec2messages
```

Three availability zones, because two is the minimum EKS accepts and three is
the minimum that survives losing one without losing quorum on anything that
uses a quorum.

The interface endpoints are not decoration. Without them, every image pull,
every log write and every `AssumeRoleWithWebIdentity` call leaves through the
NAT gateway and is billed per gigabyte. They are also the largest fixed line in
the bill — see [cost-optimization.md](cost-optimization.md).

## Stack layout

```text
environments/
├── bootstrap/     # state backend, CI roles, security baseline, budgets
├── dev/           # cheapest posture that still exercises the same code
├── staging/       # production shaped, so production changes are boring
└── production/    # private API, per zone NAT, backup, vault lock

modules/
├── vpc/                 # subnets, NAT, endpoints, flow logs
├── eks/                 # cluster, node groups, add-ons, KMS, OIDC provider
├── eks-platform-iam/    # IRSA roles for the platform controllers
├── irsa/                # generic IRSA role factory
├── ecr/                 # image repositories, scanning, lifecycle
├── tf-state-backend/    # S3 + KMS remote state
├── github-oidc/         # keyless CI credentials
├── security-baseline/   # CloudTrail, Config, GuardDuty, Security Hub
├── observability/       # CloudWatch alarms, audit detections, dashboard
├── cost-controls/       # budgets, cost anomaly detection
└── backup/              # AWS Backup vault, plan, vault lock

ansible/
├── inventory/<env>/     # group_vars per environment, plus aws_ec2 discovery
├── roles/               # eks_kubeconfig, eks_platform, eks_storage,
│                        # argocd, argocd_bootstrap, eks_validate
└── playbooks/site.yml   # the whole bootstrap, tagged per stage

kubernetes/
├── platform/            # namespaces with PSA labels, priority classes
├── apps/nginx/          # a workload, with its quota and network policy
├── monitoring/          # kube-prometheus-stack values, base + per env
└── storage/             # gp3-retain, gp3-backup StorageClasses
```

## What is a singleton, and why bootstrap exists

`environments/bootstrap` holds everything that exists once per AWS account. The
test is simple: **if two environments both tried to create it, the second apply
would fail.**

That covers the Terraform state bucket, the GitHub OIDC provider, the CI roles,
the CloudTrail trail, the AWS Config recorder, the GuardDuty detector, Security
Hub, the account public access block, and the budgets. Putting any of those in
`dev` means `staging` cannot be created.

It also holds the guardrail policy attached to every CI role, which denies the
permissions that would let the pipeline stop the trail, delete the detector, or
empty the audit bucket. An apply role with `PowerUserAccess` that can also
disable the audit trail is an apply role that can hide what it did.

## Provisioning flow

```text
1. environments/bootstrap        terraform apply    (once per AWS account)
       |
       +--> state bucket + KMS, GitHub OIDC provider, CI roles
       +--> CloudTrail, Config, GuardDuty, Security Hub, Access Analyzer
       +--> budgets, cost anomaly detection, alert topics
       |
2. environments/<env>            terraform apply    (dev -> staging -> production)
       |
       +--> VPC, subnets, NAT, endpoints, flow logs
       +--> EKS control plane, node groups, add-ons
       +--> KMS keys, IRSA roles, ECR
       +--> CloudWatch alarms, dashboard, backup plan
       |
3. ansible/playbooks/site.yml    ansible-playbook
       |
       +--> kubeconfig from the AWS API
       +--> ALB controller, metrics-server, autoscaler, external-secrets,
       |    external-dns, cert-manager
       +--> gp3 StorageClass as the cluster default
       +--> Argo CD, then the Argo CD Applications
       +--> validation: nodes, zones, default class, controllers, apps
       |
4. Argo CD
       |
       +--> kubernetes/**    platform objects, workloads, monitoring
```

## Environment differences

Every environment calls the same modules. Only variables differ, so the whole
difference between `dev` and `production` is readable in one file each.

| Setting | dev | staging | production |
| --- | --- | --- | --- |
| VPC CIDR | `10.20.0.0/16` | `10.25.0.0/16` | `10.30.0.0/16` |
| NAT gateways | 1 shared | 1 per zone | 1 per zone |
| API endpoint | private, public opt-in per CIDR | private only | private only |
| Node pools | on demand + spot | on demand + spot | on demand |
| Node count | 2 | 2 | 3 |
| Creator admin access | granted | revoked | revoked |
| Control plane logs | 30 days | 90 days | 365 days |
| Flow logs | 30 days | 90 days | 365 days |
| ECR scanning | scan on push | scan on push | Inspector continuous |
| external-dns, cert-manager | off | on, ACME staging | on |
| Argo CD | single replica | HA | HA |
| Backup | none | 7 day retention | 35 / 365 day, vault lock |
| Prometheus retention | 7 days | 15 days | 30 days |

Two of these are worth calling out because they are choices, not defaults:

**Staging keeps the API endpoint private.** If staging can be reached from a
laptop and production cannot, staging never exercises the access path
production actually uses, and the first time anyone discovers that is during a
production incident.

**Staging runs a backup plan with a seven day retention.** The point is not the
data. It is that the restore procedure in
[disaster-recovery.md](disaster-recovery.md) gets rehearsed somewhere before it
is needed somewhere that matters.

## Observability in two places

Prometheus, Grafana and Alertmanager run inside the cluster, which is exactly
why they cannot be the whole answer: they go down with it.

- **Inside the cluster** — kube-prometheus-stack, deployed by Argo CD. Cluster
  internals, workload metrics, dashboards.
- **Outside the cluster** — `modules/observability`. CloudWatch alarms on the
  EKS control plane, NAT gateway port exhaustion, node health, and four metric
  filters over the control plane audit log. One composite alarm for on-call to
  subscribe to.

The kube-prometheus-stack values disable the etcd, scheduler, controller
manager and kube-proxy scrape jobs, and the four alert rules that depend on
them. On a managed control plane those endpoints do not exist, and a
permanently red target page is a page nobody reads.

## Related documents

- [Bootstrap runbook](bootstrap.md)
- [EKS cluster design](eks-cluster.md)
- [GitOps delivery](gitops.md)
- [Observability](observability.md)
- [Security model, and its gaps](security.md)
- [Cost optimisation](cost-optimization.md)
- [Operations](operations.md)
- [Disaster recovery](disaster-recovery.md)
- [Architecture decision records](adr/)
