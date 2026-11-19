# CBT-X-04 scenario spec — storage I/O pressure + launcher kill during active full-backup copy

Source: Jira `jira-issue.md` (no prior spec existed; drafted from run 20261114-cbtx04-r01 and its plan).

## Failure mode

Combined fault on the full-backup copy: sustained node-local I/O pressure on the CBT storage filesystem (HPP pool) plus a force-kill of the backup-executing virt-launcher pod ~20 s after the load begins, both inside the active copy window. Expected: the backup fails cleanly (terminal Done=True with a real failure reason), the tracker does not advance, the VM recovers automatically, and a subsequent clean full+incremental+restore cycle works (recovery leg, on request).

## Legs

| leg | run | profile | chaos | expected |
|---|---|---|---|---|
| control | `20261114-cbtx04-r01ctl` | rhel9 / HPP default manifests | none | full backup PASS (measured: 53 s copy, 55 s stage) |
| chaos | `20261114-cbtx04-r01` | same | node-io-hog 90 s + pod-scenarios launcher kill | full backup fails cleanly; run.json `full_failed` |

## Injection target / action / window

- Target 1 (hog): node `d38-h18-000-r660` (all campaign VMs land there), mount `/var/hpvolumes/csi` (`/dev/sdb`, xfs, 1.5T). `krknctl run node-io-hog --io-workers 8 --io-write-bytes 2g --io-block-size 1m --chaos-duration 90` (16 GiB transient — contention only, not a fill). Trigger: vmbackup `Progressing=True && Done≠True` (copy in progress), 3 s poll.
- Target 2 (kill): the victim VM's launcher pod, by `--name-pattern '^<launcher>$'` resolved after vm-setup (NO `--pod-label`). `krknctl run pod-scenarios --force true --kill-timeout 180`. Trigger: backup not Done AND hog container running ≥13 s in `hog-ns-<RUN>` (13 s + ~7 s krkn selection lag ≈ 20 s after load begins), 1 s poll.
- Window: active full-backup copy (`make vm-backup`). Control copy window must be ≥35 s before planning (measured 53 s).

## Measurements

- Control: copy duration, "Backup started" launcher log timestamp, Done lastTransitionTime, dest pool df.
- Chaos: trigger satisfaction timestamps (krknctl logs), hog pod hostPath assertion on the live pod spec (must be `/var/hpvolumes/csi`, not `/tmp` — CBT-EXP-09 bug), `Force deleting pod <launcher>` line (must equal pre-chaos target), kill offset from hog container start (band 17–25 s), failure reason string, tracker latestCheckpoint before/after, launcher uid before/after, VMI phase, agent connection, hotplug pod absence, node Ready, hog residue files on the pool.

## Classification

- **RESILIENT**: backup fails cleanly (Done=True with a real failure reason, no hang), tracker latestCheckpoint null/unchanged, no checkpoint recorded on the failed backup, no orphan hotplug/attachment pod, VM recovers (Running, new launcher uid, agent connected, CBT Enabled), node Ready, no leftover hog residue after capture.
- **DEFECT**: tracker advanced or checkpoint recorded on the failed backup; backup hung (Progressing forever / no Done); orphan attachment; VM not recovered; hog writing to the wrong path (tooling-invalid, do not grade).

## Blast radius

Node `d38-h18-000-r660` pool-disk I/O for 90 s (shared with other campaign VMs on that node, idle during the window); the victim VM's launcher pod only. Cleanup obligation: remove `hog-jobfile.conf`/`output.yaml` from `/var/hpvolumes/csi` after evidence capture; delete `hog-ns-<RUN>`.

## Reference run

`runs/20261114-cbtx04-r01/` — RESILIENT (see `run-report.md`). Failure reason found: "Backup has failed: VMI backup status was lost".
