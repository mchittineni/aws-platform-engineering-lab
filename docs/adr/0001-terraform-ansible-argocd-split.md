# ADR 0001 — Three tools with hard boundaries

**Status:** Accepted

## Context

The platform needs infrastructure provisioned, a handful of controllers
installed into a cluster that does not exist until provisioning finishes, and
then ongoing delivery of workloads.

Any one of the three tools could technically do more than its share. Terraform
has a Helm provider and a Kubernetes provider. Ansible can call the AWS API.
Argo CD can be given a Terraform controller. Each of those options collapses the
stack into fewer tools, which is superficially attractive.

## Decision

Three tools, with the boundary defined by *which API is being called*:

| Tool | Owns | Stops at |
| --- | --- | --- |
| Terraform | The AWS API | The Kubernetes API |
| Ansible | The Kubernetes API, until Argo CD is running | Argo CD being healthy |
| Argo CD | The Kubernetes API, from then on | — |

Specifically rejected: managing Helm releases from Terraform, and managing AWS
resources from Ansible.

## Consequences

**Better.** Terraform state never contains Kubernetes objects, so a cluster
rebuild does not require surgery on state. The dependency graph is honest: you
cannot plan a Helm release against a cluster that does not exist yet, and the
Terraform Helm provider papers over that with `depends_on` and a provider
configured from an unknown value — which fails on the first apply of a new
environment and works forever after, making it a trap for exactly the person
least equipped to debug it.

**Worse.** Three tools means three sets of credentials, three linters, three
things to learn. The handoff between Terraform outputs and Ansible variables is
manual: ARNs are exported into the environment by hand, which is documented in
the bootstrap runbook and is the least elegant part of this repository.

**Accepted cost.** The Ansible layer is small — six roles — and shrinks as more
of it moves into Argo CD. It will not reach zero: something has to install Argo
CD, and that something cannot be Argo CD.
