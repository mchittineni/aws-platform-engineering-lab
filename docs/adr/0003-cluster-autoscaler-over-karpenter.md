# ADR 0003 — Cluster autoscaler, not Karpenter

**Status:** Accepted

## Context

Karpenter is the direction AWS is pushing for EKS node autoscaling, and it is
genuinely better at what it does: it provisions right-sized nodes directly from
pending pod requirements rather than scaling predefined groups, consolidates
underutilised nodes, and handles spot interruption natively.

The cluster autoscaler works by adjusting the desired size of managed node
groups. It can only scale shapes that already exist, and it bin-packs into them
rather than choosing them.

## Decision

Use the cluster autoscaler with managed node groups. Karpenter is a known,
deliberate deferral rather than an oversight.

## Rationale

Karpenter replaces managed node groups with `NodePool` and `EC2NodeClass`
custom resources. That means:

- node lifecycle moves out of Terraform and into Kubernetes objects, which
  changes what a `terraform plan` can tell you about the compute in an
  environment
- an SQS interruption queue, EventBridge rules and a separate node IAM role and
  instance profile, none of which the managed node group needed
- upgrades become Karpenter's `drift` behaviour rather than the managed node
  group's rolling update, which is a different operational model to learn

Each of those is fine. Together they are a substantial change to how the
compute layer is owned, and adopting it at the same time as everything else in
this repository would mean two unfamiliar things failing at once.

Managed node groups also give something Karpenter does not: AWS owns the AMI
selection, the bootstrap and the rolling upgrade. For a platform whose point is
that the infrastructure layer is boring, that is worth keeping while the rest
settles.

## Consequences

**Worse.** Scaling is coarser. Adding a new instance shape means a Terraform
change rather than a `NodePool` edit. Nodes are less well packed, so the compute
bill is higher than it needs to be. Spot interruption is handled by the node
group's own draining rather than by a controller watching the interruption
queue, which gives less notice.

**Better.** The compute layer is fully described by Terraform state, node
upgrades are AWS's problem, and there is one fewer controller whose failure mode
has to be understood.

## When to revisit

When the compute bill is large enough that bin-packing efficiency matters, or
when a workload needs an instance shape that does not fit the existing pools.
Migration is incremental: Karpenter can run alongside a managed node group, and
the platform pool can stay while workloads move.
