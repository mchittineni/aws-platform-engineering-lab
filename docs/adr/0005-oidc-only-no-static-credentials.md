# ADR 0005 — No long-lived AWS credentials anywhere

**Status:** Accepted

## Context

The default way to give CI access to AWS is an access key in a repository
secret. The default way to give a pod access to AWS is an access key in a
Kubernetes Secret, or a node role broad enough to cover every pod on the node.

Both work immediately and both are the single most common source of cloud
credential compromise: a key in a secret store is a key that can be exfiltrated,
is rarely rotated, and leaves no trace of which workload used it.

## Decision

No long-lived AWS credential exists in this repository, in any GitHub secret, or
in any Kubernetes Secret.

| Consumer | Credential | Lifetime |
| --- | --- | --- |
| GitHub Actions | OIDC web identity, subject-scoped | Minutes |
| Pods | IRSA, projected ServiceAccount token | Hours |
| Nodes | Instance profile, IMDSv2 with hop limit 2 | Rotated by AWS |
| Operators | SSO or assumed role | Session |

Enforced, not just intended:

- `modules/github-oidc` rejects any subject ending in `:*` through variable
  validation, because `repo:org/repo:*` lets any branch in any fork assume the
  role.
- Apply roles trust only `repo:<org>/<repo>:environment:aws-<env>`, so a token
  with that subject only exists after GitHub's environment protection rules have
  been satisfied.
- `modules/irsa` asserts the `:aud` claim as well as `:sub`. Checking only `sub`
  is a common mistake — without the audience condition, any web identity token
  from the provider satisfies the policy.
- Node groups have no key pair and no inbound port 22. IMDSv2 is required with a
  hop limit of 2, so a pod on the host network cannot read the node's instance
  profile.
- One IRSA role per controller, never a shared platform role. A compromised
  external-dns pod cannot delete load balancers.

## Consequences

**Better.** There is nothing to rotate and nothing to leak. Every AWS API call
from CI is attributable to a workflow run through the role session name. A
compromised pod's blast radius is one controller's policy.

**Worse.** Local development needs SSO or an assumed role — `aws configure` with
a key does not fit the model. An apply cannot be run from a laptop against
staging or production at all, because the apply role's trust policy has no path
that a laptop can satisfy. During an incident, that is felt.

That last point is the intended trade: the emergency path is to run the workflow,
not to bypass it. If the workflow itself is broken, the recovery path is an
administrator assuming a break-glass role, which is an auditable event rather
than a normal one.
