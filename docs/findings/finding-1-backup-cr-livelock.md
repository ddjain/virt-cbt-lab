# Finding 1: Backup CR livelocks permanently with no terminal condition — VM-wide backup capability deadlock

**Severity:** High (availability) · **Class:** Wedge / no terminal resolution for permanent failures · **Reproducible:** YES — deterministic, 2/2 attempts (per entry path) · **Tickets:** `cbt-chaos/scenarios_v2/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md` (merged EXP-6 + EXP-8)

## 1. Summary

When a push-mode `VirtualMachineBackup` hits a **permanent, non-retryable failure** (a corrupt checkpoint, a deleted tracker), the backup controller requeues the failed operation forever: the backup CR never reaches a terminal state (`Done`/`Failed`), its finalizer never releases, the hotplugged target PVC stays attached, and — via the one-backup-per-source rule — **every new backup on the VM is rejected**. The VM's backup capability is completely dead until an operator intervenes. Two independent fault entry paths were reproduced, both funneling into this same root cause.

## 2. Environment

- OpenShift 4.22 (cluster 4.22.1531), OpenShift Virtualization 4.22.12 (kubevirt v1.8.4-era `backup.kubevirt.io/v1alpha1`)
- RHEL 9 VMs, push-mode backup, HostPath storage pool (node-local disk) on node `d38-h18-000-r660`
- Workload: 1000 files / 17,431 MiB (deterministic, manifest-hash-verified)

## 3. Entry Path A — corrupt checkpoint bitmap (EXP-6, run `20261014-exp06-r01`)

### Scenario ID
EXP-6 (adaptive experiment; WeaknessAnalyst proposal P1, Judge-ranked highest-EV)

### How chaos was injected

1. Built a **2-disk VM** (rootdisk=vda 80Gi clone + datadisk=vdb 2Gi blank ext4) via a custom manifest carrying density-pool adoption labels/annotations; adopted via `make e2e TYPE=full EXISTING_VM`.
2. **Control leg:** full backup with no disruption — `includedVolumes: [rootdisk, datadisk]`, Done=True/success in 55 s. Proves the 2-disk harness itself is sound.
3. **Surgery:** located vdb's QEMU format node (`libvirt-2-format`, via `query-named-block-nodes` matching `/cbt/datadisk.qcow2`), then removed the full backup's checkpoint bitmap **from vdb only**:
   ```
   virsh qemu-monitor-command <domain> \
     '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"<checkpoint-name>"}}'
   ```
   Fail-closed verification via `query-block` before (bitmap present) and after (rootdisk bitmap retained, datadisk gone) — artifacts `bitmaps-before.json` / `bitmaps-after.json` / `qmp-remove-result.txt`.
4. **Hard-restarted the VMI** (`oc delete vmi`) to fire the checkpoint-redefinition path.

### What was expected (hypothesis)

Per source analysis (`RedefineCheckpoint`/`findDisksWithCheckpointBitmap`): the disk missing its bitmap would be silently excluded from the redefined checkpoint and all subsequent incrementals would complete Done=True **without that disk** — silent permanent data-protection loss.

### What actually happened

- The hypothesized **silent drop did NOT occur** — QEMU's checkpoint-consistency check refuses the backup (positive backstop).
- **Redefinition accepted the broken checkpoint:** the tracker's `latestCheckpoint.volumes` still claimed `rootdisk+datadisk` after restart (no validation of per-disk bitmaps).
- **The incremental wedged:** created 19:22:30Z, stuck in `Initializing=True` ("backup target PVC being attached") forever. Every start attempt failed with the deterministic libvirt 400 `checkpoint inconsistent: missing or broken bitmap '...' for disk 'vdb'` (virError 109). **19 retries in 22 minutes** with exponential backoff, no terminal condition, stuck finalizer `backup.kubevirt.io/vmbackup-protection`, leaked hotplug-mounted target PVC (VMI volumeStatus showed it `MountedToPod` throughout).
- **Observability gap:** all 19 `BackupError` events targeted the **VMI object**; the backup CR's own event stream was completely EMPTY — CR-scoped monitoring sees a healthy "in progress" backup indefinitely.

### Reproducibility

Deterministic on first attempt (1/1). Every step of the causal chain independently captured (watch streams, controller retry log, QMP fail-closed proofs).

## 4. Entry Path B — tracker deleted mid-copy (EXP-8, run `20261014-exp08-r01`)

### Scenario ID
EXP-8 (adaptive; WeaknessAnalyst proposal P2-r1, Judge-confirmed compact design)

### How chaos was injected

1. Fresh single-disk VM + full backup via the workflow's own manifest.
2. Watcher polled the backup at 1 s; on **observed** `Progressing=True` (copy start confirmed at 20:48:02Z), held 15 s (mid-copy; copies run ~53 s), then:
   ```
   oc delete vmbackuptracker vm-tracker-20261014-exp08-r01 -n vm-cbt-demo
   ```
   Fail-closed: GET re-checked → 404 verified (`inject-result.txt: tracker-deleted-404-verified`).

### What was expected

Per source (`updateBackupTracker` never re-checks tracker existence after BackupBegin): completion-time tracker patch → 404 → infinite requeue → backup stuck Progressing with no terminal state and no deadline.

### What actually happened

- **Primary wedge reproduced:** backup stuck, no terminal state at the 15-min threshold; controller loop logged `BackupTracker vm-tracker-20261014-exp08-r01 does not exist` + `update backup is deleting`.
- **New variant — deletion deadlock:** deleting the wedged backup CR did NOT clear it — the abort path itself requires the tracker. The CR sat with `deletionTimestamp` 21:03:07Z for **35+ minutes** (vs seconds when the tracker exists).
- **New variant — VM-wide capability deadlock:** while the CR was stuck, ALL new backups on the VM were rejected with `spec.source: VirtualMachineBackup "..." in progress for source`. One wedged backup = the VM's entire backup capability dead, no API-only recovery.

### Reproducibility

Deterministic on first attempt (1/1). Direct controller-log evidence of the 404 mechanism (not inferred).

## 5. Root cause (single fix for both paths)

Push-mode backups have **no terminal resolution for permanent failures**: no max-retry, no deadline. A permanently-failing backup start (or cleanup) requeues forever. A terminal `Failed` (releasing the finalizer, detaching the target PVC) would fix both entry paths simultaneously.

## 6. Recovery matrix (all live-verified on the wedged states)

| Path | Result |
|---|---|
| Delete wedged backup CR (tracker present) | **WORKS** — finalizer cleared in seconds; hotplug PVC detached |
| Delete wedged backup CR (tracker absent) | **WEDGES** — abort needs the tracker (35+ min limbo observed) |
| Fresh `forceFullBackup: true` on same VM | **WORKS** — Done=True type=Full in ~20 s |
| Recreate tracker (re-apply manifest) | **WORKS** — unblocks the stuck abort; CR then deletes |
| Delete tracker, then new backup | **WORKS as clean fallback** — next backup completes type=Full (chain silently discarded) |

**Operator runbook:** for a checkpoint-inconsistent wedge — recreate/ensure the tracker exists, delete the wedged CR, then take a force-full (or delete the tracker to reset the chain). No node-level intervention required.

## 7. Evidence paths

- `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/` — legA-full-backup.yaml (control), bitmaps-before/after.json, qmp-remove-result.txt, tracker-after-restart.yaml, legB-incremental-backup.yaml (wedged state), legB-controller-retry-loop.log (19× 400 + requeues), legB-events.txt, followup-{a,c}-*.log (recovery legs)
- `cbt-chaos/scenarios_v2/CBT-EXP-08/runs/20261014-exp08-r01/` — inject-result.txt, backup-final.yaml, backup-deletion-stuck.yaml, controller-window.log ("does not exist" / "update backup is deleting"), recovery-backup.yaml, trigger.log
- Observer streams (independent injection witnesses) under each run's `observer/`

## 8. Source anchors (kubevirt v1.8.4)

- `pkg/virt-launcher/virtwrap/storage/backup.go` — `RedefineCheckpoint` / `findDisksWithCheckpointBitmap` (per-disk probing; missing bitmaps logged at V(3) only; `isCheckpointInvalidError` fires only when ZERO disks match)
- `pkg/storage/cbt/backup.go` — start/requeue path (no terminal resolution for permanent start failures); `updateBackupTracker` (no not-found tolerance)
