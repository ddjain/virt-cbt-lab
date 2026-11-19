# Scenario: Storage I/O contention during an incremental backup

## 1. Identity

- **Scenario ID:** CBT-I-04
- **Jira issue:** CBT-I-04 — "Create storage I/O contention during an incremental backup" (P1, technical scenario: node-io-hog, phase: active operation)
- **Run family:** incremental-backup workflow, storage-plane contention (performance-correctness)
- **Precedent:** CBT-F-09 (identical disruption on the FULL backup — node-io-hog via krknctl on the CBT storage path, gated on the active-copy compound condition; PASS). I-04 applies it to the incremental pass.

## 2. Objective and hypothesis

**Jira objective:** measure whether sustained storage contention slows the incremental backup while preserving its incremental nature and data correctness.

**Product question:** with 8 parallel stress-ng hdd writers hammering the HostPath pool filesystem that backs both the VM root disk and the incremental destination PVC, does p01 still complete as an Incremental (longer than the ~15–20 s baseline is acceptable), with a distinct correct checkpoint and verified restores?

## 3. Workflow and prerequisites

Two-stage lifecycle (I-01 pattern): `make e2e TYPE=full` → `make e2e TYPE=incremental` (RHEL 9, default variant). The hog starts before the incremental stage and fires when p01 reaches Progressing=True ∧ Done≠True (krknctl trigger-command, 3 s interval).

Cluster facts (measured 2026-11-12, F-09/I-04 probes): the only node with the cbt-demo-hpp backing disk is d38-h18-000-r660 (also where every campaign VM is scheduled); the pool device is **/dev/sdb mounted at /var/hpvolumes/csi** (findmnt-verified; the old `/mnt/local-storage/cbt-demo-local-pool` path in this spec was wrong); ~1.3 t free — 64 × 2 g = 128 g transient dsync writes fill <10%.

## 4. Target and validated disruption

**Target:** the CBT storage filesystem on the VM's worker node (d38-h18-000-r660, `/var/hpvolumes/csi` on /dev/sdb).

**Action (variant 2, executed 2026-11-12):** direct run-owned privileged pod (NOT krknctl — see §9): nodeSelector `kubernetes.io/hostname=d38-h18-000-r660`, hostPath `/var/hpvolumes/csi` (type Directory) mounted at /hog-data, `stress-ng --hdd 64 --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync --timeout 120s`, armed via `direct-trigger.sh` polling p01 Progressing=True ∧ Done≠True (3 s interval, fail-closed, live pod-spec assertion). krknctl node-io-hog is NOT usable for this fault: its buffered writes are page-cache absorbed (~16 MB/s device writes at 64×2g/120s, rc=0, "disk space allocated: 0.145 MB" — silent no-op; see bugs/krknctl-node-io-hog-buffered-writes-no-device-load.md). The EXP-09 `--node-mount-path`→`/tmp` bug does NOT reproduce with plugin digest edea0aeb… — targeting works; only the write mode is broken.

**Condition:** p01 exists ∧ Progressing=True ∧ Done≠True (the exact F-09/I-02 compound condition, single-quoted JSONPath validated live in F-09).

**Expected mechanics:** the copy competes with 8 hdd writers for the same filesystem → longer duration (Jira explicitly expects > ~15 s baseline) → still Incremental type, distinct checkpoint, correct data. The hog namespace is created by the trigger and cleaned on exit (trap).

## 5. Verification criteria

- Injection validity: krknctl log shows the trigger command satisfied (backup Progressing observed) and the hog pod running on d38-h18-000-r660 during the copy; hog namespace created; evidence of I/O (hog pod logs/status).
- Incremental nature preserved: p01 `.status.type=Incremental`; duration recorded and compared with the 16–21 s no-contention baseline (F-09's full went 52→~72 s under the same load; the incremental is ~15 GiB of changed data, so a comparable slowdown ratio is expected — any duration is acceptable per the Jira as long as type/data hold).
- Checkpoint: distinct p01 checkpoint, chained to full; tracker advanced exactly once.
- Data correctness: full-only + cumulative restore hashes PASS (workflow's final-pass verification).
- Hog cleanup: hog namespace deleted after the run (trap); no residual stress pods.

## 6. Pre-run guards

RUN_ID collision guard, full stage must exit 0, krknctl present, hog namespace name free, VM node == d38-h18-000-r660.

## 7. Uncertainties

- The incremental (16–21 s) may finish before the hog's trigger fires (3 s interval) — no: the condition is checked every 3 s against a ≥16 s window; F-09 proved the pattern on a 52 s window; a 16 s window still admits a 3 s poll. If the hog fires late (after Done), the run is harness-invalid (re-run).
- The hog writes 16 g to the same filesystem as the backup destination PVC — capacity check done in F-09 (<1.4% fill); no risk of ENOSPC.

## 8. Variant 2 — direct hog with synchronous writes (r03)

r02 result: injection VALID (hog pod on d38-h18-000-r660, container started 4 s after the copy window opened, ran 61 s covering p01's Done; 8 workers; 8230 MB allocated detected) and ALL correctness criteria PASS (type=Incremental, distinct chained checkpoint, tracker exactly once, 17/17 restores) — but **no observable slowdown**: p01 = 18 s, inside the 16–21 s no-contention baseline. The Jira's expected "takes longer" did not materialize.

Root cause (source-verified, not invented): the krkn hog image's io path (`run.sh` → `io-hog.conf.template`: `hdd $HDD_WORKERS / hdd-bytes $HDD_BYTES / hdd-write-size $HDD_WRITE_SIZE / timeout $DURATION`) uses stress-ng's default hdd options — **buffered writes, no fsync/dsync/direct** (`--hdd-opts` supports sync/dsync/direct/fdatasync but the template does not set it). Buffered 1 m writes are page-cache absorbed; the kernel flushes lazily, so the backup's reads/writes on /dev/sdb never competed for the disk queue. Ground truth: `/usr/local/lib/python3.9/site-packages/krkn_lib/k8s/templates/hog_pod.j2` (env plumbing only) and the image's own `run.sh`/`io-hog.conf.template` (extracted via podman from quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog).

Variant 2 design (r03): keep the validated injection shape (same node, path, 3 s gated trigger on p01 active-copy) but replace the hog pod with a DIRECT pod running `stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync` (F-10 direct-pod precedent; dsync = O_DSYNC per-write synchronous writes — forces the disk queue contention the Jira wants). Expect p01 duration > 21 s (the no-contention baseline ceiling). If it still completes in the baseline band with dsync writes landing during the copy, that is itself a meaningful resilience result (the pool disk absorbs both streams).


## 9. r03 result (variant 2 executed, 2026-11-12)

Run `runs/12-11-2026-13-00-53-vm-20261112-cbti04-r01-i04-incremental-io-hog-iteration-1/` — **RESILIENT**. Control `20261112-cbti04-r01ctl`: same pins, incremental copy 15 s, 18.28 GB payload, PASS. Chaos leg: trigger satisfied 2 s after Progressing=True (13:04:40), hog pod Running 13:04:43 with live-spec assertion (node + hostPath + dsync args), telemetry shows sustained sdb writes across the copy window, p01 Done 13:04:57 (≈19 s vs control 15 s — mild slowdown, not a gate). Type=Incremental, distinct chained checkpoint, tracker advanced exactly once, payload byte-identical to control, full+cumulative restore verification PASS. Hog cleanup clean (namespace deleted, residue absent).

Sizing note: this execution used the user-approved 64 workers × 2 g × 120 s dsync (the spec's original 8 × 2 g × 60 s remains the Jira's nominal ask; both are variant 2 in spirit — synchronous writes on the pool device).

