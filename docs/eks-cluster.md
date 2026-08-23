# EKS Cluster Design

Design decisions in `modules/eks`, and why each one is there.

## Control plane

The control plane is managed. There is nothing to bootstrap, but four settings
decide whether it is auditable and recoverable.

### Secret envelope encryption

`encryption_config` points at a customer managed KMS key. Without it, etcd
Secret material is encrypted with an AWS owned key that cannot be audited or
revoked. With it, every Secret read is a CloudTrail entry against a key the
account controls.

The key uses a 30 day deletion window and rotation. Deleting it makes every
Secret in the cluster permanently unreadable, so the window is the safety net.

### Control plane logging

All five log types are enabled: `api`, `audit`, `authenticator`,
`controllerManager`, `scheduler`. The `audit` log is the only record of who did
what through the Kubernetes API.

The log group is created by Terraform *before* the cluster. If EKS creates it,
it defaults to never expiring and to the AWS owned key. Creating it first fixes
both retention and encryption.

### Endpoint exposure

The module default is `endpoint_public_access = false`. A cluster that only
answers inside the VPC is the safe starting point; an environment opts in
explicitly. `public_access_cidrs` rejects `0.0.0.0/0` through a variable
validation rather than a code review comment.

`dev` enables the public endpoint only when an allow list is supplied, so an
empty variable can never mean "open to the internet".

### Access management

`authentication_mode = "API"` uses EKS access entries instead of the
`aws-auth` ConfigMap. A malformed `aws-auth` edit can lock every principal out
of a cluster with no recovery path other than AWS support; access entries are
an API with validation.

`production` sets `bootstrap_cluster_creator_admin_permissions = false`, so
whoever ran the first apply does not silently keep admin forever. Access comes
only from the declared `access_entries`.

## Node groups

### Launch templates

Managed node groups work without a launch template, but then:

- IMDSv2 is optional
- the root volume is unencrypted gp2
- there is no way to force metadata hardening

The module creates one launch template per node group with:

| Setting | Value | Reason |
| --- | --- | --- |
| `http_tokens` | `required` | IMDSv2 only, which defeats SSRF based credential theft |
| `http_put_response_hop_limit` | `2` | A pod on the host network cannot reach the node credentials |
| `encrypted` | `true` | Root volumes are encrypted at rest |
| `volume_type` | `gp3` | Cheaper than gp2 at every size, with independent IOPS |
| `monitoring` | `enabled` | One minute CloudWatch metrics instead of five |

The AMI is still chosen by EKS through `ami_type`, so AWS keeps owning patching
and the rolling upgrade.

### desired_size drift

`scaling_config[0].desired_size` is in `ignore_changes`. Terraform sets the
initial size; after that the cluster autoscaler owns it. Without the ignore,
every plan wants to undo the last scaling event.

### Spot capacity

`dev` runs a spot pool with `min_size = 0` and a `NO_SCHEDULE` taint, so
nothing lands there unless it declares a toleration. Several instance types are
listed because a spot pool with one type is a pool that runs out.

`production` has no spot pool. Spot is right for batch and CI, not for the
platform controllers everything else depends on.

## IRSA

The cluster creates an IAM OIDC provider from its own issuer URL. That is what
lets a ServiceAccount exchange a projected token for IAM credentials, with no
static keys on the node and no node role over-grant.

Each controller gets its own role with its own policy —
`modules/eks-platform-iam` creates them. A single shared platform role
would mean a compromised external-dns pod could also delete load balancers.

Trust policies check both claims:

```text
<issuer>:sub  = system:serviceaccount:<namespace>/<name>
<issuer>:aud  = sts.amazonaws.com
```

Checking only `sub` and omitting `aud` is a common mistake: without the
audience condition any web identity token issued by the provider satisfies the
policy.

`modules/irsa` is the generic factory. It switches from `StringEquals` to
`StringLike` automatically when a subject contains a wildcard.

## Add-ons

| Add-on | Managed by | Notes |
| --- | --- | --- |
| `vpc-cni` | Terraform | Own IRSA role, network policy enforcement, prefix delegation |
| `kube-proxy` | Terraform | No IAM needed |
| `coredns` | Terraform | Waits for node groups; it cannot schedule on an empty cluster |
| `aws-ebs-csi-driver` | Terraform | Own IRSA role plus a KMS grant |
| `eks-pod-identity-agent` | Terraform | Enables Pod Identity as an alternative to IRSA |
| `amazon-cloudwatch-observability` | Terraform | Optional. Own IRSA role. Required for the node level CloudWatch alarms to have data |
| AWS Load Balancer Controller | Ansible | Not an EKS add-on; installed by Helm |
| `metrics-server` | Ansible | EKS does not ship it, and HPA needs it |
| cluster autoscaler | Ansible | Needs the IRSA role from Terraform |
| External Secrets, external-dns, cert-manager | Ansible | Optional per environment, each with its own IRSA role |

`resolve_conflicts_on_update = "PRESERVE"` keeps any field a human or Argo CD
changed on the add-on, instead of reverting it on the next apply.

### Two vpc-cni settings that are easy to get wrong

**`enableNetworkPolicy`.** Off by default in the add-on. With it off, the API
server accepts every `NetworkPolicy` object and enforces none of them. That is
worse than having no policies, because the objects exist and the cluster looks
segmented. The module turns it on, and `eks_validate` fails the run if policy
objects exist without the enforcing agent present in the `aws-node` DaemonSet.

**`ENABLE_PREFIX_DELEGATION`.** The VPC CNI gives each pod a real VPC address
from the node's ENIs, so the pods-per-node ceiling is a function of the instance
type, not of a CIDR you chose. An `m6i.large` tops out around 29 pods without
prefix delegation and around 110 with it. The trade is that each node reserves
/28 prefixes rather than individual addresses, so the VPC consumes addresses
faster. The subnets here are /20, which leaves room for that.

Neither can be changed without the add-on restarting `aws-node` on every node,
so decide before the cluster carries traffic.

## Upgrades

1. Bump `kubernetes_version` and apply. The control plane upgrades first; it
   stays available throughout.
2. Node groups follow. `max_unavailable_percentage` decides the blast radius —
   33% in dev, 25% in production.
3. Every workload needs a PodDisruptionBudget, or the drain either stalls or
   takes all replicas down at once.
4. Bump the add-on versions in `addon_versions` after the control plane, not
   before. An add-on newer than the control plane is unsupported.

`upgrade_policy_support_type = "STANDARD"` means the cluster is not silently
moved to extended support — and billed for it — when the version reaches end of
standard support. It will refuse the version instead, which is the signal to
upgrade.
