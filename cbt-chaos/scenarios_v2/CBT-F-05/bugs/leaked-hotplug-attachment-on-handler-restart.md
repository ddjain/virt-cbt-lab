# CBT-F-05 — Leaked hotplug attachment after virt-handler restart during CBT backup unplug

## Summary

Restarting the node's `virt-handler` pod during the window between a CBT full backup's copy completion and its hotplug unplug leaves the backup volume permanently attached to the VM's node. The backup PVC becomes unusable by any other node (restore/verification workloads hang in Pending with Multi-Attach errors) until an operator manually deletes the orphaned VolumeAttachment and restarts the replacement handler pod. Backup data itself remains valid.

## Environment

- OpenShift 4.22.15, OpenShift Virtualization 4.22.12
- Backup destination: Ceph RBD via `openshift-storage.rbd.csi.ceph.com` (RWX-style hotplug attach, RWO PVC)
- Reproduced by: CBT chaos scenario CBT-F-05, run 20261012-cbtf05-r01 (2026-10-12)

## Steps to reproduce

1. Create a VM with changed block tracking enabled and a multi-gigabyte workload so the full backup copy runs for a measurable window (8 × 1 GiB used).
2. Start a full CBT backup to a dedicated RBD PVC.
3. When the launcher's compute log emits `"msg":"Backup started"` for that backup, delete the `virt-handler` pod on the VM's node (`oc delete pod virt-handler-<pod> -n openshift-cnv --wait=false`).
4. Let the backup complete and the incremental pass run, then attempt any workload that mounts the full-backup PVC on a different node (e.g. the standard restore-verification pod).

## Actual behavior

- The full and incremental backups complete successfully; tracker/checkpoint chain is correct.
- At unplug time (copy end), the replacement handler logs:
  - `failed to remove hotplug disk directory …: device or resource busy` (vm.go:1493)
  - `Marking volume … as unmounted from pod, it can now be detached` (vm.go:500)
- The CSI `VolumeAttachment` object for the backup PV is never deleted (finalizer `external-attacher/openshift-storage.rbd-csi-ceph-com` remains; no deletionTimestamp).
- The replacement handler keeps the block device mounted at its own hotplug-disks path (`/pods/<vmi-uid>/volumes/kubernetes.io~empty-dir/hotplug-disks/<backup-pvc>`, observed as `/dev/rbd7` held by handler PID).
- The Ceph RBD image retains an exclusive-lock watcher; the CSI node plugin's `rbd unmap` retries fail with `Device or resource busy` indefinitely (238 retries observed over ~2 hours).
- Any pod mounting the backup PVC on another node stays Pending: `Multi-Attach error for volume … Volume is already exclusively attached to one node`. The workflow's restore verification failed for this reason (pod Pending 53+ minutes; lifecycle FAIL).

## Expected behavior

The hotplug unplug and CSI detach complete after the handler is replaced: the VolumeAttachment is removed, the device is unmapped, and the backup PVC can be attached by restore workloads on any node without operator intervention.

## Recovery / workaround (verified)

1. Delete the orphaned VolumeAttachment object for the backup PV.
2. Restart the replacement `virt-handler` pod on the VM's node (a fresh handler does not re-establish the stale mount).
3. Result: device unmapped (`/dev/rbdX` gone), Ceph watcher cleared (`rbd status` → `Watchers: none`), backup PVC attachable; re-run restore verification passes.

## Evidence (run 20261012-cbtf05-r01)

- Injection signal: `Backup started` at 19:20:21.821Z; handler deleted mid-copy; full backup terminal 19:21:27Z (68 s).
- Unplug failure at 19:21:27.355Z (handler log lines above).
- VolumeAttachment `csi-43bd21aa…` for PV `pvc-111336f6…` (PVC `vm-backup-pvc-20261012-cbtf05-r01`) attached to node d38-h18-000-r660, stuck from creation 19:20:19Z until manual deletion ~21:20Z.
- Holder identified via host process scan: virt-handler replacement pod process with `/dev/rbd7` mounted at the hotplug-disks path.
- `rbd unmap` EBUSY loop in `csi-rbdplugin` logs on the VM's node; RBD watcher persisted on image `csi-vol-53263947…`.
- Multi-Attach events from 19:23:57Z; restore-verify pod Pending 53+ min; verification re-run after cleanup passed 17/17 checks.
- Control runs (no handler disruption) show no leftover VolumeAttachment on backup PVCs.

## Suggested investigation areas

- virt-handler hotplug unplug retry semantics around `vm.go:1493` (`failed to remove hotplug disk directory`) and `vm.go:500` (`Marking volume … unmounted`): an EBUSY from the still-held CSI globalmount should be retried, not treated as a terminal unmounted state.
- CSI NodeUnstageVolume idempotency when the staging path is held by a restarting consumer (the consumer holding the device open is the handler itself).
- external-attacher detach flow when the VolumeAttachment outlives all pods referencing the volume.

## Impact

- Severity: High — backup volume unusable for restore until manual intervention; silent (backup objects all report success).
- Data loss: none (chain restores correctly after cleanup).
