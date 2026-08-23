# Security

## Reporting a vulnerability

Do not open a public issue for a security problem in this repository.

Report it privately through GitHub's private vulnerability reporting on the
Security tab, or by email to the address in the repository description.
Expect an acknowledgement within three working days.

Include, if you can: what an attacker can do, which file or resource is
involved, and whether it affects a deployed environment or only the code.

## What this repository is

Infrastructure as code for an AWS platform. There is no running service to
attack here, so the interesting failures are different from an application
repository:

- a Terraform module that grants more IAM permission than it needs
- a CI workflow that can be triggered by an untrusted fork
- a default that exposes something publicly
- a secret committed by mistake

All four are in scope.

## What is deliberately not here

**No long lived AWS credentials.** There is no access key in this repository,
in any GitHub secret, or in any Kubernetes Secret. CI authenticates through the
GitHub OIDC provider; pods authenticate through IRSA. If you find a static
credential, that is a finding — report it.

**No SSH.** The node groups have no key pair and no inbound port 22. Access to
an instance is through Session Manager, which is authenticated by IAM and
recorded in CloudTrail.

## Controls that are enforced rather than documented

- Every KMS key is customer managed with rotation enabled.
- Terraform state is encrypted, versioned, access logged, and its bucket
  policy refuses non-TLS and unencrypted writes.
- CloudTrail records every management event, and the CI apply role is denied
  the permissions that would let it stop or delete the trail.
- The audit bucket denies object deletion to every principal except the ones
  explicitly listed.
- The EKS API endpoint defaults to private, and `0.0.0.0/0` is rejected by
  variable validation rather than by review.
- Secrets in etcd are envelope encrypted with a key this repository owns.
- Nodes require IMDSv2 with a hop limit of 2, so a compromised pod cannot read
  the node's instance profile.
- AWS Config rules assert the above continuously, and drift opens an issue.

The full model, including the gaps that are known and accepted, is in
[docs/security.md](docs/security.md). Read the gaps section before treating any
of this as production hardened for your own threat model.

## Supported versions

Only `main` is supported. There are no released versions and no backports.
