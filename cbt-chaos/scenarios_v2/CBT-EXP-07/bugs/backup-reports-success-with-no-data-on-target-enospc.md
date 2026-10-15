# [CBT] Backup reports success with ~0% of the data when the destination runs out of space mid-copy (failed push job recorded as success; chain advances onto the empty backup)

## Summary

When a push-mode VirtualMachineBackup's destination PVC runs out of space during the live copy (after checkpoint creation), the backup completes with **Done=True and reason "Successfully completed VirtualMachineBackup"** while the destination contains only a metadata-sized qcow2 shell — in the reproducer, **4,456,448 bytes (≈4.25 MiB) against a 17,431 MiB workload (0.02%)**. The copy "window" was 3 seconds (a real copy of this workload takes 64 s). The underlying ENOSPC error never surfaces in the backup object's conditions, reason, or events — the only failure trace is the misleading Warning event `VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` fired at the same instant.

Compounding the corruption: the tracker's `latestCheckpoint` **advances to the empty backup's checkpoint**, so subsequent incremental backups silently chain off a 4 MiB shell.


**Mechanism (r02, live-verified):** the "successful" backup is a qcow2 overlay whose BACKING FILE is the LIVE VM's disk (`/var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2`). The copy never ran — the target holds only the overlay metadata. A restore against a deleted/sourceless VM (the disaster scenario a backup exists for) fails with `Could not open backing file` — the backup restores NOTHING.

## Environment

- OpenShift Virtualization 4.22.12 (kubevirt v1.8.4-era backup implementation, `backup.kubevirt.io/v1alpha1`)
- RHEL 9 VM, 1000-file / 17,431 MiB workload; push-mode backup; HostPath storage class (node-local PV destination)

## Reproduction (live-verified 2026-10-14, run 20261014-exp07-r01)

1. Take a normal full backup (control): Done/success in 64 s, real data on the destination (86,882 MiB with PV overhead).
2. Create a second backup with a 4 Gi destination PVC pre-filled to ~127 MiB free (single fallocate filler file).
3. The backup starts normally (checkpoint creation needs only metadata space), the copy hits the space wall, and the backup reaches Done=True / "Successfully completed VirtualMachineBackup" in **3 seconds**.
4. The destination contains only the 4.25 MiB qcow2 header; the tracker advances to this backup's checkpoint.

## End-to-end restore evidence (r02 reproduction, 2026-10-14)

- Reproduced with a workflow-driven lifecycle: control full (53 s, real data) → surgery backup on the pre-filled 4 Gi target → **Done=True "Successfully completed VirtualMachineBackup"** again; target again holds the 2,726,297,600-byte filler + a **4,456,448-byte qcow2**; pre-fill timestamp (20:30:23Z) recorded BEFORE backup creation (injection-window proof).
- `qemu-img info` on the shell: `virtual size 79.7 GiB, disk size 7.94 MiB, backing file: /var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2` — an overlay pointing at the LIVE SOURCE disk, not a standalone backup; the copy never ran.
- **Disaster-case restore attempt** (backing file absent, as after VM loss): `qemu-img convert` fails — `Could not open backing file: ... No such file or directory`. The backup is unrestorable exactly when it is needed.
- **Restore-while-alive (r03):** with the VM still running and the backing file reachable, `qemu-img convert` of the shell completes in **15.8 s** and produces a full-size 79.7 GiB raw image whose first GiB is byte-identical (md5 match) to the live source disk — the "restore" simply reads through the overlay to the running VM's disk. **Normal restore verification cannot detect this corruption class while the VM lives; only the disaster case fails — exactly when the backup is needed.**

## Expected behavior

- The failed copy terminal-fails the backup CR with the real reason (e.g. "No space left on device").
- The tracker does not advance from a failed copy.

## Actual behavior

- Done=True with a pure success reason; zero warning conditions on the CR.
- No ENOSPC text anywhere (object, events, VMI status); only the generic "VMI backup status was lost" Warning event.
- Destination: 0.02% of the workload; chain advanced onto the empty backup.

## Impact

- **Silent data-protection loss (worst class):** consumers see a healthy backup chain that actually contains nothing for this backup; every subsequent incremental chains off the shell.
- No guest impact (VM stays healthy) — the failure is invisible from every standard monitoring surface.
- The only operator-visible signal is a Warning event that reads as a benign completion race ("status was lost"), which customers are trained to ignore because it also fires on healthy completions.

## Recovery

None identified within the product — the corrupt chain must be manually discarded (delete the tracker; next backup falls back to Full — verified as the recovery path for chain corruption in the companion EXP-6 finding). Detection heuristic for operators: a "successful" backup whose duration is implausibly short for the VM's data size, or whose destination usage did not grow proportionally.

## Evidence

- Run: `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/20261014-exp07-r01/`
- Success-with-no-data: `legB-backup.yaml` (Done=True, "Successfully completed VirtualMachineBackup", type=Incremental) vs `legB-target-files.txt` (qcow2 = 4,456,448 bytes) and `legB-target-usage-mib.txt` (2,608 MiB total incl. the 2,600 MiB pre-existing filler)
- 3-second copy window: `observer/surgery-backup.jsonl` (Progressing→Done within 20:10:53Z) vs control 64 s (`legA-full-backup.yaml`); `observer/vmi.jsonl` backupStatus start/end 20:10:50→20:10:53
- Error swallowed: absence of ENOSPC text across `observer/surgery-backup.jsonl`, `observer/events-surgery.jsonl`, `observer/vmi.jsonl`; the ghost Warning event at 20:10:53Z
- Chain corruption: `observer/tracker.jsonl` (latestCheckpoint advanced to the surgery backup's checkpoint)
- Control leg (proves the harness path): `legA-full-backup.yaml`, `legA-target-usage-mib.txt`

## Related scenario / execution

- EXP-7, run `20261014-exp07-r01` (2026-10-14): control Done 20:10:47Z (64 s, real data) → surgery created 20:10:50Z → Done=True 20:10:53Z (3 s, 4.25 MiB) → tracker advanced.
- Upstream anchor: kubevirt#17578 (`succeeded:false` DOMAIN_JOB_COMPLETED recorded as success; closed rotten without a fix).
- Source anchors (kubevirt v1.8.4): `pkg/virt-launcher/virtwrap/storage/backup.go` `HandleBackupJobCompletedEvent` (event-type-only switch; job-stats `succeeded` unexamined); tracker update path in `pkg/storage/cbt/backup.go`.
- Companion finding: EXP-6 (`bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md`) — the same "VMI backup status was lost" ghost event masks that defect's real cause too; both tickets should reference the event-masking issue.
