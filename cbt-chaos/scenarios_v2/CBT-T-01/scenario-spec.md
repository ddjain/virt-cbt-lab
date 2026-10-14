# CBT-T-01…04 — Hog threshold-hunt scenarios (new, campaign-authored)

**Campaign context:** user directive 2026-10-13 — "test the threshold points for cpu hog, memory hog, io hog, storage hog, in such way that cbt backup process degrade or fail". These four scenarios extend the X family with the same triage/E2E workflow. Goal per scenario: sweep the hog intensity until CBT backup **degrades** (measurable slowdown ≥2× baseline or freeze/thaw anomalies) or **fails** (backup terminal-failure, VM pause, OOM), recording the threshold point and the no-effect ceiling for engineering feedback.

## Established baselines (this cluster, rhel9+default/HPP, 1000×15-20MiB)

- Full backup: 52-58s copy (page-cache-absorbed at this scale)
- Incremental: 16-17s
- Node: 112 cores, ~503GiB memory (d38-h18-000-r660, and all worker nodes identical)
- Prior no-effect data points: CPU 32 workers @60% load = no measurable effect (F-10); memory 40% (49GiB) = no effect (X-01); io 8×dsync on SAME device as restore PVCs = +19% on restore only (R-02); io hog on foreign filesystem = no effect (I-04); io 8 workers during full via krknctl (targeting /tmp actually) = +24% (F-09 harness caveat: krkn remapped the mount path).
- Known hard failure independent of hogs: pool ENOSPC (I-04 r01 — VM PausedIOError, backup never completes) — that IS the storage-hog failure mode already evidenced; T-04 quantifies the boundary.

## Sweep design (all runs: full backup in background, hog applied at Progressing-by-type gate, single variable = intensity)

### CBT-T-01 CPU hog threshold
- Mechanism: direct pod, krkn-hub image, HOG_TYPE=cpu, CPU_METHOD=all, DURATION=90, WORKERS = {32@60%, 64, 96, 112 @ LOAD_PERCENTAGE=100} (escalating until degradation/failure; 4 legs max, stop early on degradation)
- Measure: backup duration vs baseline, freeze/thaw duration, VM guest responsiveness (SSH probe), node load
- Degradation criteria: full backup ≥2× baseline (>110s) or Done reason anomaly; failure: backup terminal failure or VM unresponsive

### CBT-T-02 memory hog threshold
- Mechanism: X-01 direct-pod recipe (emptyDir /work copy), VM_BYTES = {50%, 70%, 85%, 95%} WORKERS=4 DURATION=90
- Measure: backup duration, kernel OOM lines, launcher restartCount, OOMKilled containers, VM VMI state
- Failure modes to observe: node-level OOM killing launcher/QEMU vs hog, guest memory pressure, backup stall
- Degradation criteria: measurable slowdown; failure: OOM kill of any CBT-relevant process or backup failure

### CBT-T-03 I/O hog threshold (same-device)
- Mechanism: R-02 direct-pod recipe (dsync hdd workers on /var/hpvolumes/csi — SAME device as backup PVCs), WORKERS = {8, 32, 64} × --hdd-bytes 2g --hdd-write-size 1m, DURATION=90
- NOTE: R-02 proved same-device contention hits restore, and full-copy at this scale is page-cache-absorbed; expect the copy to absorb until the device saturates (iostat evidence) — measure both backup duration and iostat util
- Degradation: ≥2× backup duration; failure: backup failure or VM PausedIOError

### CBT-T-04 storage-fill (capacity) threshold
- Mechanism: fallocate filler pod on hostPath /var/hpvolumes/csi filling to leave {60, 100, 140} GiB free (pool 1.42TiB free after clean-all; full backup needs ~17.5GiB data + qcow2 overhead)
- Purpose: find the boundary between "backup completes" and ENOSPC failure (I-04 r01 already proved the failure mode at 0 free; find the ACTUAL threshold — how much headroom a full+incremental cycle needs)
- Measure: backup success/failure vs free space at start; PV capacity vs actual usage; the free-space floor that still succeeds
- This directly quantifies the F-08/I-05 "run out of space" scenarios' safety margin

## Shared trigger skeleton (per scenario)
1. Guards: node Ready, pool ≥300GiB free (T-04 excepted — its filler IS the variable), no stale run resources
2. `make e2e TYPE=full NAME=<RUN_ID> VM_OS=rhel9 MANIFEST_VARIANT=default GUEST_BASE_FILE_COUNT=1000 GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20 …` in background
3. Gate: `oc get vmbackup <name> -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' == True`
4. Apply hog leg; telemetry (oc adm top node/pod, iostat via debug node where relevant, kernel OOM grep)
5. Backup completes or fails → record duration/reason; follow-up incremental + verify when backup succeeded
6. Escalate intensity until degradation/failure or legs exhausted; threshold point = the intensity where behavior changes

## Report format
Standard cbt-chaos-run templates; verdict per leg (NO_EFFECT / DEGRADED / FAILED with evidence) + a threshold summary table in the final report. Findings feed the engineering feedback: which resource dimension the CBT copy is sensitive to, and at what point it breaks.
