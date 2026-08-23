# GitOps Delivery

Argo CD is installed by Ansible and owns everything afterwards. That split is
the whole design: something has to create the thing that creates everything
else, and after that nothing should be applied by hand.

## What owns what

```text
Terraform  ──► AWS API           (VPC, EKS, IAM, KMS, ECR, alarms, backup)
Ansible    ──► Kubernetes API    (controllers, storage class, Argo CD itself)
Argo CD    ──► Kubernetes API    (everything else, reconciled from Git)
```

Once step three is running, a `kubectl apply` against a managed namespace is
reverted within the reconciliation interval, because self-heal is on. That is
the intended behaviour: it means the cluster state and the repository cannot
diverge quietly.

## Applications

Defined per environment in `ansible/inventory/<env>/group_vars/all.yml`, so
which applications an environment runs is one readable list rather than a set of
files that differ subtly.

| Application | Source | Namespace | dev | staging | production |
| --- | --- | --- | --- | --- | --- |
| `platform` | `kubernetes/platform` | `platform` | yes | yes | yes |
| `storage` | `kubernetes/storage` | `kube-system` | yes | yes | yes |
| `demo-nginx` | `kubernetes/apps/nginx` | `demo` | yes | yes | no |
| `monitoring` | kube-prometheus-stack chart | `monitoring` | yes | yes | yes |

Two source shapes are supported by the `argocd_bootstrap` role:

**`type: git`** — plain manifests from a path in this repository.

**`type: helm`** — an upstream chart, with values files read from *this*
repository through a second source declared with `ref: values`. That indirection
is what lets a Helm application keep its values under version control here
instead of in a chart fork.

## Values layering

The monitoring application uses two values files:

```yaml
values_paths:
  - "kubernetes/monitoring/kube-prometheus-stack/values.yaml"
  - "kubernetes/monitoring/kube-prometheus-stack/values-production.yaml"
```

Later files win, exactly like `helm -f a.yaml -f b.yaml`. The base file holds
everything true of every environment; the overlay holds retention, replica
counts, volume sizes, the cluster external label and the ingress. A per
environment difference lives in one place and is diffable.

## Sync policy

Every Application is created with:

```yaml
syncPolicy:
  automated:
    prune: true        # a resource deleted from Git is deleted from the cluster
    selfHeal: true     # a manual kubectl edit is reverted
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
  retry:
    limit: 5
    backoff: { duration: 10s, factor: 2, maxDuration: 5m }
```

`prune: true` and `selfHeal: true` together are what make Git the source of
truth rather than a suggestion. Without prune, deleting a manifest leaves the
resource running forever; without self-heal, a console or `kubectl` change wins
until somebody notices.

`ServerSideApply=true` is not optional for the monitoring application. The
Prometheus Operator CRDs exceed the annotation size limit that client-side apply
depends on, and the failure mode is a confusing `metadata.annotations: Too long`
error rather than anything about CRDs.

The `resources-finalizer.argocd.argoproj.io` finalizer is set on every
Application. Without it, deleting an Application leaves every resource it created
running in the cluster — orphaned, unmanaged, and still billing.

## Ordering

Namespace-scoped governance lives in the same directory as the workload it
governs. The `demo` namespace, its `LimitRange`, its `ResourceQuota` and its
`NetworkPolicy` objects are all in `kubernetes/apps/nginx/`, so Argo CD applies
them in one sync wave.

The alternative — putting the quotas in `kubernetes/platform` — creates a
cross-Application ordering problem, because sync waves do not span
Applications. It would work eventually, through retries, but "works eventually
after some failed syncs" is not a state worth designing for.

`kubernetes/platform` therefore holds only cluster-scoped objects: namespaces
with their Pod Security Admission labels, and the priority classes.

## Priority classes

`kubernetes/platform/priority-classes.yaml` defines five, and the ordering is a
decision rather than a default:

| Class | Value | For |
| --- | --- | --- |
| `platform-critical` | 900000 | Ingress, CSI, autoscaler, Argo CD |
| `platform-observability` | 800000 | Prometheus, Alertmanager, Grafana |
| `workload-high` | 100000 | Production workloads |
| `workload-default` | 0 | The global default |
| `workload-batch` | -10000 | Interruptible, typically on the spot pool |

Observability sits above every workload on purpose. Losing Prometheus during an
incident is worse than losing a replica, because it removes the evidence of what
is going wrong at exactly the moment it is needed.

`workload-default` is zero rather than negative so that a pod which asks for
nothing is not evicted ahead of work explicitly marked as batch.

These classes are also applied by the `eks_platform` Ansible role, from the same
file, before any controller is installed. That is not duplication for its own
sake: every platform controller asks for `platform-critical`, and the API server
rejects a pod naming a priority class that does not exist — including Argo CD's
own pods. Argo CD then adopts the identical objects and reports `Synced`.

## Reaching the Argo CD UI

There is no public ingress for Argo CD in any environment. Port forward:

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

Delete that Secret once a real identity provider is configured. Until then it is
a shared static password, which is the reason the UI is not exposed.

## When an Application will not sync

```bash
kubectl -n argocd get applications
kubectl -n argocd describe application monitoring
kubectl -n argocd logs deploy/argo-cd-argocd-repo-server --tail=100
```

| Symptom | Usual cause |
| --- | --- |
| `ComparisonError`, cannot resolve revision | `gitops_repo_url` is a private repository with no credentials configured |
| `OutOfSync` forever on the same field | A controller mutates the field; add it to `ignoreDifferences` |
| `Too long: must have at most 262144 bytes` | Missing `ServerSideApply=true` on a CRD-heavy chart |
| Healthy but nothing deployed | `path` points at a directory that does not exist on `targetRevision` |
| Namespace stuck `Terminating` | A finalizer on a resource inside it; usually a PVC or a webhook config |
