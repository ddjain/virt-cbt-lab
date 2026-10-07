# OADP VM backup and restore plan for the CBT demo

**Status:** Planning guide. Confirm target-cluster prerequisites and change approvals before running any mutating step.

## Goal

Evaluate OpenShift API for Data Protection (OADP) as an additional VM backup and restore path for the repository's KubeVirt Changed Block Tracking (CBT) demonstration on a compatible OpenShift Virtualization cluster. The intended result is a reproducible OADP backup of a CBT-enabled VM, followed by a restore into a safe test target and verification of real guest data.

This is complementary to `make e2e`; it is not a replacement for that workflow or a means of testing the CBT checkpoint chain.

## What OADP is

OADP is Red Hat's OpenShift data-protection operator. It deploys and configures Velero and its OpenShift-supported plugins. Backups and restores are requested through Kubernetes resources such as Velero `Backup` and `Restore` objects, with OADP-specific configuration supplied by a `DataProtectionApplication` (DPA).

At a high level, an OADP VM backup consists of:

1. Velero records the selected Kubernetes resources for a workload namespace.
2. The KubeVirt Velero plugin follows the VM resource graph and includes relevant KubeVirt/CDI resources, such as DataVolumes and PVCs.
3. CSI snapshots capture the disk volumes. With DataMover enabled, snapshot data is copied to the configured object store.
4. A Velero restore recreates the selected resources and volumes, subject to the restore cluster having compatible storage and other dependencies.

OADP is a workload backup tool, not a full-cluster recovery product. It does not back up etcd or OpenShift Operators and does not provide full-cluster backup and restore.

## Relationship to this repository's CBT E2E

The existing `make e2e` sequence is:

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```

It enables CBT on a VM, writes guest data, requests a KubeVirt `VirtualMachineBackup` of type `Full`, records a checkpoint in a `VirtualMachineBackupTracker`, mutates the guest, then requests an `Incremental` backup based on that checkpoint. The repository's restore verification separately reconstructs the qcow2 full image and incremental overlay and compares the recovered guest data with recorded hashes.

OADP uses a different path: Velero resource backup + CSI volume snapshots (optionally moved to object storage) + a KubeVirt plugin. That path does not request the repository's `VirtualMachineBackup` or tracker API and does not prove the full/incremental CBT checkpoint semantics. Keep these as separate acceptance criteria:

- **CBT E2E:** CBT enabled; full and incremental backup types; distinct checkpoints; tracker advancement; full-only and full-plus-incremental guest-data reconstruction.
- **OADP E2E:** OADP backup succeeds; backup data reaches the chosen object store when DataMover is enabled; restore succeeds; restored VM starts and contains the expected guest data.

For the first OADP test, take its backup after the existing CBT workflow has completed and use the post-incremental guest hash as the restore expectation. That proves the OADP snapshot restores the final guest state without implying that OADP performed the incremental CBT operation.

## Target-cluster preflight

Before installation, repeat the read-only inventory in Phase 0. Confirm the supported OpenShift/OADP versions, API availability, CSI/snapshot/DataMover prerequisites, selected VM disk StorageClass and volume mode, and object-store readiness. Record sanitized capability results only; do not add cluster identities, internal hostnames, kubeconfig paths, credentials, or endpoint URLs to this plan.

## Compatibility and supported backup method

Use the Red Hat OADP release supported for the selected OpenShift version. Reconfirm the support matrix and current catalog version/channel immediately before installation; do not rely on a stale lab observation.

For OpenShift Virtualization, Red Hat documents these supported OADP backup methods:

- CSI backups.
- CSI backups with DataMover.

The documented VM integration excludes file-system backup/restore and volume-snapshot backup/restore. Therefore:

- Do not use `cbt-demo-hpp` as the OADP VM disk target.
- Prefer an ODF CSI-backed VM disk, such as the observed `ocs-storagecluster-ceph-rbd` or `ocs-storagecluster-ceph-rbd-virtualization`, after verifying the live VM's actual PVC and snapshot support.
- Use CSI DataMover to copy snapshot data to object storage when the goal includes durable recovery independent of the source volumes or cluster.
- A `VolumeSnapshotClass` exists on the cluster. The OADP 1.6 release notes say that CSI backup/restore no longer requires a `VolumeSnapshotClass`; do not add or alter Velero-specific labels as a speculative prerequisite. Follow the installed OADP 1.6.1 documentation and events if behavior differs.

The ODF snapshot class `Delete` policy means the Kubernetes snapshot resource can be deleted with its owning lifecycle. For durable copies, the test must verify that DataMover completed and the backup is recoverable from object storage; a local snapshot's existence alone is not durable-backup proof.

## Prerequisites

### Cluster and permissions

- OpenShift 4.22 with OpenShift Virtualization installed and healthy.
- Cluster-admin access for installing the operator and configuring DPA, storage, and credentials.
- Red Hat Operator catalog access and permission to install the stable `redhat-oadp-operator` package.
- Sufficient cluster resources for the OADP controller, Velero, CSI snapshot operations, and DataMover/node-agent pods.

### VM storage and snapshot capability

- The selected CBT VM must have its disk PVC on an ODF CSI-backed StorageClass, not HPP.
- Verify the correct Ceph RBD CSI driver, snapshot API/controller, and RBD snapshot class are healthy.
- Confirm PVC volume mode, access mode, capacity, and current VM-to-PVC/DataVolume ownership before selecting the VM.
- Confirm target storage and capacity for the restore; restored VM volumes are provisioned as new claims.

### Backup object store

Choose explicitly between these targets:

1. **Same-cluster lab proof:** ODF NooBaa with a dedicated OBC-backed bucket. Confirm NooBaa readiness, then create the OBC and configure a DPA BSL.
2. **Independent recovery proof (recommended):** an S3-compatible object store outside the source cluster/storage failure domain, with a dedicated bucket/prefix and appropriate credentials.

For either target, provide the endpoint, bucket, prefix, region/provider settings, credentials, trusted CA details where needed, and network access from OADP pods. Do not put credentials in manifests committed to this repository or print them in logs. Do not disable TLS verification to work around an untrusted certificate; configure the correct CA.

### Restore dependencies

- A target namespace and a non-conflicting restore strategy.
- Compatible StorageClasses and CSI support at the target.
- Any required cluster-scoped VM instancetype/preference objects, network attachments/configuration, and other cluster dependencies must be available separately. The KubeVirt Velero plugin documents that not all cluster-scoped and network configuration is backed up.
- A guest-data verification mechanism, such as reading the known file and comparing its expected SHA-256 hash after the restored VM boots.

## Proposed setup and test sequence

### Phase 0 — repeat read-only checks

Run these checks from an authorized cluster-admin context with the target kubeconfig selected. They inspect state only; they do not install or create resources.

```sh
oc whoami
oc get clusterversion version
oc get csv -A
oc get packagemanifest redhat-oadp-operator -n openshift-marketplace
oc get ns openshift-adp
oc api-resources --api-group=oadp.openshift.io
oc get storageclass
oc get csidrivers
oc get volumesnapshotclass
oc get volumesnapshot
oc get storagecluster -n openshift-storage
oc get noobaa -n openshift-storage
oc get obc -A
oc get vm,vmi -A -l cbt-demo=enabled
oc get pvc -n vm-cbt-demo -o wide
```

For the pilot VM, inspect its labels, DataVolume/PVC ownership, storage class, mode, readiness, current guest state, and whether it is one of the currently shared workloads. Avoid printing Secrets or full configuration that may contain credentials or internal endpoint values.

### Phase 1 — select the pilot and destination

- Use a dedicated fresh CBT run with `MANIFEST_VARIANT=odf` or an existing VM whose root disk is confirmed ODF-backed. The repository's current default E2E variant is ODF-backed; `cbt-demo-hpp` remains a non-CSI option.
- Do not select an HPP-backed VM merely because its CBT APIs work; the CBT workflow's success does not imply its storage supports the OADP CSI path.
- Select exactly one VM by a unique run label. The repository labels resources with `virt-cbt-lab/run-id`; confirm that the VM and disk resources share the expected run ownership labels before using a Velero label selector.
- Choose external object storage for independent recovery, or document that an ODF NooBaa destination only demonstrates same-cluster restore.
- Coordinate with concurrent workloads and CBT runs; avoid selecting a VM in use or overloading a shared worker during backup/restore.

### Phase 2 — install the Red Hat OADP operator

- Install the Red Hat `redhat-oadp-operator` release supported for the target OpenShift version in `openshift-adp`; confirm the current catalog version/channel first.
- Do not install a similarly named Community operator in place of the Red Hat package.
- Verify the operator CSV is `Succeeded`, the OADP APIs are registered, and the controller pod is ready.

### Phase 3 — provision object storage credentials

For an ODF NooBaa lab target, create an OBC in the OADP namespace and use the generated bucket/credential information to configure Velero. For an external S3 destination, provision the dedicated bucket and least-privilege credentials through the storage administrator/provider.

Before referencing credentials from a DPA, ensure the Secret is in the expected OADP namespace and uses the key name required by the chosen provider configuration. Keep the Secret content out of source control, command output, and this plan.

### Phase 4 — create the DataProtectionApplication

Configure the DPA with:

- `kubevirt` plugin for VM/DataVolume/PVC relationships.
- `openshift` plugin for OpenShift-specific resources.
- `csi` plugin for CSI snapshots.
- The object-storage provider plugin (for example, `aws` for S3-compatible storage).
- A default BackupStorageLocation pointing at the dedicated bucket/prefix and credential Secret.
- CSI snapshot DataMover enabled, including the OADP node agent with `uploaderType: kopia` and the DPA's default snapshot data movement setting.
- Appropriate timeouts/resource allocations if live operation requires them; do not add tuning until the unmodified baseline is measured.

Illustrative shape only; substitute provider-specific settings and Secret names from the selected object-store procedure. This is not an applied manifest:

```yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: oadp-cbt
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - kubevirt
        - openshift
        - csi
        - aws
      resourceTimeout: 10m
      defaultSnapshotMoveData: true
    nodeAgent:
      enable: true
      uploaderType: kopia
  backupLocations:
    - name: default
      velero:
        provider: aws
        default: true
        credential:
          name: <credential-secret>
          key: <provider-credential-key>
        objectStorage:
          bucket: <dedicated-bucket>
          prefix: <dedicated-prefix>
        config:
          region: <provider-region>
          s3Url: <S3-compatible-endpoint>
          s3ForcePathStyle: "true"
```

For native AWS S3, provider configuration differs; for NooBaa, follow the ODF/OADP procedure for its endpoint, region, path-style behavior, and CA. `s3Url` and `s3ForcePathStyle` are typical S3-compatible settings, not universal values.

No `VolumeSnapshotLocation` is needed for the CSI snapshot path described in the OpenShift VM integration documentation. Do not configure one by default unless the selected provider/method requires it.

### Phase 5 — verify OADP readiness

Before creating any VM backup, check:

- DPA reports a successful reconciled condition.
- Velero and required node-agent pods are ready.
- The BackupStorageLocation phase is `Available`.
- The selected CSI driver and snapshots are operational.
- OADP can reach the object-store endpoint and has valid credentials/CA trust.

A reconciled DPA alone is not proof that the bucket is usable. Check BSL availability and then prove the path with a small, isolated backup.

### Phase 6 — run a selected-VM backup

After the repository CBT E2E has established the expected guest state, create a Velero `Backup` in `openshift-adp` that:

- Includes only the selected VM namespace.
- Uses the selected VM's unique run label as a label selector.
- Sets the chosen BackupStorageLocation.
- Enables `snapshotMoveData: true` for the backup (or confirms the DPA default is applied).

OpenShift documentation's single-VM example uses a `Backup` CR with `includedNamespaces`, `labelSelector`, `storageLocation`, and `snapshotMoveData: true`. For this repository, use the actual run ID rather than a generic `app` label if it uniquely identifies the VM resources.

Wait for Velero's terminal backup phase. Review the Backup description/logs and related snapshot/data-movement resources. A `Completed` phase must be accompanied by evidence that the VM's PVC was included and the data-movement task completed when durable movement is part of the test.

### Phase 7 — restore into an isolated target

- Restore to a scratch namespace or test cluster, not over the active CBT VM/PVC names.
- Ensure target storage and cluster-scoped VM dependencies exist.
- Use a restore namespace mapping when restoring into a different namespace, if supported by the selected Velero/OADP CRD version; check the installed CRD schema before applying the Restore.
- Set `restorePVs: true` for the VM restore path.
- Wait for the Restore to reach its terminal state; inspect warnings/errors and confirm the new PVCs bind.
- Confirm the restored VM becomes Ready/Running. Avoid concurrent duplicate guest identity/network exposure; if needed, keep the source VM stopped during the isolated restore validation or configure the target VM network appropriately.

OpenShift's documented single-VM restore uses a Velero `Restore` CR with `backupName` and `restorePVs: true`. For restoring one VM from a multi-VM backup, the Red Hat instructions require selectors that identify both the VM and the associated DataVolume identity so the PVC is restored correctly.

### Phase 8 — verify data and CBT independence

- Capture/retain the expected guest hash from the CBT workflow state at the time of OADP backup.
- Read the restored guest file through the supported guest access method and compare its SHA-256 with that expected value.
- For the first run, back up after the existing full-plus-incremental CBT E2E and compare against the final incremental-state hash.
- Report the OADP result separately from the existing CBT full/incremental/checkpoint and qcow2-reconstruction checks.
- If the claim is disaster-recovery durability, repeat restore from the object-store copy without depending on the source volume snapshot or original ODF cluster.

## Acceptance criteria

The pilot is successful only if all relevant criteria pass:

1. Correct Red Hat OADP operator release for OpenShift 4.22 is installed and healthy.
2. DPA is reconciled, Velero/node-agent are ready, and the BSL is `Available`.
3. Backup selects only the intended CBT VM and includes its VM disk through CSI.
4. When using DataMover, snapshot bytes have been moved to the configured object storage and the backup can be restored from that copy.
5. Restore completes into the isolated target; PVCs bind and VM starts.
6. Restored guest data matches the hash captured at backup time.
7. The existing CBT E2E remains independently passing; OADP results do not stand in for CBT checkpoint assertions.

## Risks and boundaries

- **Wrong operator package:** select the Red Hat OADP operator supported by the target OpenShift release, not a similarly named Community package.
- **Wrong storage class:** the HPP VM can pass the repository CBT E2E but does not provide the CSI-backed OADP path. Use an ODF CSI-backed VM disk.
- **Snapshot-only durability:** a local CSI snapshot may share the source storage failure domain. Use DataMover to object storage for independent copies.
- **NooBaa failure domain:** a same-cluster NooBaa bucket is suitable for a lab test but does not prove recovery after loss of the source cluster/storage.
- **VM dependency gaps:** plugin documentation says some cluster-scoped and network configuration is not included; establish dependencies at the target.
- **Shared live workloads:** coordinate backup and restore activity to avoid contention or disrupting concurrent VM workloads.
- **Snapshot class policy:** check the selected snapshot class deletion policy; prove DataMover and restore behavior rather than assuming a local snapshot persists.
- **Guest consistency:** take the test backup at a known guest state and avoid concurrent guest mutation during backup if the test expects an exact file hash. A successful resource backup alone does not prove application consistency.
- **Scope:** OADP does not recover etcd, Operators, or a full OpenShift cluster.

## References

### Red Hat documentation

- [OpenShift Container Platform 4.22: OADP Application backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/backup_and_restore/oadp-application-backup-and-restore) — compatibility matrix, OADP/OpenShift Virtualization integration, CSI/DataMover support, DPA setup, single-VM Backup and Restore examples.
- [OpenShift Data Foundation documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.22) — ODF storage, NooBaa, and object-bucket configuration.

### Upstream projects

- [OpenShift OADP Operator](https://github.com/openshift/oadp-operator) — operator implementation and configuration documentation.
- [KubeVirt Velero plugin](https://github.com/migtools/kubevirt-velero-plugin) — VM/DataVolume/PVC resource handling, plugin compatibility, and supported backup methods.
- [Velero CSI plugin](https://github.com/vmware-tanzu/velero-plugin-for-csi) — CSI snapshot behavior and the durability caveat for snapshots that remain on primary storage.

### Repository evidence

- [`../vm-cbt-workflow.md`](../vm-cbt-workflow.md) — CBT E2E behavior and storage details.
- [`../cbt/08-operations.md`](../cbt/08-operations.md) — operational checks and failure interpretation.
- [`../cbt/12-kubevirt-source-reference.md`](../cbt/12-kubevirt-source-reference.md) — upstream API/controller behavior.
