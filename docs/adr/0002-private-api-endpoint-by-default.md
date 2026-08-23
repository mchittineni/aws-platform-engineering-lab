# ADR 0002 — Private EKS API endpoint by default

**Status:** Accepted

## Context

EKS exposes the Kubernetes API publicly by default. The endpoint requires IAM
authentication, so a public endpoint is not an open door — but it does mean the
control plane of every cluster is reachable from the entire internet, and that
any authentication bypass in the API server or a mis-scoped access entry becomes
immediately exploitable from anywhere.

The counter-argument is real: a private endpoint means `kubectl` does not work
from a laptop without a VPN, a peering connection, or an SSM port forward. That
friction is felt every day, by everyone.

## Decision

`endpoint_public_access` defaults to `false` in `modules/eks`.

`public_access_cidrs` rejects `0.0.0.0/0` through variable validation, so
enabling the public endpoint requires naming actual CIDRs.

Per environment:

- **dev** may opt in, and only for a supplied allow list. An empty variable can
  never mean "open to the internet".
- **staging** and **production** are private, with no opt-in.

Staging being private is the deliberate part. If staging is reachable from a
laptop and production is not, staging never exercises the access path production
uses, and the first time anybody discovers that is during a production incident.

## Consequences

**Better.** Two `CRITICAL` tfsec findings do not exist. The blast radius of a
leaked kubeconfig is bounded by network reach as well as by IAM.

**Worse.** Operating staging and production requires an SSM port forward, which
is documented in the bootstrap runbook and is genuinely more annoying than
`kubectl get pods`. Running the Ansible playbook against production requires
network reach into the VPC.

**Reversing this** re-opens the two tfsec findings, which is the intended
friction: it should be a decision with a visible cost, not a default somebody
flips.
