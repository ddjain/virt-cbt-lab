# 11. Cloud05 live-audit evidence

## Scope and evidence boundary

This is a read-only audit snapshot of the live cloud05 cluster, recorded on 2026-09-30 UTC. It cross-checks the CBT documentation against API objects, CRD schema, VMI/launcher state, HPP storage, OVN network configuration, events, and launcher/controller logs. No new chaos action was injected by this audit. Existing resources and events from other runs were present; their timestamps and run IDs must be preserved before attributing an event to a test.

Use this page to understand what was actually observed. Use the other pages for the design that should remain valid when the cluster changes.

## Installed control plane

| Check | Observed |
|---|---|
| OpenShift | 4.22.15 |
| OpenShift Virtualization/HCO | 4.22.9 |
| KubeVirt operator | `v1.8.4` |
| Backup API | `backup.kubevirt.io/v1alpha1` |
| CRD ownership labels | `managed-by: virt-operator`, `part-of: hyperconverged-cluster` |
| CBT feature gate | `IncrementalBackup` |
| CBT selector | `cbt-demo=enabled` |
| Cluster network | OVN-Kubernetes |
| Nodes | 13 Ready nodes at audit time |
| `virt-controller` | 2 running replicas |
| `virt-handler` | DaemonSet across nodes |

The live KubeVirt configuration had the CBT selector and feature gate required by this repository. A cluster with the CRDs but without the feature gate or matching selector can accept manifests while leaving a VM's CBT state disabled; setup must verify `.status.changedBlockTracking.state=Enabled`.

## Network snapshot

```text
Pod network:     10.128.0.0/14, hostPrefix /23
Service network: 172.30.0.0/16
Cluster MTU:     1400
Geneve:          6081
IPsec:           disabled
VM interface:    pod network + masquerade
Guest access:    Service TCP/22 through oc port-forward
```

The representative VMI reported a private pod/guest address from the pod CIDR and `AgentConnected=True`. Its live libvirt XML contained the connected virtio-serial `org.qemu.guest_agent.0` channel. Backup bytes still used local QEMU `file`-driver paths, not the VM Service or NBD.

## Storage snapshot

```text
StorageClass:      cbt-demo-hpp
Provisioner:       kubevirt.io.hostpath-provisioner
Binding:           WaitForFirstConsumer
Reclaim:           Delete
Access mode:       ReadWriteOnce
HPP pool:          cbt-demo-pool
Backing capacity:  1489Gi reported by the pool PV
Placement:         one selected worker
```

The HPP resource used a host-local pool and a backing claim. Exact host paths and node names are intentionally dynamic; query them with `oc get hostpathprovisioner cbt-demo-hpp -o yaml` before a test.

Observed CBT workload PVCs were `Filesystem` RWO claims for:

- the cloned root disk;
- the generated persistent-state PVC;
- the full destination;
- the incremental destination.

The large representative root claim requested 40 GiB and was CDI-preallocated; its VMI reported `filesystemOverhead: 0.06` and `LiveMigratable=False` with reason `DisksNotLiveMigratable`. The VM template also set `evictionStrategy: None`.

## Representative live run

Run ID: `kb-large-0930-1248`, namespace `vm-cbt-demo`.

| Object | Observed state |
|---|---|
| VM/VMI | Running; CBT `Enabled`; Debian 12; `AgentConnected=True` |
| Full backup | `type=Full`, `Done=True`, checkpoint present |
| Incremental backup | `type=Incremental`, `Done=True`, checkpoint present |
| Tracker | latest checkpoint equals the incremental checkpoint |
| Included volume | `diskTarget=vda`, `volumeName=rootdisk` |
| Checkpoint tree | full checkpoint parent with incremental child |
| Launcher | `virt-launcher` `compute` container; no separate backup/export pod |

The API timestamps for this run were:

```text
full object created:        2026-09-30T12:50:38Z
full Done transition:       2026-09-30T12:51:07Z
incremental created:        2026-09-30T12:53:45Z
incremental Done transition:2026-09-30T12:54:00Z
```

These are API object durations. They include PVC binding, hotplug, controller reconciliation, and cleanup. They are not the exact QEMU byte-copy duration; use launcher log timestamps for that measurement.

## Observed runtime sequence

The representative launcher log included, in order:

```text
Backup begin called
Initializing backup
Freezing VMI to capture backup state
Thawing VMI after backup job started
Backup started
Backup has been completed successfully
Updated backup result in metadata via Notifier
Generating incremental backup ... from checkpoint: <full checkpoint>
```

The live QEMU command line showed:

```text
raw root file: /var/run/kubevirt-private/vmi-disks/rootdisk/disk.img
CBT layer:    /var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2
```

Both were local `file` driver block devices. The CBT layer was mounted from the persistent-state PVC, not the root-disk PVC.

## Observed warnings and their meaning

Cloud05 showed these event patterns:

- `HotplugFailed` with `disk.img: no such file or directory`, followed by `VolumeMountedToPod`; this was a materialization/retry boundary.
- `VirtualMachineBackupCompletedSuccessfully` and `VirtualMachineBackupFailed: Backup has failed: VMI backup status was lost` close together for some runs. Do not infer final state from event order alone.
- `VirtualMachineBackupCompletedWithWarning` for guest-agent freeze failures in runs where the guest agent was not connected.
- `ClaimMisbound` and `FailedMount` warnings around CDI temporary clone/upload PVCs while later clone completion succeeded.

The correct verdict procedure is: settled CR conditions/reason, tracker state, checkpoint tree, artifact checks, and restored data.

## Current cluster-state caveat

The audit found multiple full/incremental pairs and six running CBT-enabled VMs across the demo namespaces. This is useful evidence that run-derived Kubernetes names can coexist. It also creates shared-node contention and event interleaving. A chaos result must record the active run set, selected storage worker, launcher pod, and exact target backup name.

A separate `vm-cbt-restore` namespace contained manually named Pending PVCs and inspector pods referencing names that were not present there. Those objects are not evidence from the repository's run-derived restore verifier. The verifier uses `vm-restore-verify-<run-id>` in the workflow namespace and is deleted after collecting its log.
## Fresh live E2E cross-check

After the original audit, a new default-size E2E was run on cloud05 using run ID `docs-audit-135644` in namespace `vm-cbt-demo`. This run is additional live evidence, not a replacement for the point-in-time snapshot above:

| Check | Observed |
|---|---|
| VM/VMI | Running; VM CBT state `Enabled`; VMI on the HPP-selected worker (node name intentionally omitted) |
| KubeVirt control | operator `v1.8.4`; `IncrementalBackup` enabled; selector matches `cbt-demo=enabled`; `virt-controller` 2/2 ready; `virt-handler` 10/10 ready |
| Full backup | `vm-backup-docs-audit-135644`; `Done=True`; `type=Full`; checkpoint `vm-backup-docs-audit-135644-2026-09-30_13-57-27`; terminal reason was `Completed VirtualMachineBackup, warning: Failed freezing guest filesystem` |
| Incremental backup | `vm-incremental-docs-audit-135644`; `Done=True`; `type=Incremental`; checkpoint `vm-incremental-docs-audit-135644-2026-09-30_13-57-43` |
| Tracker | `vm-tracker-docs-audit-135644`; latest checkpoint equals the incremental checkpoint |
| Included volume | `rootdisk` / `vda` in both backup statuses and the tracker checkpoint |
| Destination PVCs | Full and incremental claims `Bound`, `Filesystem`, `ReadWriteOnce`, storage class `cbt-demo-hpp` |
| Restore verification | Full-only and combined full-plus-incremental hashes matched the guest captures; marker absent from full-only and present in combined restore |
| Restore pod policy | OpenShift emitted a `restricted` PodSecurity warning for the intentionally privileged restore pod, but allowed it |

The run also confirms the API contract visible in the source: default Push mode is represented by an omitted `spec.mode`, the tracker-backed request reports `Incremental`, the full copy completed with a guest-agent freeze warning, and the incremental copy settled with reason `Successfully completed VirtualMachineBackup`. The complete source mapping and fallback/error semantics are in [12. KubeVirt source reference](12-kubevirt-source-reference.md).

## Source-review verdict

The live object and the v1.8.4 source agree on the normal path:

```text
backup CR
  -> virt-controller validation, finalizer, target-PVC hotplug
  -> virt-launcher RPC
  -> libvirt/QEMU checkpoint + block-copy
  -> virt-handler/domain-metadata status propagation
  -> virt-controller status, cleanup, tracker update
```

The source review adds two important distinctions that must stay explicit in chaos reports:

- `Done=True` is also used for a terminal failure; inspect its reason and VMI `backupStatus.failed`.
- A `422 Unprocessable Entity` checkpoint-redefinition response clears the tracker checkpoint and intentionally causes the next backup to be Full; a `503 Service Unavailable` response is retryable.


## Section-by-section judge verdict

| Documentation section | Verdict | Remaining boundary |
|---|---|---|
| 01 Overview | **Pass for observed architecture** | Physical delta representation still needs `qemu-img` assertions |
| 02 Components | **Pass** | Pull mode and token behavior remain untested |
| 03 Network | **Pass** | Network disruption was not used to claim backup-data disruption |
| 04 Storage | **Pass for cloud05 demo topology** | HPP is local/RWO and single-worker; not HA storage |
| 05 Full backup | **Pass** | Hotplug and warning-event races need terminal-state handling |
| 06 Incremental backup | **Pass for normal chain** | Checkpoint redefinition after restart remains untested |
| 07 Restore | **Pass for guest-data reconstruction** | Does not boot a VM or prove qcow2 delta allocation |
| 08 Operations | **Pass** | Reports can still be mixed by concurrent local workflows |
| 09 Limitations | **Pass** | Failure outcomes remain unknown until chaos scenarios execute |
| 10 Chaos design | **Pass as test plan** | Scenarios are hypotheses until independently run and verified |
| 11 Cloud05 audit | **Pass for recorded evidence** | Point-in-time; repeat checks after topology, version, or workload changes |
| 12 KubeVirt source reference | **Pass for v1.8.4 source mapping** | Downstream patches and Pull-mode behavior require installed-build/live testing |

The overall documentation is therefore **operationally usable with explicit proof gaps**, not a claim that every failure path or production deployment property has been proven.

## Reproduce the audit checks

```sh
oc get kubevirt -n openshift-cnv -o yaml
oc get crd virtualmachinebackups.backup.kubevirt.io -o yaml
oc get crd virtualmachinebackuptrackers.backup.kubevirt.io -o yaml
oc get vm,vmi,vmbackup,vmbackuptracker -A
oc get storageclass cbt-demo-hpp -o yaml
oc get hostpathprovisioner cbt-demo-hpp -o yaml
oc get network.config.openshift.io cluster -o yaml
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
```

For a selected run:

```sh
oc get vmbackup "$FULL_BACKUP_NAME" "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o yaml
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml
oc exec -n "$NAMESPACE" "$LAUNCHER_POD" -c compute -- \
  virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree
oc logs -n "$NAMESPACE" "$LAUNCHER_POD" -c compute
```
