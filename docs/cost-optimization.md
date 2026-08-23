# Cost Optimisation

An EKS lab is easy to leave running by accident. This is where the money goes
and what this repository does about it.

## Baseline

Approximate monthly figures for the `dev` environment in `eu-central-1`,
running continuously. Treat them as order of magnitude, not a quote.

| Component | Configuration | Approximate monthly |
| --- | --- | --- |
| EKS control plane | one cluster | 73 USD |
| Platform nodes | 2 × `m6i.large` on demand | 140 USD |
| Spot node | 1 × `m6i.large` spot | 20 USD |
| NAT gateway | 1 shared | 35 USD + data |
| EBS | 3 × 50 GB gp3 root, 70 GB monitoring | 20 USD |
| Interface VPC endpoints | 7 endpoints × 3 AZ | 150 USD |
| ALB | 1 shared | 20 USD + LCU |
| CloudWatch logs | control plane + flow logs | 10 to 30 USD |
| **Environment subtotal** | | **roughly 470 to 500 USD** |

Account level, charged once regardless of how many environments exist:

| Component | Notes | Approximate monthly |
| --- | --- | --- |
| CloudTrail | First management event trail is free; the S3 storage is not | 1 to 5 USD |
| AWS Config | Charged per configuration item recorded, and EKS churns them | 5 to 25 USD |
| GuardDuty | Per event and per GB of analysed logs | 5 to 20 USD |
| Security Hub | Per check and per finding ingested | 5 to 15 USD |
| S3 audit bucket | Tiers to Glacier IR after 90 days | 1 to 5 USD |
| KMS | 1 USD per key per month, plus requests | 10 to 15 USD |
| Budgets, anomaly detection, SNS | Effectively free at this scale | under 1 USD |
| **Account subtotal** | | **roughly 30 to 85 USD** |

The two surprises in the environment table are the interface endpoints and the
control plane, neither of which scales down with usage. In the account table it
is AWS Config: a cluster that autoscales generates configuration items
continuously, and Config bills per item.

## The levers that actually matter

### 1. Interface VPC endpoints are the biggest fixed line

Seven endpoints across three availability zones is 21 ENIs at about 7 USD each.
That is more than the nodes.

They exist so that ECR pulls, STS calls and SSM traffic do not cross the NAT
gateway. In a lab with light image pull volume the NAT data charge is far lower
than the endpoint charge.

```hcl
module "vpc" {
  # Keep only the gateway endpoint, which is free
  interface_endpoints = []
}
```

Keep them in production, where NAT data processing on image pulls does exceed
the endpoint cost, and where keeping ECR traffic off the public path is a
security requirement rather than an optimisation.

### 2. Stop paying for an idle cluster

A lab does not need to run overnight. Scaling the node groups to zero keeps the
cluster and all its configuration, and drops the compute line to nothing:

```bash
aws eks update-nodegroup-config \
  --cluster-name aws-platform-dev \
  --nodegroup-name platform \
  --scaling-config minSize=0,maxSize=4,desiredSize=0
```

The control plane still bills at 73 USD per month. `terraform destroy` is the
only way to stop that, which is why the environment is built to be
reproducible in about 20 minutes.

### 3. One NAT gateway, or none

`single_nat_gateway = true` in dev saves about 70 USD per month over one per
zone. It makes one availability zone a single point of failure for egress,
which is acceptable in a lab and not in production.

### 4. Spot for anything interruptible

The dev spot pool is roughly 70% cheaper than on demand. `min_size = 0` means
it costs nothing when empty. The taint keeps workloads off it unless they
tolerate interruption.

### 5. gp3 everywhere, never gp2

gp3 is about 20% cheaper per GB than gp2 and decouples IOPS from capacity. The
`eks_storage` Ansible role removes the default annotation from the `gp2`
StorageClass EKS ships with, so a PVC that names no class lands on gp3 rather
than silently provisioning gp2.

### 6. One ALB, not one per Ingress

Every Ingress without a group annotation creates its own ALB at roughly 20 USD
per month. The `alb.ingress.kubernetes.io/group.name` annotation puts them all
behind one. This is the single easiest way to make an EKS bill grow without
noticing.

### 7. Container logs are optional, and they are the expensive half

`enable_cloudwatch_observability` installs the CloudWatch agent, which is what
makes the node level alarms in `modules/observability` more than
`INSUFFICIENT_DATA`. It has two independent switches, and they cost very
different amounts:

- `enable_enhanced_container_insights` — more granular metrics, charged per
  metric. Moderate.
- `enable_container_logs` — every container's stdout and stderr shipped to
  CloudWatch Logs, charged per GB ingested. This is usually the largest single
  line on an observability bill, and it duplicates what Prometheus and the
  in-cluster stack already hold.

Both default to off. Turn on Container Insights metrics; think hard before
turning on container logs.

### 8. Log retention

Control plane audit logs are the highest volume log source in the cluster. Dev
retains 30 days, production 365. Retention is set on the log group by Terraform
before the cluster is created, because a log group created by EKS never
expires.

## Cost visibility

Every resource carries `Environment`, `Project`, `ManagedBy` and `Owner`
through the provider's `default_tags`. Activate those as cost allocation tags in
the Billing console — this is a manual step in the console and nothing works
without it — then Cost Explorer can answer "what does dev cost" without
guesswork.

`modules/cost-controls`, applied by the bootstrap stack, turns that tagging into
alerts rather than a report somebody remembers to open:

- An account budget with alerts at 50%, 80% and 100% of actual spend, plus one
  on the **month end forecast**. The forecast alert is the only one that arrives
  early enough to act on.
- A per environment budget filtered on the `Environment` tag, so a dev cluster
  left running over a weekend shows up on its own line.
- Cost Anomaly Detection per service, which catches the step change — somebody
  enabling continuous scanning on a 400 image registry — that a monthly budget
  only reveals three weeks later.

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-08-01,End=2026-08-31 \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=TAG,Key=Environment
```

## Checklist before leaving an environment running

- [ ] Node groups scaled to zero, or the environment destroyed
- [ ] No orphaned load balancers (`aws elbv2 describe-load-balancers`)
- [ ] No orphaned EBS volumes in `available` state
- [ ] No unattached Elastic IPs
- [ ] The budget and anomaly detection SNS subscriptions are **confirmed**; an
      unconfirmed subscription means the alerts go nowhere
