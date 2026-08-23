# ADR 0004 — One AWS account, three environments

**Status:** Accepted, with a known gap

## Context

The reference architecture for this is a multi-account landing zone: AWS
Organizations, one account per environment, a delegated security account
aggregating GuardDuty and Security Hub, and service control policies enforcing
guardrails at the organisational level.

That is unambiguously the correct answer for production at scale. It is also a
large amount of scaffolding — Control Tower or a hand-built Organizations
setup, cross-account role chains, per-account bootstrapping — before the first
cluster exists.

## Decision

One AWS account. Three environments separated by:

- **VPCs** with non-overlapping CIDRs (`10.20`, `10.25`, `10.30`)
- **IAM**: a separate plan and apply role per environment, each with an OIDC
  trust policy scoped to that environment's GitHub environment
- **Tags**: `Environment` on every resource through `default_tags`, which is
  what per-environment budgets and cost attribution key on
- **State**: separate keys in one bucket

## Consequences

**Worse, and this is the gap.** The isolation between production and dev is IAM
policy, not an account boundary. A sufficiently broad IAM mistake — and the CI
apply roles hold `PowerUserAccess` — can reach across environments. There is no
service control policy backstop, because SCPs need Organizations. Per-account
service quotas are shared, so a runaway dev autoscaler can exhaust a quota
production needs.

**Better.** One bootstrap, one CloudTrail, one GuardDuty detector, one Config
recorder, one Security Hub — instead of five of each plus the aggregation to
make them useful. Cross-environment work (reading a staging output while
planning production) needs no role chaining. The whole platform is
comprehensible.

**Mitigations in place.** The guardrail deny policy on every CI role prevents
the pipeline from disabling the audit trail or deleting audit records. Per
environment budgets make a runaway environment visible. Access entries mean the
production cluster does not trust the dev apply role.

## When to revisit

Before anything with a real compliance obligation runs here, or before more than
a handful of people have apply access. The migration is genuinely painful —
resources cannot be moved between accounts, so it is a rebuild — which is an
argument for doing it earlier than feels necessary.
