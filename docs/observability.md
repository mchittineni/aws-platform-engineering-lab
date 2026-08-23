# Observability

Two systems, deliberately. Prometheus and Grafana run inside the cluster, which
is exactly why they cannot be the whole answer: they go down with it.

| Layer | Tool | Watches | Survives a cluster outage |
| --- | --- | --- | --- |
| In cluster | kube-prometheus-stack | Kubernetes internals, workloads, dashboards | No |
| Out of cluster | CloudWatch, `modules/observability` | Control plane, NAT, node health, audit log | Yes |

## In cluster: kube-prometheus-stack

Deployed by Argo CD as a Helm Application, with a base values file and a per
environment overlay. See [gitops.md](gitops.md) for the layering.

### What is disabled, and why

```yaml
kubeProxy:              { enabled: false }
kubeEtcd:               { enabled: false }
kubeScheduler:          { enabled: false }
kubeControllerManager:  { enabled: false }
```

On a managed control plane these components exist but expose no endpoint the
cluster can scrape. Leaving the scrape jobs enabled produces four permanently
red targets, and a permanently red target page is a page nobody reads.

The four corresponding alert rules — `KubeProxyDown`, `etcdMembersDown`,
`KubeSchedulerDown`, `KubeControllerManagerDown` — are disabled for the same
reason. An alert that is always firing is not an alert.

What EKS *does* publish about the control plane goes to CloudWatch, which is the
other half of this document.

### Storage

Prometheus, Alertmanager and Grafana all use `WaitForFirstConsumer` binding, so
the EBS volume is created in whichever zone the pod is scheduled into. An EBS
volume cannot cross a zone boundary, which means **the pod is pinned to that
zone from then on**. If that zone goes away, the pod cannot be rescheduled until
the volume is restored elsewhere.

That is an accepted trade for a single Prometheus. It is the reason staging and
production run two replicas, and the reason both use the `gp3-backup` class so
the volume is in the backup plan.

### Retention

| | dev | staging | production |
| --- | --- | --- | --- |
| Prometheus replicas | 1 | 2 | 2 |
| Retention | 7 days | 15 days | 30 days |
| Volume | 25 GB | 50 GB | 100 GB |
| Alertmanager replicas | 1 | 2 | 3 |

`retentionSize` is set alongside `retention` on purpose. Time-based retention
alone does not stop a cardinality explosion from filling the volume, and a full
Prometheus volume means no metrics at all rather than fewer metrics.

### Alertmanager

Three replicas in production because Alertmanager gossips to deduplicate
notifications; with two, a network partition means every alert is delivered
twice. Routing to a real destination is left unconfigured here — wire it to the
same SNS topic or an incident tool, and remember that a notification path is
only real once it has been tested end to end.

## Out of cluster: CloudWatch

`modules/observability`, applied per environment.

### Control plane

`cluster_failed_request_count` in the `AWS/EKS` namespace. Sustained server-side
errors here mean kubectl, every controller and the autoscaler are all degraded
at once. Two consecutive breaching periods before alarming, so a single blip
does not page.

### NAT gateway

`ErrorPortAllocation` alarms on the first occurrence, with no tolerance, because
it never happens for a benign reason. `PacketsDropCount` has a threshold.

See [operations.md](operations.md) for what to do when it fires — port
exhaustion presents inside the cluster as random timeouts that look like an
application bug.

### Node health

`cluster_failed_node_count`, `node_cpu_utilization`, `node_memory_utilization`,
`node_filesystem_utilization` from the `ContainerInsights` namespace.

These metrics **only exist** once the `amazon-cloudwatch-observability` add-on is
collecting them, which is why one variable —
`enable_container_insights` — drives both the add-on and the alarms.
Enabling the alarms alone leaves them in `INSUFFICIENT_DATA`, which looks
identical to healthy on a dashboard.

Disk is alarmed at 80% because the kubelet begins evicting pods at 85% by
default. Alarming after the eviction has started is not useful.

### Audit log detections

Four metric filters over the control plane audit log:

| Detection | Threshold | Why |
| --- | --- | --- |
| `anonymous_api_access` | 1 | A served request for `system:anonymous` is never expected |
| `forbidden_responses` | 50 in 5 min | A probing credential. Set high enough to ignore a controller with a stale cache |
| `exec_into_pod` | 1 | Not wrong, but should always correlate with a known incident |
| `secret_enumeration` | 10 in 5 min | Cross-namespace Secret listing |

This is the same audit log GuardDuty analyses. GuardDuty finds the patterns AWS
knows about; these four are the specific questions this platform wants answered
immediately.

### One alarm to page on

`<cluster>-platform-degraded` is a composite alarm over the paging-worthy
children. On-call subscribes to one thing instead of twelve, and the composite
alarm's description points at the runbook.

### Dashboard

Deliberately small: API server requests, NAT egress, NAT errors, node health,
audit detections. Its purpose is the first sixty seconds of an incident — is the
control plane answering, are nodes leaving, is egress saturated. The deep dive
happens in Grafana.

## Logs

| Source | Destination | Retention |
| --- | --- | --- |
| EKS control plane, all 5 types | CloudWatch, KMS encrypted | 30 / 90 / 365 days |
| VPC flow logs | CloudWatch, KMS encrypted | 30 / 90 / 365 days |
| CloudTrail | S3 audit bucket + CloudWatch | 730 days / 90 days |
| Container stdout and stderr | CloudWatch, **off by default** | — |

The log group for the control plane is created by Terraform *before* the
cluster. A log group that EKS creates for itself never expires and uses an AWS
owned key, and neither can be changed retroactively without losing the history.

Container log shipping is off by default because it is charged per GB ingested
and is usually the largest line on an observability bill — while duplicating
what the in-cluster stack already holds. See
[cost-optimization.md](cost-optimization.md).

## What is missing

- **No log aggregation for application logs.** No Loki, no OpenSearch. Container
  logs are either in CloudWatch or nowhere.
- **No tracing.** No OpenTelemetry collector, no X-Ray.
- **No SLOs.** There are alarms on symptoms, not error budgets on objectives.
- **Alertmanager has no configured receiver.** Alerts fire and stop at
  Alertmanager.
