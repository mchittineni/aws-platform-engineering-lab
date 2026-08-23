# AWS Platform Operations

Day two procedures for the EKS environments.

## Getting access

```bash
aws eks update-kubeconfig --region eu-central-1 --name aws-platform-dev \
  --kubeconfig ~/.kube/aws-platform-dev.config
export KUBECONFIG=~/.kube/aws-platform-dev.config
```

A `kubectl` command that returns `error: You must be logged in to the server`
means the IAM identity has no access entry, not that the credentials are wrong:

```bash
aws eks list-access-entries --cluster-name aws-platform-dev
```

## Health check

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,\
POOL:.metadata.labels.platform\\.aws/pool,\
VERSION:.status.nodeInfo.kubeletVersion

kubectl get pods -A --field-selector=status.phase!=Running
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n argocd get applications
```

## Common failures

### Ingress stays pending, no ADDRESS

The Load Balancer Controller is the only thing that reconciles it.

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=100
```

| Log message | Cause |
| --- | --- |
| `AccessDenied` on `elasticloadbalancing:*` | ServiceAccount not annotated with the IRSA role, or the role's trust policy has the wrong subject |
| `couldn't auto-discover subnets` | Public subnets missing the `kubernetes.io/role/elb` tag |
| `WebIdentityErr` | The OIDC provider was recreated and the role trust policy points at the old ARN |

Check the annotation:

```bash
kubectl -n kube-system get sa aws-load-balancer-controller \
  -o jsonpath='{.metadata.annotations}'
```

### Pod stuck in ContainerCreating with no IP

The VPC CNI assigns real VPC addresses, so subnet exhaustion presents as
unschedulable pods rather than an obvious network error.

```bash
kubectl -n kube-system logs -l k8s-app=aws-node --tail=50

aws ec2 describe-subnets --subnet-ids <id> \
  --query 'Subnets[].AvailableIpAddressCount'
```

`/20` subnets give about 4000 addresses each, which is generous. If they do run
out, enable prefix delegation on the CNI add-on rather than resizing subnets.

### PVC stuck in Pending

```bash
kubectl describe pvc <name> -n <namespace>
kubectl -n kube-system logs deploy/ebs-csi-controller -c csi-provisioner
```

An EBS volume cannot cross availability zones. `WaitForFirstConsumer` binding
prevents most of this, but a pod with a node selector pinning it to a different
zone than an existing volume will never bind.

### Node NotReady

```bash
kubectl describe node <name>

# Get a shell without SSH
aws ssm start-session --target <instance-id>
sudo journalctl -u kubelet -n 100
```

### Cluster autoscaler is not scaling up

```bash
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=100
kubectl get pods -A --field-selector=status.phase=Pending
```

Usual causes: the pending pod requests more CPU or memory than any instance
type in the node group provides; the node group is already at `max_size`; or the
pod tolerates no taint that the only scalable pool carries.

## Kubernetes version upgrade

```bash
# 1. Check for deprecated APIs first
kubectl get apiservices | grep -v True

# 2. Control plane
#    bump kubernetes_version in the environment, then
terraform plan && terraform apply

# 3. Watch the node groups roll
kubectl get nodes -w

# 4. Bump the add-on versions
#    set addon_versions in the environment, then apply again
```

Between steps 2 and 3, confirm every workload has a PodDisruptionBudget.
Without one, a node drain either stalls indefinitely or evicts every replica at
once.

## Scaling

```bash
# Temporarily change the bounds without a Terraform apply
aws eks update-nodegroup-config \
  --cluster-name aws-platform-dev --nodegroup-name platform \
  --scaling-config minSize=2,maxSize=8,desiredSize=3
```

`desired_size` is in `ignore_changes`, so this does not create drift. Changing
`min_size` or `max_size` here does, and Terraform will revert it on the next
apply. Change those in code.

## Cost pause

```bash
for ng in platform spot; do
  aws eks update-nodegroup-config \
    --cluster-name aws-platform-dev --nodegroup-name "$ng" \
    --scaling-config minSize=0,maxSize=4,desiredSize=0
done
```

The control plane keeps billing. See
[cost optimisation](cost-optimization.md).

## Finding orphaned resources

Kubernetes creates AWS resources Terraform does not track. When a namespace is
deleted without its Services and Ingresses being reconciled first, they leak.

```bash
# Load balancers with no matching Ingress
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,DNSName]' --output table

# Unattached volumes
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

# Unassociated Elastic IPs
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table
```

## Disaster recovery

| Loss | Recovery |
| --- | --- |
| A node | Automatic; the node group replaces it |
| An availability zone | Automatic in production; dev loses egress if it held the NAT gateway |
| The cluster | `terraform apply` then `ansible-playbook`, roughly 20 minutes; Argo CD restores workloads from Git |
| Terraform state | Restore a previous object version from the state bucket |
| A KMS key | Cancel the deletion inside the 30 day window; after that, Secrets encrypted with it are unrecoverable |

Cluster recovery works because nothing in the cluster is the source of truth.
The gap is persistent volume data — no volume backup is configured yet. See the
known gaps in [security](security.md).

## Alarms and where they come from

Two systems watch this platform, and knowing which one paged you tells you
where to start.

| Source | Watches | Reaches you via |
| --- | --- | --- |
| Prometheus / Alertmanager, in cluster | Kubernetes internals, workloads | Alertmanager |
| CloudWatch, `modules/observability` | Control plane, NAT egress, node health, audit log | SNS, one composite alarm |

If the CloudWatch composite alarm `<cluster>-platform-degraded` fires and
Alertmanager is silent, suspect the layer underneath Kubernetes. If Alertmanager
is loud and CloudWatch is quiet, the infrastructure is fine and a workload is
not.

```bash
# What is currently in ALARM
aws cloudwatch describe-alarms --state-value ALARM \
  --query 'MetricAlarms[].[AlarmName,StateReason]' --output table

# The composite alarm, and which child tripped it
aws cloudwatch describe-alarms --alarm-names aws-platform-prod-platform-degraded
```

### `nat-<id>-port-allocation-errors`

The alarm nobody sets until the first time it fires. A NAT gateway runs out of
source ports at roughly 55,000 concurrent connections to a *single* destination,
and inside the cluster the symptom is random connection timeouts that look
exactly like an application bug.

Fixes, in order of preference: add a VPC endpoint for the destination service so
the traffic stops crossing NAT at all; spread the destination across more IPs;
add NAT gateways.

### `audit-anonymous-api-access`

The API server served a request for `system:anonymous` and did not reject it.
Treat as an incident.

```bash
aws logs start-query \
  --log-group-name /aws/eks/aws-platform-prod/cluster \
  --start-time $(date -u -v-1H +%s) --end-time $(date -u +%s) \
  --query-string 'fields @timestamp, sourceIPs.0, verb, objectRef.resource
                  | filter user.username = "system:anonymous"
                  | sort @timestamp desc'
```

### `audit-exec-into-pod`

Somebody opened a shell in a running pod. Not automatically wrong — it is how
debugging works — but in production it should always correlate with a known
incident. If it does not, find out whose credentials those were.

## Drift

The `Drift Detection` workflow runs a read-only plan against every environment
daily. Drift opens an issue with the plan attached; a subsequent clean plan
closes it.

Drift has exactly two honest resolutions:

1. **The change was intentional.** Put it in Git and apply it, so the next
   person to run a plan does not undo it.
2. **The change was not intentional.** Apply the current configuration to revert
   it, and work out how it happened.

Leaving an open drift issue is the third option, and it ends with somebody's
emergency console fix being silently reverted by an unrelated apply three weeks
later.

## Backup and restore

Volumes are backed up by AWS Backup, selected by the `platform.aws/backup` tag
that the `gp3-backup` StorageClass applies.

```bash
# Did last night's plan actually run?
aws backup list-backup-jobs --by-backup-vault-name aws-platform-prod \
  --by-created-after "$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'BackupJobs[].[State,ResourceArn,CompletionDate]' --output table
```

A backup job that has been failing silently for six weeks is worse than no
backup, because it is believed. That is what the SNS notifications on
`BACKUP_JOB_FAILED` are for — confirm the subscription.

The restore procedure, including what a snapshot does *not* restore, is in
[disaster-recovery.md](disaster-recovery.md).

## Rotating a compromised credential

There is no static AWS credential to rotate, which changes the procedure.

| What is compromised | What to do |
| --- | --- |
| A pod's IRSA role | Remove the ServiceAccount annotation or delete the role. Existing sessions last up to `max_session_duration`. |
| The CI apply role | Remove the GitHub environment protection approval, then narrow or delete the role. The OIDC trust means no key needs revoking. |
| A KMS key | Do **not** schedule deletion. Disable it, which stops new use while leaving decryption recoverable. |
| A node | Terminate the instance. The node group replaces it; the instance profile credentials die with it. |

For an IRSA role, revoke active sessions rather than waiting them out:

```bash
aws iam put-role-policy --role-name <role> --policy-name RevokeOlderSessions \
  --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*",
 "Condition":{"DateLessThan":{"aws:TokenIssueTime":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}]}
JSON
)"
```

## Upgrading Kubernetes

Always `dev` → `staging` → `production`, and never on the same day.

1. Bump `kubernetes_version` in `environments/dev`, plan, read the plan, apply.
2. Watch for a **replacement** of anything in the plan. A replaced node group is
   a rolling outage, and it looks identical to an update in the diff.
3. Node groups follow the control plane. `max_unavailable_percentage` sets the
   blast radius: 33% in dev, 25% in staging and production.
4. Bump the add-on versions in `addon_versions` **after** the control plane. An
   add-on newer than the control plane is unsupported.
5. Run `make verify ENV=dev`.
6. Leave it a week. Then staging, then production.

Every workload needs a `PodDisruptionBudget` before step 3, or the drain either
stalls forever or takes every replica down at once.
