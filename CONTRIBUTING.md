# Contributing

## The shape of a change

Every change to AWS follows the same path, and the path is not negotiable
because it is what the CI roles are scoped to:

```text
branch → pull request → plan on the PR → review the plan → merge
       → apply to dev → apply to staging → apply to production
```

Nothing is applied from a laptop against staging or production. The apply role
can only be assumed by a workflow run inside the protected GitHub environment
of the same name, so an apply from anywhere else fails at the STS call rather
than half way through.

## Before you open a pull request

```bash
make deps        # once
make validate    # fmt + terraform validate on every stack and module
make security    # tfsec + Checkov
make lint        # tflint
make kube-validate
make ansible-lint
```

`make ci` runs all of it. If `make ci` is green and CI is red, that is a bug in
the Makefile — say so in the pull request.

## Where a change belongs

| You are changing | Put it in |
| --- | --- |
| Something two environments both need | `modules/` |
| How one environment differs | `environments/<env>/main.tf` |
| Something singular per AWS account | `environments/bootstrap` |
| A cluster-wide Kubernetes object | `kubernetes/platform/` |
| A workload | `kubernetes/apps/<name>/` |
| How a controller is installed | `ansible/roles/` |
| Which controllers an environment runs | `ansible/inventory/<env>/group_vars/all.yml` |

A variable that exists in only one environment is a smell: it usually means the
module should have taken a parameter instead.

## Rules that are enforced, not suggested

- **Every variable has a description.** tflint fails the build without one.
- **Every module is `terraform fmt` clean.** So is every environment.
- **tfsec and Checkov must pass with zero findings.** An accepted finding gets
  a `#tfsec:ignore` or `#checkov:skip=CKV_ID:reason` comment *with the reason on
  the line above it*. An ignore without a justification will be asked about in
  review. Run `make security` before pushing — both tools exit non-zero on a
  finding, so a new one turns CI red.
- **ansible-lint must exit zero.** `.ansible-lint` scopes it to Ansible content
  and keeps `var-naming[no-role-prefix]` in `warn_list`, so those 56 findings
  stay visible without failing the build. Do not add to that list to make a new
  finding go away.
- **No wildcard OIDC subject.** `modules/github-oidc` validates subjects against
  an allowlist of the three shapes GitHub issues (`:pull_request`,
  `:environment:NAME`, `:ref:refs/heads/BRANCH`) and rejects any subject
  containing `*`. Denying one bad suffix is not enough: `endswith(subject, ":*")`
  catches `repo:org/repo:*` but admits `repo:org/*`, `refs/heads/*` and a bare
  `*`, each of which is broader than the subject it was meant to block.
- **Every IAM role CI creates carries the permissions boundary.** Any module
  that creates an `aws_iam_role` takes a `permissions_boundary_arn` and passes it
  through, and every environment supplies it from the bootstrap output
  `ci_permissions_boundary_arn`. The apply role is denied `iam:CreateRole`
  without it, so a module that forgets fails at apply rather than silently
  creating an unconstrained role. If you add a role-creating module, wire this
  first.
- **A plan role never gets a write permission.** Plan roles get `s3:GetObject`
  and `kms:Decrypt` on their own `aws/<env>/*` state prefix. `s3:PutObject` and
  `s3:DeleteObject` belong to the apply role. Both plan workflows run
  `terraform plan -lock=false`, so there is nothing a plan needs to write.
- **No `0.0.0.0/0` on the Kubernetes API.** Rejected by variable validation.
- **Chart versions are pinned.** A floating chart version means the next run of
  the playbook upgrades a controller without anybody deciding to.
- **Action versions are pinned to a SHA**, with the tag in a trailing comment.

## Writing Terraform here

- One resource type per file when a module grows past about 150 lines
  (`main.tf`, `iam.tf`, `kms.tf`, `addons.tf` in `modules/eks`).
- Comments explain *why*, not *what*. `# Create a KMS key` is noise;
  `# Without this, Secrets are only encrypted with the EKS managed key` is the
  reason the resource exists.
- Prefer variable `validation` over a note in the README. A rule the tool
  enforces survives; a rule in prose does not.
- `optional()` with a default in an object type, rather than a second variable.
- Outputs are the interface. If an environment reaches into a module's
  internals, add an output.

## Writing Ansible here

- Roles are idempotent, and that is tested by running them twice.
- Assert preconditions at the top of a role. Failing before the first Helm
  release beats debugging a `CrashLoopBackOff`.
- `changed_when` on every `command` task. A task that always reports changed
  makes `--check` useless.
- No `json_query`. It needs `jmespath` on the control host, and a validation
  step that fails on a missing Python package teaches people to skip
  validation.

## Commit messages

Conventional commits, because the scope is what tells a reviewer whether they
need to care:

```text
feat(eks): add the CloudWatch observability add-on
fix(vpc): expose NAT gateway IDs for the port allocation alarm
docs(security): record the accepted tfsec ignores
refactor(ansible): move controller versions into group_vars
ci(drift): close the drift issue when the plan comes back clean
```

## Reviewing a pull request

Read the plan, not only the diff. The diff says what the author intended; the
plan says what AWS is about to do. The two differ more often than anybody
expects, particularly around anything with `for_each`.

Ask specifically:

- Does any resource get **replaced** rather than updated? A replaced node group
  or KMS key is an outage or a data loss, and it looks identical to an update
  in the diff.
- Is a new IAM permission scoped to a resource ARN?
- If it creates an IAM role, does it accept and pass `permissions_boundary_arn`?
- Does a plan-time credential gain any permission that mutates something?
- Does this widen public exposure anywhere?
- Is there a rollback, and does the author know what it is?

## Security-relevant changes

If a change touches IAM, an OIDC trust policy, a bucket policy, a security
group, or the state backend, say so in the pull request and name the control it
affects. Two specific claims in [docs/security.md](docs/security.md) depend on
mechanisms that are easy to weaken without noticing:

- the audit deny policy only holds because the permissions boundary makes it
  transitive
- the plan role is only read-only because the write actions live in a separate
  policy document

A change that breaks either one will still plan cleanly and still pass tfsec.
Reviewers should check both by reading the policy documents in
`environments/bootstrap/main.tf`, not by trusting the diff summary.

Do not report a vulnerability in a pull request or a public issue. Use the
private route in [SECURITY.md](SECURITY.md).
