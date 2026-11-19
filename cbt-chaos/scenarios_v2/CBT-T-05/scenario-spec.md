# CBT-T-05 scenario spec — mixed-storage resilience (VM disk and backup destination on separate storage)

## Objective

Follow-up to CBT-T-04 (HPP-only): prove whether separating the VM root disk
from the backup destination contains the storage-starvation blast radius, and
measure the minimum safe backup-destination PVC sizing on quota-enforcing
storage (ODF/Ceph RBD).

## Variants (repo change, this campaign)

Two new `MANIFEST_VARIANT` values registered in `scripts/common.sh`, with
manifests under `manifests/`:

- `hpp-odf`: VM root on `cbt-demo-hpp` (node d38-h18-000-r660 local pool),
  full+incremental backup destinations on `ocs-storagecluster-ceph-rbd`.
- `odf-hpp`: VM root on `ocs-storagecluster-ceph-rbd`, backup destinations on
  `cbt-demo-hpp`.
- `FULL_BACKUP_DISK_SIZE_OVERRIDE` env/make override added for sizing sweeps
  (variant default remains 90 Gi ODF-dest / 80 Gi HPP-dest for rhel9).


## Test matrix

| ID | Config | Knob | Proves |
|---|---|---|---|
| A0-full | large-odf | dest PVC request 79–84 Gi | minimum full-backup dest margin |
| A0-incr | large-odf | INCREMENTAL_PVC_SIZE 17–19 Gi | minimum incremental dest margin |
| A-ctl | hpp-odf | none | mixed combo works end-to-end |
| A2 | hpp-odf | HPP floor ~2 GiB, no backup in flight | VM-side pause + recovery behavior |
| A3 | hpp-odf | HPP floor 25 GiB held through cycle (+dest sizing) | independent failure domains |
| B-ctl | odf-hpp | none | reverse combo works end-to-end |
| B1 | odf-hpp | HPP floor 60 GiB during full backup | backup fails, VM untouched |
| B1i | odf-hpp | HPP floor 95 GiB (full passes, incr starved) | incremental fails, VM untouched |
| OPT-Ceph | hpp-odf | Ceph pool-level drain | not executable as designed — pool has ~25 TiB max-avail; quota-level ENOSPC governs (see report) |
| del5 (addendum) | large-odf | 8 GiB guest-written then fully deleted before incremental | since-deleted blocks ARE copied (artifact 8.2 GiB vs 0.17 GiB live delta) |
| mw1 (addendum) | large-odf | 5 GiB written in 3 sets, half deleted before incremental | partial delete/multi-write: artifact = union of blocks written (5.2 GiB) |

## Measurements and grading

- Full/incremental success: Done reason + run.json status `complete`
  (vm-cbt-verify before per-leg cleanup), never exit codes alone.
- VM health: VMI `PausedIOError` condition, sampler pause transitions,
  agent connectivity, self-resume timing from virt-launcher logs.
- Ceph health: `HEALTH_OK` sampled every 3 s; abort on any deviation.
- Artifact sizes: `du` via a helper pod mounting the destination PVC.
- Per-leg cleanup by run-id label; watchdog abort policy as T-04.
