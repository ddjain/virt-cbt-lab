# [CBT] Incremental backup wedges permanently in Initializing with no terminal condition and no events on the backup CR when the checkpoint bitmap is missing for one disk

## Summary

When a VirtualMachineBackup checkpoint's per-disk dirty bitmap is missing for one of the VM's disks (observed: bitmap removed from the data disk between a full backup and its incremental, with a VMI restart firing the checkpoint redefinition), two product defects combine into a stuck state requiring manual intervention:

1. **Checkpoint redefinition accepts an incomplete checkpoint.** After the VMI restart, the tracker's `latestCheckpoint` still lists both volumes even though one disk's bitmap is gone — the redefinition path does not validate per-disk bitmap presence.
2. **The backup controller livelocks on a permanent error.** Every start attempt for the next incremental fails with a deterministic libvirt 400 (`checkpoint inconsistent: missing or broken bitmap '<checkpoint>' for disk 'vdb'`, virError 109). The controller requeues indefinitely (19 observed retries in 22 minutes with exponential backoff), never setting a terminal condition. The backup CR stays `Initializing=True` with its `backup.kubevirt.io/vmbackup-protection` finalizer, the hotplugged backup-target PVC remains mounted to the VMI, and there is no deadline or max-retry cutoff.

Additionally, all failure events (`BackupError`, 19×) target the **VMI object**, not the failing backup CR — the backup object's own event stream is empty, so CR-scoped monitoring cannot detect the wedge.

## Environment

- OpenShift Virtualization 4.22.12 (kubevirt v1.8.4-era backup implementation, `backup.kubevirt.io/v1alpha1`)
- 2-disk RHEL 9 VM (rootdisk vda + datadisk vdb), push-mode backup, HostPath storage
- Positive backstop (refutes silent corruption): QEMU's checkpoint-consistency check refuses the backup — the defect is the system's RESPONSE to a broken checkpoint (wedge), not silent data loss.

## Reproduction (live-verified 2026-10-14, run 20261014-exp06-r01)

1. Create a 2-disk VM; take a full backup (both disks in `status.includedVolumes`).
2. Remove the checkpoint bitmap from ONE disk via QEMU (`block-dirty-bitmap-remove` on the disk's format node) — verified with `query-block` (rootdisk retains the bitmap, datadisk loses it).
3. Restart the VMI (checkpoint redefinition fires): the tracker's `latestCheckpoint.volumes` still lists both volumes.
4. Request an incremental backup: the CR is created `Initializing` and never becomes terminal; the controller log shows an infinite requeue loop of `failed to send Start backup command: ... 400 ... checkpoint inconsistent`.

## Expected behavior

- The redefinition should detect the missing per-disk bitmap and either invalidate the checkpoint (forcing a clean fallback to full backup — a proven-safe path) or exclude the disk with a warning.
- A deterministic, permanent start failure should terminal-fail the backup CR (releasing the finalizer, detaching the target PVC) instead of retrying forever.
- Backup-start failures should be observable on the backup object's event stream.

## Actual behavior

- Tracker claims both volumes; incremental wedges in Initializing forever; finalizer stuck; target PVC leaked (mounted); 19 BackupError events on the VMI only; zero events on the backup CR.

## Impact

- Availability: the backup chain for the VM is unusable and wedged until manual CR deletion; the leaked hotplug volume stays attached.
- Observability: CR-based monitoring sees a healthy "in progress" backup indefinitely.
- No data corruption: QEMU's checkpoint-consistency check refuses the backup (positive backstop) — the defect is the failure handling, not silent data loss.

## Recovery (verified matrix, 2026-10-14 live on the wedged state)

| Path | Result |
|---|---|
| (a) Delete the wedged backup CR | **WORKS** — finalizer cleared within seconds despite the permanent-error livelock; the leaked hotplug target PVC detached cleanly (VMI volumeStatus cleared) |
| (b) Fresh `forceFullBackup: true` on the same VM (CR deleted first) | **WORKS** — Done=True type=Full in ~20 s; backup capability is NOT permanently destroyed by the broken checkpoint |
| (c) Delete the VirtualMachineBackupTracker, then take a new backup | **WORKS as clean fallback** — tracker deletion is instantaneous (no finalizer/guard); the next backup completes as type=Full (chain silently discarded, no wedge, no error) |

Recommended operator runbook for a checkpoint-inconsistent wedge: delete the wedged backup CR, then either take a force-full backup (fastest) or delete the tracker to reset the chain (both verified). No node-level libvirt intervention is required.

Retry cadence detail for triage: 19 retries observed over ~22 minutes with growing backoff (exponential; not a fixed-interval hammer).

## Evidence

- Run: `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/`
- Wedged CR state: `legB-incremental-backup.yaml` (Initializing=True, finalizer present, no terminal condition, 19:22:30Z → beyond 19:45Z)
- Retry loop: `legB-controller-retry-loop.log` (19× "failed to send Start backup command ... 400 ... checkpoint inconsistent"; requeue lines)
- Bitmap surgery proof: `bitmaps-after.json` (rootdisk bitmap present, datadisk absent), `qmp-remove-result.txt` (`{"return":{}}`)
- Redefinition non-validation: `tracker-after-restart.yaml` (latestCheckpoint volumes = rootdisk+datadisk post-restart)
- Observability gap: `observer/events-incr.jsonl` (backup-object events: EMPTY) vs `observer/events-vm.jsonl` (19 BackupError events on the VMI)
- Control leg (proves 2-disk backup works pre-surgery): `legA-full-backup.yaml` (includedVolumes both disks, Done=True)

## Related scenario / execution

- EXP-6, run `20261014-exp06-r01` (2026-10-14): surgery leg timeline 19:18:25Z (bitmap removal) → 19:21:42Z (redefinition accepts broken checkpoint) → 19:22:30Z (incremental created) → 19:44:24Z (19th retry, e2e timeout, CR still Initializing).
- Source anchors (kubevirt v1.8.4): `pkg/virt-launcher/virtwrap/storage/backup.go` RedefineCheckpoint/findDisksWithCheckpointBitmap (per-disk probing, V(3)-only logging for missing bitmaps); `pkg/storage/cbt/backup.go` start/requeue path (no terminal resolution for permanent start failures).

## Second entry path + deadlock variants (EXP-8, 2026-10-14, run 20261014-exp08-r01)

The same no-terminal-resolution wedge is reachable from a completely different fault: **deleting the backup tracker mid-copy** (operator "cleanup" action).

1. **Wedge (same class, API-side entry):** tracker deleted 15 s after observed copy start (404-verified) → backup stuck Progressing with the controller requeue loop `BackupTracker ... does not exist` — no terminal state, no deadline.
2. **Deletion deadlock (new variant):** deleting the wedged backup CR does NOT clear it when the tracker is gone — the abort path itself requires the tracker (`update backup is deleting` loop); the CR sat with a deletionTimestamp for 35+ minutes (vs seconds when the tracker exists, per the recovery matrix above).
3. **VM-wide capability deadlock (new):** while the wedged CR is stuck, ALL new backups on the VM are rejected: `spec.source: VirtualMachineBackup "..." in progress for source`. One wedged backup = the VM's entire backup capability dead, with no API-only recovery.

**Recovery (verified):** recreating the tracker (re-applying any backup manifest for the VM recreates it) unblocks the abort — the wedged CR then deletes and new backups are accepted.

Evidence: `cbt-chaos/scenarios_v2/CBT-EXP-08/runs/20261014-exp08-r01/` (backup-deletion-stuck.yaml, controller-window.log, recovery-backup.yaml, trigger.log).

**Ticket scope note:** both entry paths (checkpoint bitmap corruption; tracker mid-copy deletion) funnel into the same root cause — no terminal resolution for permanent backup-start/cleanup failures. A single fix (max-retry or deadline → terminal Failed, releasing finalizer and detaching the target PVC) addresses both.
