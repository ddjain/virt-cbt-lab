# make e2e VM_OS=rhel9 — timing profile and improvement plan (2026-10-15)

Profiled run 20261015091633-silent-wolf-4eb4 on cloud05 (rhel9, MANIFEST_VARIANT=large-odf, 1000 base + 1000 incremental files @ 15-20 MiB, 1 incremental pass). Verdict: PASS, 572s wall. Produced by three parallel agents: TimingMonitor (ran make e2e, extracted workflow.log step timings), StepObserver (namespace-wide oc get -w watches on VM/VMI/DV/vmbackup for sub-step timings), PerfAnalyst (baseline vs 4 prior large-odf rhel9 runs + ranked improvements). Consolidated 2026-10-15.

---

# Part 1 — Run info

# E2E Run Info — rhel9

- run_id: 20261015091633-silent-wolf-4eb4
- vm_name: vm-20261015091633-silent-wolf-4eb4
- namespace: vm-cbt-demo
- os_profile: rhel9, manifest_variant: large-odf
- make e2e start (this run): 2026-10-15T09:16:29Z (UTC)
- Note: a first launch attempt at 2026-10-15T09:14:09Z aborted in 0s due to a checkout e2e lock held by a prior run (20261015-cbtf04-r03, PID 1438733, full backup only, INCOMPLETE). Relaunched at 09:16:29Z after that run finished; run dir 20261015091633-silent-wolf-4eb4 created 09:16:33Z.

---

# Part 2 — Step and sub-step timing

# E2E RHEL9 Timing Profile — 20261015091633-silent-wolf-4eb4

## Run identity
- run_id: 20261015091633-silent-wolf-4eb4
- vm_name: vm-20261015091633-silent-wolf-4eb4 (namespace vm-cbt-demo, os_profile rhel9, variant large-odf)
- make e2e start (UTC): 2026-10-15T09:16:29Z (relaunch; see note)
- Final verdict logged: 2026-10-15T09:26:08Z
- Total elapsed (per e2e banner): 9m 34s (574s)
- make e2e process gone (terminal): confirmed 2026-10-15T09:29:51Z; make reported "Total elapsed: 9m 34s"

Note: a first launch attempt at 2026-10-15T09:14:09Z aborted in 0s with "Another E2E operation is active in this checkout (PID 1438733)" — a pre-existing run (20261015-cbtf04-r03) held the lock. Relaunched at 09:16:29Z once free.

## Step timings (verbatim from runs/20261015091633-silent-wolf-4eb4/logs/workflow.log)
```
[2026-10-15T09:18:20Z] [make] Step timing: VM setup and baseline workload elapsed_seconds=105.
[2026-10-15T09:19:39Z] [make] Step timing: Full backup elapsed_seconds=79.
[2026-10-15T09:21:55Z] [make] Step timing: Incremental backup pass 1/1 elapsed_seconds=136.
[2026-10-15T09:26:07Z] [make] Step timing: CBT verification and restore test elapsed_seconds=252.
[2026-10-15T09:26:07Z] [make] Step timing: target=vm-cbt-demo elapsed_seconds=572.
[2026-10-15T09:26:08Z] [make] Step timing: target=monitor elapsed_seconds=1.
```

## Final verdict (verbatim)
```
[2026-10-15T09:26:08Z] [make] Final verdict: PASS; lifecycle and restore verification passed; report: /root/virt-cbt-lab/runs/20261015091633-silent-wolf-4eb4/report.json
```
E2E banner: Result ✓ PASS · Type all · Lifecycle 1/1 incremental passes complete · Total elapsed 9m 34s.

## Per-step data transfer details (report.json / workflow.log)
- Baseline workload: 1000 files, 18,277,728,256 bytes (~17.02 GiB, 15–20 MiB/file), captured 09:18:20Z.
- Full backup vm-backup-20261015091633-silent-wolf-4eb4: 79s; backup PVC 80Gi (Bound); checkpoint vm-backup-...-2026-10-15_09-18-20; done "Successfully completed VirtualMachineBackup".
- Incremental pass 1 vm-incremental-...-p01: 136s (backup itself reported done in 19s; rest of step = guest mutation + checkpointing); PVC 30Gi (Bound); 1000 files added + 1 modified; added_payload_bytes 18,284,019,712 (~17.03 GiB); totals after pass: 2000 files, 36,561,747,968 bytes (~34.05 GiB); captured 09:21:31Z.
- CBT verification & restore test: 252s. Restore-verify pod (rebase each pass onto preceding checkpoint + hash full-only and cumulative disks) ran ~250s of pod runtime (Running 09:21:57→09:26:07). Full-only restore matched 1000 files / 18,277,728,256 bytes / manifest sha256; incremental prefix matched 2000 files / 36,561,747,968 bytes / manifest sha256. All checks passed.
- Effective backup throughput: full ≈ 18.28 GB/79s ≈ 231 MiB/s; incremental backup transfer ≈ 18.28 GB/19s ≈ 962 MiB/s (CBT only copies changed blocks); verification dominated by restore-verify pod (~250s), not backup.

## Wall-time breakdown (sums ≈ 572s target time)
- VM setup + baseline workload: 105s (18%)
- Full backup: 79s (14%)
- Incremental backup pass: 136s (24%)
- Verification + restore test: 252s (44%)
- monitor + tail: ~2s

---

# Part 3 — Improvement plan

# `make e2e VM_OS=rhel9` — wall-clock profile and ranked improvement plan

Analyzed by PerfAnalyst on 2026-10-15. Live run: **20261015091633-silent-wolf-4eb4** (`make e2e VM_OS=rhel9`, MANIFEST_VARIANT=large-odf, 1000 base files @ 15–20 MiB, 1 incremental pass) — finished PASS at 09:26:08Z, total wall ≈ **575 s**. All evidence below cites `runs/<id>/logs/workflow.log` line numbers (format `[timestamp] [component] [level] message`) on cloud05:/root/virt-cbt-lab, plus script/manifest locations in the repo checkout.

Note: the shared timing artifacts (`local://e2e-run-info.md`, `local://e2e-rhel9-timing.md`) were never populated by peers, so all timings below were derived directly from the authoritative `workflow.log` timestamped lines and `Step timing:` lines on cloud05.

---

## 1. Baseline table — steps vs elapsed seconds

Step elapsed values are the `[make] Step timing:` lines each target writes into `runs/<id>/logs/workflow.log` (Makefile `run_timed_step`, Makefile:78–88). All runs are rhel9 + large-odf, 1000 baseline files @ 15–20 MiB (17,277,728,256 B ≈ 17.4 GiB payload), 1 incremental pass of 1000 files (verified via each run's `workload-manifest.json`).

| Step | **Live: 20261015091633-silent-wolf-4eb4** | 20261013-cbtf09-r01 | 20261013-cbtf07-r01 | 20261012-cbtf04-r01 | 20261012-cbtf03-r01 |
|---|---|---|---|---|---|
| vm-setup | **105** | 80 | 82 | 113 | 109 |
| vm-backup (full) | **79** | 70 | 55 | 69 | 76 |
| preflight | **2**¹ | 1 | 2 | 1 | 1 |
| vm-cbt-backup (incremental pass) | **136** | 120 | 116 | 142 | 142 |
| vm-cbt-verify (+restore test) | **252** | 217 | 230 | 299 | 256 |
| monitor | **1** | 1 | 0 | 1 | 0 |
| **Total (sum)** | **≈575** | 489 | 485 | 625 | 584 |

¹ Live run's preflight ran inside e2e-stage before vm-cbt-demo; `Step timing: target=vm-cbt-demo elapsed_seconds=572.` (silent-wolf workflow.log:143) covers setup→verify; +monitor 1 s +stage overhead ≈ 575 s wall (09:16:33→09:26:08).

Outlier note: 20261015-cbtf04-r02 (same variant) shows vm-setup 116 / preflight 2 / vm-cbt-backup 143 / vm-cbt-verify 256 but its vm-backup step stretched 06:48:48→07:10:16 (~1288 s wall) while the vmbackup object itself reports Done in 67 s (monitor line, r02 workflow.log:137–138) and a `run.json.pre-repair-20261015T070811Z` file exists — i.e. a mid-run manual repair/stall, not steady-state cost. Excluded from the baseline medians but flagged in §4.

Where the live 575 s goes (derived in §2): restore-verify pod ≈ **250 s (43%)**, guest mutation ≈ **111 s (19%)**, full-backup copy ≈ **79 s (14%)**, baseline file write ≈ **68 s (12%)**, VM boot ≈ **36 s (6%)**, incremental-backup copy ≈ **19 s (3%)**, everything else ≈ **12 s (2%)**.

---

## 2. Sub-step cost attribution (from log timestamps, not guessed)

### vm-setup — 105 s (silent-wolf workflow.log:18,33,34)
- Steps 1–3/5 (DataSource read, guest key, `oc apply` of VM/DV/service): 09:16:35→09:16:36 ≈ **1 s**.
- Step 4/5 VM boot & CBT (`oc wait vm ... --timeout=20m`, vm-setup.sh:83–84): 09:16:36→09:17:12 = **36 s** (workflow.log:16→18).
- Step 5/5 baseline workload (1000 files, 17.4 GiB): 09:17:12→09:18:20 = **68 s** (workflow.log:18→33). Inside the guest this is `yes "CBT-WORKLOAD-V1:<name>" | head -c <size>` per file (vm-setup.sh:121, serial loop) **plus** a full re-read of every file for `sha256sum` FILE_RECORDs (vm-setup.sh:131–137). So ≈17.4 GiB written + 17.4 GiB re-read single-stream.

### vm-backup — 79 s (silent-wolf workflow.log:48,55)
- Step 1/4 apply: <1 s. Step 2/4 wait for Done: **79 s**, and this is pure data copy: the backup's own Done duration (creationTimestamp→lastTransitionTime, measured by monitor.sh:78–88) equals the step elapsed (79 s vs "Backup completed · 79s", workflow.log:48). No poll-wait overhead is hidden here — `oc wait` is watch-based (common.sh:842) and the signature watcher (common.sh:730–824) only polls for heartbeats. This is the KubeVirt live copy of ~18 GiB allocated blocks on ocs-storagecluster-ceph-rbd (manifests/full-backup-large-odf.yaml:18; disk 80 Gi per common.sh:125).

### vm-cbt-backup (pass 1) — 136 s (silent-wolf workflow.log:69,77,90,97)
- Step 1/5 checkpoint confirm (re-`wait` full backup + tracker check, vm-cbt-backup.sh:64–100): 09:19:39→09:19:40 ≈ **1 s**.
- Step 2/5 mutate guest: 09:19:40→09:21:31 = **111 s**, split:
  - Pre-mutation inventory re-verification: first `guest_ssh` reads+sha256s all 1000 existing files (17.4 GiB) and compares to manifest — 09:19:40→09:20:06 = **26 s** (workflow.log:64→69; the before-records path in vm-cbt-backup.sh:189–193).
  - ~4 s gap: port-forward teardown/setup + probe for the **second** `guest_ssh` invocation (two separate sessions; common.sh:636–716 rebuilds `oc port-forward` + SSH probe each call).
  - Write 1000 new files (17.1 GiB) + modify 1: 09:20:06→09:21:31 ≈ **81 s** (workflow.log:69→77).
- Step 3/5 apply incremental backup resources: <1 s.
- Step 4/5 incremental backup copy: **19 s** (workflow.log:90 — "Incremental backup completed · 19s", again equal to the vmbackup's own Done duration).
- Step 5/5 checkpoint validation + tracker advance: 09:21:51→09:21:55 = **4 s** (vm-cbt-backup.sh:420–433; `wait_for_checkpoint_in_tracker` polls at 1 s ×≤20, vm-cbt-backup.sh:47–62).

### vm-cbt-verify — 252 s (silent-wolf workflow.log:122,132,142)
- Steps 1–3/4 (read CBT state, backup statuses, checkpoint-chain validation): 09:21:55→09:21:56 ≈ **1 s**.
- Step 4/4 restore test: **251 s**, essentially all inside the restore-verify pod (workflow.log:122→132):
  - Pod created 09:21:57, container started 09:22:05 (oc: `.status.containerStatuses[0].state.running.startedAt`) → **8 s** scheduling/image-pull.
  - **~242 s of pod runtime**, which per manifests/restore-verify-pod.yaml command is: `qemu-img convert` full qcow2→raw into an emptyDir (~18 GiB alloc write), mount + `sha256sum` of 1000 files (17.4 GiB read), then for the incremental: `cp` of the incremental qcow2, `qemu-img rebase`, a **second** `qemu-img convert` that re-reads the whole backing chain, and `sha256sum` of 2000 files (34 GiB). The full image is thus read ~3× and ~36 GiB extra raw is written to emptyDir.
- Consistent across runs: restore pod Running 210–270 s before completion (r02: 07:12:41→07:16:55 = 254 s; cbtf04-r01: 19:10:32→19:15:29 = 297 s; cbtf07-r01: 00:16:47→00:20:35 = 228 s).

### Poll-wait vs data-copy summary
Poll loops contribute **<5 s total**: `oc wait` is watch-based; the restore-lib poll is 1 s/iteration (restore-lib.sh:95–101), the backup watcher 2 s (common.sh:823), tracker check 1 s (vm-cbt-backup.sh:57). Everything else is real data movement: guest file writes (17.4+17.1 GiB), guest re-reads (17.4 GiB ×2), Ceph backup copies (18 GiB + 17 GiB), and restore-pod image reads/writes (~70 GiB total I/O).

---

## 3. Ranked improvements

### #1 — Restructure restore-verify pod: mount qcow2 via qemu-nbd instead of convert-to-raw, and inspect full/incremental chains in parallel
- **Evidence**: silent-wolf workflow.log:122→132 (09:21:57→09:26:07, 250 s = 43% of run); manifests/restore-verify-pod.yaml command (`qemu-img convert -f qcow2 -O raw "$full_qcow2" /work/full.raw`, then per-pass `cp` + `qemu-img rebase` + second `convert` + per-file `sha256sum`); pod already runs privileged with `/dev` hostPath (restore-verify-pod.yaml `securityContext.privileged: true`, `host-dev` volume), so `qemu-nbd`/`nbdkit` is usable without new permissions.
- **Estimated saving**: **80–150 s** (~14–26% of run). Basis: the full image is converted to raw (~18 GiB write to emptyDir + re-read), then the incremental chain re-reads the full backing during its own convert; eliminating the raw materialization removes ~36 GiB of pod I/O, and parallelizing the two independent inspections (full-only vs cumulative) hides one behind the other (measured sequential split ≈ 110 s full-only + ≈ 130 s cumulative in the 242 s pod runtime; running concurrently bounds the pair by the longer one).
- **Sketch**: in `manifests/restore-verify-pod.yaml` command block: replace `qemu-img convert ... /work/full.raw` with `modprobe nbd; qemu-nbd --read-only --connect=/dev/nbdX "$full_qcow2"` and run `inspect_workload` against `/dev/nbdXp2` directly (losetup/mount logic in `inspect_workload` already handles partitioned loop devices; nbdkit with a qcow2 plugin is an alternative). Launch `inspect_workload FULL` and the incremental overlay pipeline as two background jobs (`&` + `wait`) since the incremental chain needs only the qcow2 file paths, not the full raw image. Keep the `FULL_QCOW2`/`PASS_NN_*` output keys unchanged so `restore-lib.sh:restore_log_field` and vm-cbt-restore-test.sh parsing are untouched.

### #2 — Drop or lighten the pre-mutation full inventory re-read in vm-cbt-backup step 2
- **Evidence**: silent-wolf workflow.log:64→69 — 26 s to re-read+sha256 all 1000 baseline files (17.4 GiB) immediately after the same pipeline created them minutes earlier; vm-cbt-backup.sh:189–193 (`before_records` ... `workload_manifest_verify_inventory`) is the code path; the check is a defensive consistency guard, not a correctness requirement for the backup itself.
- **Estimated saving**: **20–26 s** (4–5% of run). Basis: the 26 s measured read is single-stream sha256 over 17.4 GiB through the SSH port-forward.
- **Sketch**: add an opt-in variable (e.g. `GUEST_INVENTORY_VERIFY=full|sample|skip`, default `full` to preserve current behavior, documented in `.env.example` per AGENTS.md conventions) consumed in vm-cbt-backup.sh step 2. `sample` verifies a deterministic subset (e.g. every 20th file plus the file that will be modified — the modification target must still be fully verified since it is about to be mutated) via a `workload_manifest_verify_inventory` variant; `skip` trusts the manifest, matching what the restore test re-proves anyway at the end.
- **Tradeoff**: weakens the mid-chain tamper detector between setup and incremental; acceptable for perf runs, keep `full` for chaos/triage runs.

### #3 — Parallelize baseline workload generation and hashing inside the guest
- **Evidence**: silent-wolf workflow.log:18→33 — 68 s for step 5/5; vm-setup.sh:108–138: the guest script generates each file serially (`yes ... | head -c` per file, vm-setup.sh:121) and then re-reads every file serially for `sha256sum` (vm-setup.sh:131–137). Same pattern costs 56–69 s in every baseline run (cbtf07: 00:11:43→00:12:40 = 57 s; cbtf03: 18:44:00→18:45:09 = 69 s).
- **Estimated saving**: **25–40 s** (4–7% of run). Basis: 68 s for ~34.8 GiB of guest I/O ≈ 510 MiB/s single-stream; the RHEL guest has multiple vCPUs and the workload is pipe/CPU-bound, so 4–8 parallel jobs typically yield 2–3×.
- **Sketch**: in vm-setup.sh `guest_setup_command`, replace the serial `for workload_spec` loop with a list piped to `xargs -P"${GUEST_WRITE_PARALLELISM:-4}" -I{} bash -c '...'` (keep the tmp-file + size-check + `mv` pattern for atomicity), and similarly parallelize the FILE_RECORD hashing loop with `xargs -P` into a sorted aggregate (records must be emitted in `LC_ALL=C sort` order before the manifest digest — sort the collected records, not the traversal). Default parallelism 1 preserves current behavior; expose `GUEST_WRITE_PARALLELISM` in `.env.example`.

### #4 — Reuse one guest SSH session for verify-then-mutate (and across passes)
- **Evidence**: silent-wolf workflow.log:69→77 shows a ~4 s gap between the inventory-verify `guest_ssh` and the mutation `guest_ssh`; common.sh:636–716 rebuilds `oc port-forward`, probes SSH, and tears down on **every** invocation (two invocations per incremental pass; vm-setup and each pass also each pay it once).
- **Estimated saving**: **4–8 s** per incremental pass (~1%). Basis: measured 4 s gap ×2 sessions in the live run; port-forward setup+probe is 1–2 s each (workflow.log:66→68).
- **Sketch**: add a `guest_ssh_session_begin`/`guest_ssh_session_end` pair in common.sh that keeps `forward_pid`/port in globals with a trap-based cleanup, and let vm-cbt-backup.sh steps 1–2 (and multi-pass loops) share one session. Alternatively, merge the verify and mutate commands into a single `guest_ssh` call when the mutation plan is fully determined before invocation (it is — `workload_file_plan` output is precomputed at vm-cbt-backup.sh:195–198).

### #5 — Pre-pull / pre-cache the restore-helper image
- **Evidence**: live run pod created 09:21:57, container started 09:22:05 (oc `.status.containerStatuses[0].state.running.startedAt`) — **8 s** of scheduling+pull for `quay.io/rh-ee-darjain/cbt-restore-helper:latest-windows-ntfs-20261001` before any work starts.
- **Estimated saving**: **~8 s** (1.4%). Basis: measured create→started delta.
- **Sketch**: since every run schedules the restore pod fresh, either pin a digest and rely on node caching (the 31-node cluster makes cache hits node-dependent), or add an optional `make prefetch-helper` step / pre-pull DaemonSet in the namespace before vm-cbt-verify; `RESTORE_HELPER_IMAGE` is already env-driven (restore-lib.sh:11–17).

### Not worth doing (measured, for the record)
- **Poll-interval trims**: `oc wait` is watch-based; the 1–2 s poll loops (restore-lib.sh:101, common.sh:823, vm-cbt-backup.sh:57) bound added latency by one interval each — total <5 s across the whole run. Trimming them buys ≤2 s and costs log heartbeat granularity.
- **Shrinking the full/incremental backup copy windows (79 s + 19 s)**: see §4 — the sizing is deliberate.

---

## 4. Risks and constraints

- **The large-odf sizing is deliberate — do not shrink data to go faster.** AGENTS.md:71 (cloud05:/root/virt-cbt-lab/AGENTS.md) documents that the large variant exists precisely to produce a long-enough *live backup-copy window* for chaos scenarios that must land mid-copy ("Need a longer live backup-copy window (e.g. for a chaos scenario that must land mid-copy)?"). The 79 s full / 19 s incremental copy windows are the product feature; recommendations #1–#5 all preserve data volumes and only attack *verification and guest-side* overhead, which sits outside the chaos-injection window.
- **#1 (qemu-nbd) changes the restore-verification mechanism itself.** Risk: qcow2-on-NBD read paths differ subtly from convert-to-raw (refcount/cluster-boundary behavior, XFS on RHEL vs ext4 on Debian vs NTFS on Windows — restore-lib.sh:3–5 documents all three). The manifest digest comparison (file name/size/sha256 aggregate) is a strong end-to-end check, but keep convert-to-raw available as a fallback mode (env-gated) until qemu-nbd has passed a few full runs. Also verify `/dev/nbd*` is usable inside the privileged container on this cluster (hostPath `/dev` is already mounted).
- **#2 weakens a tamper/consistency check** between setup and incremental. For chaos-injection and triage runs (the cbtf*/cbti* families), keep `full` verification; the `sample`/`skip` modes should be opt-in for perf-focused runs only.
- **#3 increases guest CPU/IO concurrency**, which slightly perturbs the environment a chaos scenario observes during setup. Default to parallelism 1 and opt in per run type; the deterministic content pattern (`CBT-WORKLOAD-V1:<name>`) is unaffected by ordering, but the FILE_RECORD aggregation must remain sorted or manifest sha256 values change and old manifests won't validate.
- **Parallel restore inspection (#1) doubles peak pod I/O** against the same Ceph RBD PVs; on a busy cluster this could lengthen rather than shorten wall time — measure with `scripts/monitor.sh` and the pod log timestamps before adopting.
- **The vm-backup stall in 20261015-cbtf04-r02** (vm-backup step ~1288 s wall vs 67 s actual backup Done; `run.json.pre-repair-20261015T070811Z` present) is a separate reliability issue in the wait/watcher path (common.sh:827–850) worth a ticket of its own — it dwarfs every optimization here when it triggers, but it is not steady-state cost and was excluded from the baseline medians.
- **Cluster noise**: the 5 comparable runs show ±15% total variance (485–625 s) with ~30 VMs from density pools running on the same nodes (oc get vmi -n vm-cbt-demo shows 10+ live VMs); estimates above use within-run measured deltas, not cross-run totals, to stay robust to that.

## Bottom line

Of the live run's ~575 s, only ~100 s (full+incremental backup copies, VM boot) is irreducible product behavior; ~250 s is restore-verification I/O amplification, ~110 s is guest-side write/re-verify, and ~70 s is baseline generation. Improvements #1–#3 alone target **~125–215 s (22–37%)** of savings without touching the deliberate chaos-injection copy windows.
