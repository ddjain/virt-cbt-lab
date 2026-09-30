# 12. KubeVirt source-of-truth reference

## Scope and version

This page maps the documented CBT behavior to the upstream KubeVirt source reviewed at tag [`v1.8.4`](https://github.com/kubevirt/kubevirt/tree/v1.8.4). That tag matches the KubeVirt operator version observed on cloud05 during the live audit. A downstream OpenShift Virtualization build can carry patches; when behavior matters, compare the installed image/source version and the live CRD/API behavior.

The paths below are repository-relative GitHub links. Line anchors are useful navigation hints, not a stable API: upstream line numbers can move.

## CRD and API contract

| Contract | Upstream implementation | What the code establishes |
|---|---|---|
| Backup and tracker types, `Push`/`Pull`, `Start`/`Abort`/`Export`, source references, immutable spec, status fields, conditions | [`staging/src/kubevirt.io/api/backup/v1alpha1/types.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/staging/src/kubevirt.io/api/backup/v1alpha1/types.go#L27-L274) | `VirtualMachineBackup` supports a VM or tracker source. `VirtualMachineBackupTracker` stores `latestCheckpoint` and `checkpointRedefinitionRequired`. `VirtualMachineBackupSpec` is immutable and validates `pvcName`, source group/kind, Pull token, and mode. |
| API group and resource kinds | [`staging/src/kubevirt.io/api/backup/v1alpha1/register.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/staging/src/kubevirt.io/api/backup/v1alpha1/register.go#L30-L65) | The API group is `backup.kubevirt.io/v1alpha1`; resources are `virtualmachinebackups` and `virtualmachinebackuptrackers`. |
| CBT state machine and VMI backup status | [`staging/src/kubevirt.io/api/core/v1/types.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/staging/src/kubevirt.io/api/core/v1/types.go#L2160-L2218) | CBT states are `PendingRestart`, `Initializing`, `Enabled`, `Disabled`, and `IncrementalBackupFeatureGateDisabled`. VMI backup status carries start/end, completed/failed, warning/error text, checkpoint, and included volumes. |
| CBT selector configuration | [`staging/src/kubevirt.io/api/core/v1/types.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/staging/src/kubevirt.io/api/core/v1/types.go#L3100-L3116) | The cluster configuration selects which VMs receive CBT; the VM disk/volume itself does not independently enable the feature. |

## Feature-gate and volume eligibility logic

| Concern | Upstream implementation | Operational implication |
|---|---|---|
| `IncrementalBackup` gate and selector matching | [`pkg/virt-config/feature-gates.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-config/feature-gates.go#L32-L46), [`pkg/virt-config/feature-gates.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-config/feature-gates.go#L204-L212), [`pkg/storage/cbt/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/cbt.go#L80-L170) | CRDs can exist while CBT remains disabled. The gate and selector must match, then the VM/VMI state must reach `Enabled`. |
| CBT state transitions | [`pkg/storage/cbt/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/cbt.go#L172-L281) | A running VMI normally passes through a restart boundary before CBT becomes active. Disabling selectors can require another restart. |
| Eligible volumes | [`pkg/storage/cbt/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/cbt.go#L297-L315) | Only PVC, DataVolume, and HostDisk volumes are CBT-eligible. Container disks, cloud-init, empty disks, and other non-eligible volumes are not included in CBT backup output. |

## Control-plane reconciliation

| Step | Upstream implementation | Behavior and failure semantics |
|---|---|---|
| Backup controller construction, informer wiring, rate-limited queues | [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L104-L197), [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L356-L401) | `virt-controller` watches Backup, Tracker, VMI, VMExport, and PVC-related state. Errors are requeued with rate limiting; completed resources are skipped unless deletion cleanup is required. |
| Eligibility and initiation | [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L459-L588), [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L590-L655) | The source VM must exist, have a running VMI, have an eligible volume, and report CBT `Enabled`. Migration blocks initiation. A tracker with a checkpoint selects Incremental unless `forceFullBackup` is true; otherwise the request is Full. |
| Destination attach/detach | [`pkg/storage/cbt/push-target-pvc.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/push-target-pvc.go#L60-L214) | The destination must be a filesystem PVC. The controller patches it into VMI `utilityVolumes` with type `Backup`, waits for `HotplugVolumeMounted`, then removes it during cleanup. PVC/hotplug events are not equivalent to terminal backup status. |
| VMI backup status and terminal conditions | [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L933-L1013), [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L1220-L1295) | `Done=True` is set for both successful and failed terminal outcomes. The `Done` reason and VMI `backupStatus.failed`/`backupMsg` distinguish them. A guest freeze/thaw warning can produce completed-with-warning rather than failure. |
| Tracker update and cleanup | [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L1238-L1342), [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L1352-L1375) | A successful checkpoint updates `latestCheckpoint`; failed backups do not advance it. Cleanup removes Pull exports, detaches the destination PVC, and removes the source VMI backup status before the final result is published. |
| Delete/abort and Pull TTL | [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L546-L585), [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L657-L676), [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L905-L930) | Deleting a progressing backup asks the launcher to abort, then cleanup continues. Pull backups can expire from `creationTimestamp`; expiry aborts an unfinished job and deletes its VMExport. |

## Tracker recovery after restart or migration

| Step | Upstream implementation | Behavior and failure semantics |
|---|---|---|
| Mark checkpoint for redefinition | [`pkg/virt-handler/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-handler/cbt.go#L53-L149) | During CBT `Initializing`, after all eligible domain disks have a `DataStore`, `virt-handler` marks trackers that have checkpoints. It then changes the VMI CBT state to `Enabled`. |
| Reconcile the flag | [`pkg/storage/cbt/backuptracker.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backuptracker.go#L37-L169) | `virt-controller` calls `RedefineCheckpoint`. A transient error is rate-limited and retried. An HTTP 422/Unprocessable Entity is treated as an invalid checkpoint: the checkpoint and flag are cleared, an event is emitted, and the next backup becomes Full. |
| Migration restart boundary | [`pkg/virt-handler/migration-target.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-handler/migration-target.go#L1076-L1108) | A migration target with CBT enabled is returned to `Initializing` so the same disk/checkpoint redefinition path can run. This is distinct from a backup-copy failure. |

## Node-local runtime and QEMU/libvirt path

| Step | Upstream implementation | Behavior and failure semantics |
|---|---|---|
| Create CBT overlays | [`pkg/virt-launcher/virtwrap/storage/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/cbt.go#L45-L143), [`pkg/virt-launcher/virtwrap/storage/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/cbt.go#L259-L334) | A qcow2 overlay is created for each eligible volume. It uses QMP `blockdev-create`; a failed creation removes the partial file. The overlay path is in the VMI persistent-state area, not the backup destination. |
| Expose overlay plus raw backing disk to libvirt | [`pkg/virt-launcher/virtwrap/converter/converter.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/converter/converter.go#L692-L783) | CBT disks use a qcow2 overlay as the front file and a `DataStore` pointing to the raw file/block device. The backup code identifies these `DataStore` disks. |
| Receive backup command | [`pkg/virt-launcher/virtwrap/cmd-server/server.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/cmd-server/server.go#L815-L905) | The launcher rejects backup requests unless CBT is `Enabled`, validates Start/Abort/Export options, and delegates to the in-process domain manager. This command is a launcher RPC, not a Kubernetes API call. |
| Dispatch Start/Export/Abort | [`pkg/virt-launcher/virtwrap/manager.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/manager.go#L2756-L2770) | Start, Pull export, and abort use separate storage-manager paths. |
| Build full/incremental backup and checkpoint XML | [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L58-L205), [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L207-L300) | The full backup has no incremental parent. An incremental request carries the tracker checkpoint name. Only `DataStore` disks are copied; the checkpoint name is `<backup-name>-<UTC start timestamp>`. Guest freeze is best effort; thaw failure is saved as a warning. |
| Idempotency and concurrency checks | [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L87-L123), [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L611-L625) | Repeating the same in-progress command is ignored; repeating a completed command fails; a different command while one is active fails. Failed-to-start metadata is cleared so a retry can initialize fresh state. |
| Interpret libvirt job completion | [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L302-L367) | Completed succeeds; failed always fails; canceled fails in Push mode but is intentionally non-failing for Pull mode. The result is written to the launcher metadata cache and propagated through the domain metadata notifier. |
| Abort and Pull tunnel | [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L369-L445) | Abort is valid only for the matching unfinished backup and an unbounded libvirt backup job. Pull mode starts a mutually authenticated TLS tunnel to the export Service; the backup data still originates from the mounted backup socket/PVC. |

## Checkpoint redefinition and error classification

| Step | Upstream implementation | Behavior and failure semantics |
|---|---|---|
| Launcher checkpoint RPC | [`pkg/virt-launcher/virtwrap/cmd-server/server.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/cmd-server/server.go#L907-L954) | It rejects disabled CBT, invalid checkpoint JSON, and runtime failures. It returns `checkpointInvalid=true` when storage reports a corrupt/inconsistent libvirt checkpoint. |
| Query bitmap state | [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L462-L609) | QMP `query-named-block-nodes` is used because `qemu-img info` does not see updated live bitmap state. Only disks containing the named bitmap are included in the redefined checkpoint. `CreateCheckpointXML` uses `REDEFINE | REDEFINE_VALIDATE`. |
| HTTP error mapping | [`pkg/virt-handler/rest/lifecycle.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-handler/rest/lifecycle.go#L384-L422) | Invalid/corrupt checkpoint → HTTP 422, intended to clear the tracker checkpoint. Transient launcher/runtime error → HTTP 503, intended to retry. Malformed request → HTTP 400. |
| Controller interpretation | [`pkg/storage/cbt/backuptracker.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backuptracker.go#L121-L152) | The controller currently identifies invalid redefinition by the 422/Unprocessable Entity response text; all other errors stay retryable. |

## Pull-mode export path

Pull mode is not exercised by this repository's default Push manifests, but it is part of the installed API:

1. `virt-controller` creates a `VirtualMachineExport` owned by the `VirtualMachineBackup`, waits for its Service name, creates a short-lived client certificate, and sends an `Export` command to virt-launcher. See [`pkg/storage/cbt/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L695-L902).
2. The export controller treats a progressing Backup with included volumes as a source and exposes data/map endpoints. See [`pkg/storage/export/export/backup-source.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/export/export/backup-source.go#L41-L187).
3. The export server serves backup data/map paths over TLS and checks the backup token. See [`pkg/storage/export/virt-exportserver/exportserver.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/export/virt-exportserver/exportserver.go#L157-L185) and [`#L262-L291`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/export/virt-exportserver/exportserver.go#L262-L291).
4. Pull-mode TTL and export deletion are controller responsibilities; endpoint readiness is not the same as a Push PVC artifact being copied.

## Source-grounded chaos invariants

A chaos test should preserve or explicitly classify these invariants:

- A backup is not successful merely because `Done=True`; inspect its `Done` reason, `status.type`, checkpoint, included volumes, and VMI backup status.
- A failed backup must not advance the tracker checkpoint; a successful backup must advance it only after a checkpoint exists.
- A tracker checkpoint can require redefinition after VMI restart or migration. 422 means discard the checkpoint and fall back to Full; 503 means retry.
- CBT data depends on the persistent-state overlay and its libvirt bitmap/checkpoint state. A destination PVC failure and a persistent-state failure are different experiments.
- A destination PVC is hotplugged as a filesystem utility volume and detached during cleanup. Attachment/hotplug events are intermediate signals.
- The guest freeze window is short and best effort; block-copy continues after thaw. Network/SSH health and local backup I/O are separate failure domains.
- The launcher rejects backup requests when CBT is not `Enabled`, and it prevents concurrent or replayed jobs with matching name/start-time metadata.

## Live-cluster cross-check commands

Use these commands on a cluster with the same API and permissions; they are read-only except for `oc exec` inspection:

```sh
oc get kubevirt -n openshift-cnv -o yaml
oc get crd virtualmachinebackups.backup.kubevirt.io -o yaml
oc explain virtualmachinebackup.spec --recursive
oc explain virtualmachinebackup.status --recursive
oc get vm,vmi,vmbackup,vmbackuptracker -A
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc get pod -n "$NAMESPACE" -l vm.kubevirt.io/name="$VM_NAME"
oc logs -n "$NAMESPACE" "$LAUNCHER_POD" -c compute
oc exec -n "$NAMESPACE" "$LAUNCHER_POD" -c compute -- \
  virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree
```

For exact artifact metadata, copy the backup files into an isolated read-only inspection pod and run `qemu-img info` and `qemu-img map --output=json`; the repository's semantic restore test does not make those physical-layout assertions.
