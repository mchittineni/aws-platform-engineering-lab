# Disaster Recovery

What can be lost, what restores it, and how long each one takes. The honest
answer for some of these is "not tested" — that is stated rather than implied.

## Recovery objectives

| Scenario | RPO | RTO | Mechanism |
| --- | --- | --- | --- |
| One node lost | 0 | ~5 min | Managed node group replaces it |
| One availability zone lost | 0 for stateless | ~5 min stateless | Nodes in the other two zones; zonal EBS volumes do **not** follow |
| Whole cluster lost | 0 for config | 45 to 90 min | Terraform apply, then `make bootstrap`, then Argo CD |
| Persistent volume lost or corrupted | up to 24 h | 30 to 60 min | AWS Backup recovery point |
| Terraform state lost | seconds | ~10 min | S3 versioning |
| Whole region lost | **unrecovered** | — | No second region is provisioned |

The last row is the real gap. Everything else has a path.

## The cluster is reproducible; the data is not

This is the distinction that decides every procedure below.

**Reproducible from Git**, no backup needed: the VPC, the cluster, node groups,
add-ons, IAM roles, KMS keys, every Kubernetes object, every Helm release, every
Argo CD Application. Losing all of it costs time, not information.

**Not reproducible**: the contents of EBS volumes, the Secrets in etcd that were
not created from Git, and Terraform state.

So the recovery plan is: rebuild the reproducible part with the same tooling that
built it the first time, and restore the rest.

## Scenario: a node is lost

Nothing to do. The managed node group notices the failed health check and
replaces the instance. Pods reschedule if they have somewhere to go, which is
what the `PodDisruptionBudget` and `topologySpreadConstraints` on every workload
are for.

Verify:

```bash
kubectl get nodes
aws eks describe-nodegroup --cluster-name aws-platform-prod --nodegroup-name platform \
  --query 'nodegroup.health'
```

## Scenario: an availability zone is lost

Stateless workloads recover on their own. The control plane is unaffected — AWS
runs it across three zones.

What does **not** recover is anything with an EBS volume in the lost zone. An
EBS volume is zonal, and `WaitForFirstConsumer` binding means the volume was
created in whichever zone the pod first landed in. The pod stays `Pending`
because its PVC can only bind in a zone that no longer exists.

The options are, in order:

1. If the workload can be rebuilt from elsewhere (Prometheus, a cache), delete
   the PVC and let it provision a new volume in a surviving zone.
2. Restore the most recent recovery point into a surviving zone (below) and point
   a new PV at it.
3. Wait for the zone.

There is no option that both preserves the data and recovers immediately. That
is a property of zonal block storage, not of this platform.

## Scenario: the whole cluster is lost

45 to 90 minutes, and the procedure is the bootstrap procedure. That is the
point of keeping it reproducible.

```bash
# 1. Rebuild the infrastructure. The state knows what existed.
cd environments/production
terraform init -backend-config=backend.hcl
terraform plan          # read this: it should be a create plan, not a diff
terraform apply

# 2. Rebuild the platform layer
cd ../..
export EKS_VPC_ID=... EBS_KMS_KEY_ARN=...     # see docs/bootstrap.md step 3
make bootstrap ENV=production

# 3. Argo CD reconciles every application from Git on its own.
make verify ENV=production
```

Then restore volumes for anything stateful, and re-create any Secret that was
not sourced from Secrets Manager. That last set is the one worth enumerating
*before* an incident, because it is the only thing here that is not written
down anywhere.

## Scenario: a persistent volume is lost or corrupted

AWS Backup holds the recovery points. Volumes are selected by the
`platform.aws/backup` tag, applied by the `gp3-backup` StorageClass.

```bash
VAULT=aws-platform-prod

# Find the recovery point
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$VAULT" \
  --query 'RecoveryPoints[?ResourceType==`EBS`].[RecoveryPointArn,CreationDate,Status]' \
  --output table

# Restore it to a new volume
aws backup start-restore-job \
  --recovery-point-arn "<arn>" \
  --iam-role-arn "$(terraform -chdir=environments/production output -raw backup_role_arn)" \
  --resource-type EBS \
  --metadata '{"availabilityZone":"eu-central-1a","volumeType":"gp3","encrypted":"true"}'
```

The restore produces a **volume**, not a PVC. Kubernetes does not know it
exists. To attach it:

1. Create a `PersistentVolume` with `csi.volumeHandle` set to the new volume ID,
   `storageClassName: gp3-backup`, and a `nodeAffinity` requirement pinning it to
   the restored volume's zone.
2. Create a `PersistentVolumeClaim` with `volumeName` naming that PV.
3. Scale the workload back up.

Omitting the `nodeAffinity` is the mistake to avoid: without it the scheduler
will happily place the pod in a zone the volume cannot reach, and the pod hangs
in `ContainerCreating` with an attach error.

**This procedure is rehearsed in staging, not documented and hoped for.** That is
why staging carries a backup plan with a seven day retention even though nothing
in staging is precious. If it has not been rehearsed this quarter, treat the RTO
above as a guess.

## Scenario: Terraform state is lost or corrupted

The state bucket is versioned, so this is a rollback rather than a rebuild.

```bash
BUCKET=<state bucket>
KEY=aws/production/terraform.tfstate

aws s3api list-object-versions --bucket "$BUCKET" --prefix "$KEY" \
  --query 'Versions[].[VersionId,LastModified,Size]' --output table

aws s3api get-object --bucket "$BUCKET" --key "$KEY" \
  --version-id "<version>" restored.tfstate

terraform state push restored.tfstate
```

Then run a plan and read it carefully. A plan that wants to create resources
which already exist means the state is older than the infrastructure, and the
fix is `terraform import`, not apply.

The CI apply roles are denied `s3:DeleteBucket` and `s3:PutBucketVersioning` on
this bucket precisely so that this path stays available.

## Scenario: a KMS key is compromised or scheduled for deletion

Deleting the cluster secrets key makes **every Secret in etcd permanently
unreadable**. There is no recovery. The 30 day deletion window on every key in
this repository is the safety net, and the `kms_key_deletion` CloudWatch alarm
fires on the `ScheduleKeyDeletion` call.

If a key is scheduled for deletion in error:

```bash
aws kms cancel-key-deletion --key-id <key-id>
aws kms enable-key --key-id <key-id>
```

If a key is genuinely compromised, disable it rather than deleting it. Disabling
stops new use while leaving decryption recoverable by re-enabling.

## Scenario: the region is lost

Unrecovered, and this is a deliberate gap rather than an oversight.

What exists today: `modules/backup` accepts `copy_destination_vault_arn`, so
recovery points can be copied to a vault in a second region, and
`modules/tf-state-backend` accepts `enable_replication` for cross-region state
replication. Neither is wired up, because a second region needs a second set of
VPC CIDRs, a second set of environments and a decision about whether it is
warm or cold.

To close it: provision a vault in a second region, set
`backup_copy_destination_vault_arn` in production, enable state replication, and
then — the part that is actually the work — decide and document what "failover"
means for DNS and for anything stateful.

## What is not covered

- **Kubernetes object state.** AWS Backup protects volumes. Nothing captures the
  API objects, so recovering a single deleted namespace means re-syncing from Git
  and re-attaching volumes by hand. Velero would close this.
- **Point-in-time recovery for EBS.** Recovery points are daily. The RPO for a
  volume is therefore up to 24 hours, and no amount of procedure changes that.
- **A tested full region failover.** See above.

## Rehearsal schedule

A recovery procedure that has not been run is a hypothesis.

| Procedure | Frequency | Where |
| --- | --- | --- |
| Volume restore | Quarterly | staging |
| Full cluster rebuild | Twice a year | a throwaway environment |
| State rollback | Twice a year | dev |
| Node failure | Continuously, by the autoscaler | everywhere |
