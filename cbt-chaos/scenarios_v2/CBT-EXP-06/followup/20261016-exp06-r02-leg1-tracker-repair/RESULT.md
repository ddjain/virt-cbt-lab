# Leg 1 — tracker repair: NEGATIVE, and decisive

**Run under test:** CBT-EXP-06 `20261016-exp06-r02` (closed, verdict BLOCKED) ·
**Executed:** 2026-10-16T06:35:26Z–06:56:07Z (1241 s) · **Driver:**
`cbt-chaos/scenarios_v2/CBT-EXP-06/leg1-tracker-repair.sh` (`bash -n` clean,
`--plan` rehearsal exit 0) · **Human approval:** this leg; delete the wedged CR
(CR only).

## Design

The wedge followed a state in which three layers disagreed: QEMU held a
checkpoint bitmap only on the root disk, the redefined libvirt checkpoint
declared only that disk, and the VirtualMachineBackupTracker still listed both
volumes. If the backup request's disk set came from the tracker, repairing the
tracker to match the checkpoint should let a new pass complete — and if that pass
completed with `includedVolumes` omitting the datadisk, it would be the terminal
form of the silent per-disk protection loss the experiment hunted.

## What happened

| Step | Observation |
|---|---|
| Pre-state | tracker `volumes=[vda/rootdisk, vdb/datadisk]`; checkpoint XML declares only `<disk name='vda' …>`; QEMU bitmaps: `datadisk=[]`, `rootdisk=['vm-backup-…-04-27-24']` |
| Remove the wedged pass | CR released its finalizer in **3 s**; its PVC kept |
| Patch the tracker | `status.latestCheckpoint.volumes → [vda/rootdisk]` accepted (merge patch on the status subresource), **stable at +0 s and +30 s**, and still `["vda/rootdisk"]` after the leg (`rv 27464802`) — no controller revert |
| New pass `…-p03` | created 06:36:00Z, PVC attached; **WEDGED**: `type` null, zero `Done` conditions, `includedVolumes` empty, finalizer `backup.kubevirt.io/vmbackup-protection` held, stale "attaching its target PVC" reason after 20 min |
| The error | **identical**: `virError(Code=109) checkpoint inconsistent: missing or broken bitmap 'vm-backup-20261016-exp06-r02-2026-10-16_04-27-24' for disk 'vdb'` (06:46:59Z; 38 controller lines in 35 min) |

## What this establishes

1. **The request for the datadisk does not come from the tracker's volume list.**
   With the tracker advertising only `rootdisk`, the backup still names `vdb` and
   fails on the same missing bitmap. The proposed explanation that the tracker's
   stale entry drives the request is **refuted** by this experiment.
2. **The wedge is driven by the checkpoint/bitmap mismatch itself** at the
   libvirt/QEMU boundary, not by tracker metadata. Metadata repair therefore
   cannot restore the VM's backup capability.
3. **The silent vda-only incremental is not reachable** this way: the product
   cannot be made to quietly protect one disk of two by repairing metadata; it
   refuses and wedges. That is a real safety property — and it comes at the cost
   of the availability defect (permanent wedge plus VM-wide deadlock).
4. Combined with the three earlier reproductions, the product picture is now:
   no silent *completed* drop (4 attempts, 2 designs), permanent non-terminal
   wedge with a held finalizer, leaked hotplug mount, empty CR-scoped event
   stream, and a VM-wide backup deadlock while the wedge persists.

## Still open

- The chain-discard escape (finding-1's last matrix row): with the wedged CR
  removed, deleting the tracker should make the next backup a full one — and
  whether that path can also leave the datadisk silently unprotected is the only
  remaining variant. It needs a new ~80 GiB destination PVC; the pool now holds
  **119.97 GiB** free (r02's own 79.72 GiB full-backup PVC was reclaimed at the
  human's direction), so it is feasible but requires its own approval.

## Live state left in place

`…-p03` wedged (a fourth reproduction, snapshotted here); its PVC and the two
earlier incremental PVCs remain `Bound`; the tracker stays repaired at
`[vda/rootdisk]`; the VM/VMI are healthy (Ready, CBT Enabled). Nothing from the
closed run's pack was modified.
