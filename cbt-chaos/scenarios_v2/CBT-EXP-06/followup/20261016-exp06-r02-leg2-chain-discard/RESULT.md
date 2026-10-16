# Leg 2 — chain discard and capability restore: POSITIVE

**Run under test:** CBT-EXP-06 `20261016-exp06-r02` · **Executed:**
2026-10-16T07:00:16Z–07:01:00Z (44 s) · **Driver:**
`cbt-chaos/scenarios_v2/CBT-EXP-06/leg2-chain-discard.sh` (`bash -n` clean,
`--plan` rehearsal exit 0) · **Human approval:** this leg; clear the wedged
CR/mount (keeping the earliest wedged pass as evidence).

## What happened

| Step | Observation |
|---|---|
| Pre-state | `…-p03` wedged with its hotplug mount attached; tracker (repaired in leg 1) at `volumes=rootdisk`; checkpoint XML declares only `vda`; QEMU: `datadisk=[]`, `rootdisk=[old bitmap]` |
| Cleanup | deleting `…-p03`'s CR released its finalizer in **2 s** and the VMI's hotplug mount list became `[]` |
| Chain discard | tracker deleted (absent confirmed). **QEMU's bitmaps did not change** — the stale root-disk bitmap survives the tracker deletion |
| Recovery | fresh tracker (`spec.source` = the VM) + a new 80Gi destination PVC + a new full backup |
| Outcome | **`type=Full`, `Done=True` 18 s later, `includedVolumes = vda/rootdisk + vdb/datadisk`**; new tracker checkpoint `vm-followup-full-…-f02-2026-10-16_07-00-35` covering both volumes; datadisk gained a **new** QEMU bitmap (the old root-disk one persists alongside it); no hotplug mounts left; VM Ready, CBT Enabled |

The guest-freeze warning (`Code=113`, `/mnt/datadisk` permission denied) appeared
on this **successful** full backup too — confirming again that it is a constant
of this guest and not the wedge's cause.

## What this establishes

1. **finding-1's matrix row is verified for the corrupt-checkpoint path**: with
   the tracker discarded, a recreated tracker plus a fresh backup completes as a
   **full** backup — the chain is silently dropped and the VM's backup capability
   returns.
2. **Protection is restored on both disks** (new per-disk bitmaps, both volumes
   in `includedVolumes` and in the tracker's checkpoint), so the conditional
   protection loss is not permanent.
3. **The operator runbook for this failure class is now fully validated**:
   delete the wedged CR (CR only) → recreate/ensure the tracker → take a fresh
   full. Leg 1 additionally showed that *repairing* the tracker does not help, so
   the tracker must be discarded rather than edited.
4. **The silent-loss hypothesis is closed in the negative across four attempts
   and two designs**: no configuration tested produced a completed backup that
   omitted a disk. The product enforces per-disk protection by refusing to start
   the copy — at the price of the availability defect (permanent wedge with no
   terminal condition, VM-wide deadlock, leaked hotplug mount, CR-scoped event
   stream empty).

## Cost note

The recovery full is a fully allocated ~80 GiB image: the pool went from
119.97 GiB free to 95.96 GiB at the 07:01 read (the image was still filling).
The three incremental PVCs from the wedged passes (`…-p01`, `…-p02`, `…-p03`)
remain `Bound` at ~0 bytes each and are the only r02 artifacts kept beyond the
closed pack's snapshots.
