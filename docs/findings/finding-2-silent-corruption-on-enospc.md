# Finding 2: Backup reports success with ~0% of the data when the destination runs out of space mid-copy

**Severity:** Critical (silent data loss) · **Class:** succeeded:false recorded-as-success (kubevirt#17578 class, live-reproduced on shipped CNV 4.22.12) · **Reproducible:** YES — deterministic, 3/3 attempts (r01, r02, r03) · **Ticket:** `cbt-chaos/scenarios_v2/CBT-EXP-07/bugs/backup-reports-success-with-no-data-on-target-enospc.md`

## 1. Summary

When a push-mode backup's destination PVC runs out of space **during** the live copy (after checkpoint creation), the backup completes with `Done=True` and reason **"Successfully completed VirtualMachineBackup"** while the destination contains only a metadata-sized qcow2 **overlay whose backing file is the LIVE VM's source disk** — the copy never ran. The underlying ENOSPC error surfaces nowhere (no condition, no reason, no event text). The tracker then advances onto the empty backup's checkpoint, so subsequent incrementals silently chain off the shell. Worst of all: a restore executed while the VM is alive "succeeds" (reading through the overlay to the running source), so **normal restore verification cannot detect this corruption class** — only the disaster-case restore (VM gone) fails, exactly when the backup is needed.

## 2. Environment

- OpenShift 4.22 / OpenShift Virtualization 4.22.12 (`backup.kubevirt.io/v1alpha1`)
- RHEL 9 VM, 1000-file / 17,431 MiB workload; push-mode backup; HostPath storage class (node-local PV destination on `d38-h18-000-r660`)

## 3. Scenario ID

EXP-7 (adaptive experiment; WeaknessAnalyst proposal P3; upstream anchor kubevirt#17578, closed rotten). Runs:
- `20261014-exp07-r01` — first reproduction (direct-drive)
- `20261014-exp07-r02` — reproduction with workflow-driven lifecycle + chain-propagation proof + disaster-restore
- `20261014-exp07-r03` — the alive-restore triad point

## 4. How chaos was injected

1. **Control leg:** fresh VM → full backup to a normal 80 Gi target — Done/success in 64 s (r01) / 53 s (r02), real data on the destination (86,882 MiB du-inclusive).
2. **Surgery:** a second backup (`vm-backup-enospc-<run>`) with a **4 Gi destination PVC**, pre-filled via node-debug to leave only ~127 MiB free:
   ```
   oc debug node/d38-h18-000-r660 -- chroot /host bash -c \
     "fallocate -l 2600M /var/hpvolumes/csi/<pv>/filler.img"
   ```
   The backup is created **after** the pre-fill (injection-window proof: pre-fill timestamp 20:30:23Z < backup creation). The copy begins (checkpoint creation needs only metadata space), then hits the space wall mid-transfer.

## 5. What was expected (hypothesis)

Per kubevirt#17578: `HandleBackupJobCompletedEvent` keys off the libvirt `DOMAIN_JOB_COMPLETED` event type only and never inspects the job stats' `succeeded` flag — a failed push copy could be recorded as success (Done=True with partial/no data).

## 6. What actually happened (identical across r01/r02/r03 — deterministic)

| Measurement | Result |
|---|---|
| Backup terminal state | **Done=True**, type=Incremental, reason **"Successfully completed VirtualMachineBackup"**, zero warning conditions |
| Copy window | **3 seconds** (control leg: 53-64 s) — physically impossible for 17.4 GiB |
| Destination contents | A **4,456,448-byte (~4.25 MiB) qcow2** — 0.02% of the workload — alongside the pre-existing filler |
| Mechanism | `qemu-img info`: backing file = **`/var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2`** (the LIVE VM's source disk) — an overlay, not a backup |
| Error visibility | ENOSPC text appears **nowhere** (backup object, events, VMI status); the ONLY trace is the ghost Warning event `"Backup has failed: VMI backup status was lost"` |
| Chain propagation | Tracker `latestCheckpoint` **advanced onto the empty backup's checkpoint**; a subsequent workflow incremental was refused only by the HARNESS's checkpoint-match guard — the product raised no objection |

### The restore triad (all live-verified)

1. **Done=True always** — the object claims success.
2. **Restore while VM alive (r03):** `qemu-img convert` of the shell completes in **15.8 s** producing a full-size 79.7 GiB raw image whose first GiB is **md5-identical to the live source disk** (`45268f192734f13ed74d855a43cc23e1`) — the "restore" reads through the overlay to the running VM. Normal restore verification structurally cannot detect the corruption.
3. **Disaster-case restore (VM gone, r02):** `qemu-img convert` fails — `Could not open backing file: ... No such file or directory`. The backup delivers **nothing** exactly when it is needed.

## 7. Reproducibility

**Deterministic: 3/3** (r01, r02, r03 — each independently reproducing Done=True + the 4.25 MiB shell + the 3 s copy window). No flakiness observed; the injection (pre-filled target) is simple and reliable.

## 8. Impact and detection heuristics

- **Silent data-protection loss (worst class):** consumers see a healthy backup chain that contains nothing for this backup; subsequent incrementals chain off the shell.
- No guest impact — the VM stays healthy; the failure is invisible from every standard monitoring surface.
- The only failure trace (the ghost event) also fires on 7/9 healthy completions — customers are trained to ignore it.
- **Operator heuristics until fixed:** (a) a "successful" backup whose duration is implausibly short for the VM's data size (3 s for 17 GiB); (b) backup-destination usage that did not grow proportionally to the workload.

## 9. Recovery

None within the product — the corrupt chain must be manually discarded (delete the tracker; next backup falls back to Full — the verified recovery path from Finding 1's matrix).

## 10. Evidence paths

- `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/20261014-exp07-r01/` — legA/B YAMLs, usage txts, target file listings, trigger.log
- `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/20261014-exp07-r02/` — surgery-backup.yaml (success reason), surgery-target-files.txt (4,456,448-byte qcow2), prefill.txt (window proof), chain-incremental failure (harness guard), observer streams (3 s copy window; tracker advancement)
- `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/20261014-exp07-r03/` — alive-restore-info.txt (backing file = live source), alive-restore-convert.txt (15.8 s read-through), trigger.log (md5 triad point)
- Observer streams (independent witnesses) under each run's `observer/`

## 11. Source anchors and upstream framing

- kubevirt#17578 (closed rotten): `HandleBackupJobCompletedEvent` switches on `DOMAIN_JOB_COMPLETED` type only; job-stats `succeeded` unexamined.
- kubevirt v1.8.4: `pkg/virt-launcher/virtwrap/storage/backup.go` `HandleBackupJobCompletedEvent`; tracker update path in `pkg/storage/cbt/backup.go`.
- **Framing note:** the #17578 *class* is reproduced on shipped CNV 4.22.12. Verify the fix status in kubevirt main before filing — if fixed post-v1.8.4, this becomes a backport request with a live repro attached.
- Related: Finding 3 (the ghost event is the only visible trace of this failure — the observability defects compound).
