# Architecture Decision Records

One file per decision that was hard to reverse, surprising without context, or a
real trade-off. Not a record of every choice — a record of the ones somebody
will otherwise re-litigate in six months.

Format: context, decision, consequences. Consequences includes what this makes
worse, because a decision with no downside was not a decision.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-terraform-ansible-argocd-split.md) | Three tools with hard boundaries | Accepted |
| [0002](0002-private-api-endpoint-by-default.md) | Private EKS API endpoint by default | Accepted |
| [0003](0003-cluster-autoscaler-over-karpenter.md) | Cluster autoscaler, not Karpenter | Accepted |
| [0004](0004-single-account-multiple-environments.md) | One AWS account, three environments | Accepted, with a known gap |
| [0005](0005-oidc-only-no-static-credentials.md) | No long-lived AWS credentials anywhere | Accepted |
