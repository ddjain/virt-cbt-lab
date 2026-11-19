# CBT-T-04 scenario spec — HPP pool free-space floor sweep (krknctl pvc-scenarios)

## Objective

Find the breaking point and degradation point of a CBT full+incremental backup
cycle as the hostpath-provisioner (HPP) pool free space on the KubeVirt node
shrinks, versus a no-chaos baseline. "Node resource limit" = the HPP pool device
`/dev/sdb` (xfs, `/var/hpvolumes/csi`, 1598959976448 B ≈ 1489 GiB) on node
`d38-h18-000-r660` — the single HPP node hosting the VM root disk and all
backup destination PVCs for this workflow.

## Corrected sizing math (supersedes jira-issue.md)

Measured on this cluster (planning phase du on the node, rhel9
`MANIFEST_VARIANT=large`):

- Full backup qcow2 = **~80 GiB allocated** (the backup preallocates to root
  disk size; apparent == allocated), not the Jira's "~60 GiB".
- Incremental PVC ≈ 18 GiB; guest mutation before it adds ~17.5 GiB to the root.
- Full+incremental cycle ≈ **135 GiB** pool consumption (setup root DV ~19 GiB
  included in per-leg baseline); full-only run ≈ 100 GiB.

Consequences:

- The Jira's 100/60/40 GiB sweep legs were replaced (100 is an incremental
  boundary, not a full boundary).
- Predicted — and measured — thresholds: full backup needs ~80 GiB free;
  full+incremental needs ~115 GiB free (free measured after `vm-setup`,
  before the full backup, i.e. the floor the fill enforces at backup start).

## Mechanism

- Holder PVC `t04-holder` (1Gi, storageClass `cbt-demo-hpp`) + pod (ubi9,
  `spc_t`, `nodeSelector kubernetes.io/hostname: d38-h18-000-r660`, never
  `nodeName` — WaitForFirstConsumer trap) in namespace `default`.
- `krknctl run pvc-scenarios --namespace default --pvc-name t04-holder
  --fill-percentage <PCT> --duration <FILL_DURATION> --kubeconfig …`
  fills the whole shared pool to `capacity*(1-PCT/100)` (df-based,
  self-adjusting) via `fallocate` of `kraken.tmp` in the holder, and removes
  the file itself after `--duration`.
- **krknctl 99% ceiling**: `--fill-percentage` must be ≤ 99 and > current
  utilization, so the lowest floor krknctl alone can express is ~14.9 GiB.
  The only exception (user-approved): the 5 GiB failure-mode leg fills to
  98.99 (~15 GiB) with krknctl, then tops up with
  `oc exec … fallocate -l <delta> /data/t04-topup.tmp` in the holder.
- Floor→percentage: read `total_kb`/`used_kb` from `df -B 1024 /data` in the
  holder, `PCT = 100*(1 - FLOOR_GIB*2^30 / (total_kb*1024))`, 4 decimals.
- Legs hold the floor through the full backup, the incremental pass, and the
  verify stage (`FILL_DURATION` = 660 s, derived from controls), then release
  the fill files and delete the leg's own resources.

## Workflow legs

Per sweep leg (`t04-leg.sh <RUN> fill <FLOOR_GIB> [topup]`):

1. collision guard; `make vm-setup NAME=<RUN>` with profile overrides on the
   make command line (Makefile `.env` inclusion would override the env);
   launcher must land on d38-h18-000-r660.
2. pre-state capture (launcher pod json, node conditions, co-tenants, holder
   df, dmesg error baseline, diskstats).
3. 3 s sampler (holder avail, node conditions, launcher restarts, VMI phase,
   test-VM + co-tenant PausedIOError, vmbackup Done) and 5 s watchdog
   (ABORT on node NotReady 30 s, DiskPressure=True, launcher restart,
   co-tenant PausedIOError; test-VM PausedIOError before the full's terminal
   state is logged as data, not an abort).
4. krknctl fill; floor verified within ±2 GiB (±1 GiB for the top-up stage)
   before the backup starts (`floor-verified.txt`).
5. `make vm-backup` → if full succeeded, `make vm-cbt-backup` →
   `make vm-cbt-verify` (final lifecycle marker; see success markers).
6. terminal capture (vmbackup yamls, tracker, run.json/summary.json, VMI
   conditions, launcher compute log, events, backup PV dir du, min avail,
   dmesg delta), release fill, delete leg resources by run-id label.

## Measurements

- Full backup duration; incremental duration; setup duration.
- Verbatim vmbackup Done reason; run.json status; tracker latestCheckpoint;
  backup PVC admission (Bound); partial artifact on the destination PV;
  VMI PausedIOError; minimum pool avail during the leg; dmesg error delta.

## Classification

- `FULL_FAIL` — full vmbackup Done=True with a failure reason, or run.json
  `full_failed` (expect `No space left on device`).
- `FULL_OK_INCR_FAIL` — full OK, incremental failed or verification failed.
- `FULL_OK_INCR_OK` — full and incremental succeed and verification passes.
- SLOWED: duration > control MAX + 5 s; DEGRADED: duration ≥ 2× control MEAN.
- Floors assumed monotonic in outcome; contradicting results are repeated
  once (`b` suffix) and both reported.

## Success markers

- Full OK: vmbackup Done=True, reason `Successfully completed
  VirtualMachineBackup`; run.json `backups.full.done_reason` carries it.
- Incremental OK: same Done reason on `vm-incremental-<RUN>-p01`, all 5
  vm-cbt-backup stage checks ✓.
- Lifecycle OK (user decision, 2026-11-15): `make vm-cbt-verify` rc 0 and
  run.json status `complete`. (The pipeline sets `verification_pending` after
  the final incremental; verify must run while the VM exists, hence it is
  part of every leg, before the approved per-leg cleanup.)

## Floor selection (executed)

Initial legs 160, 100, 60; bisect transitions A (FULL_FAIL→FULL_OK) and B
(INCR_FAIL→INCR_OK) to a bracket ≤3 GiB or the 12-leg cap; one mandatory
5 GiB failure-mode leg (top-up).
