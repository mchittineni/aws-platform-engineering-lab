## What this changes

<!-- One or two sentences. What is different after this merges. -->

## Why

<!-- The problem, not the solution. Link the issue or the incident. -->

## Blast radius

- [ ] Environments affected: dev / staging / production
- [ ] This change can be reverted by reverting this commit
- [ ] This change is **not** revertible — say what the recovery path is:

## Verification

- [ ] `make validate` passes locally
- [ ] The plan on this pull request was read, and it matches the intent
- [ ] Applied to dev, then staging, before production
- [ ] `make ansible-check` or the validation play was run against the target

## Security

- [ ] No credential, ARN with a real account ID, or hostname was committed
- [ ] Any new IAM permission is scoped to a resource, not `*`
- [ ] Any new public exposure is deliberate and documented

## Notes for the reviewer

<!-- The part of the diff that is not obvious. Where you were unsure. -->
