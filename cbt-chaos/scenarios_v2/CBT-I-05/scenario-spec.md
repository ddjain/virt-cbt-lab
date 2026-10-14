# Scenario: Run out of space on the incremental backup destination

## 1. Identity

- **Jira issue:** CBT-I-05 — "Run out of space on the incremental backup destination" (P1, technical scenario: pvc-scenarios, phase: operation start)
- **Run family:** incremental-backup workflow, storage-plane failure (capacity exhaustion)
- **Precedents:** none in this campaign (first destination-PVC-capacity scenario). Related: I-02 (mid-copy launcher kill → failed incremental → tracker-clearing finding); I-04 r01 (pool-level ENOSPC — different: that was the whole pool disk; this targets the incremental PVC's OWN capacity).

## 2. Objective and hypothesis

**Jira objective:** verify that incremental backup capacity exhaustion fails safely and leaves the previous full checkpoint and artifact usable.

**Product questions:**
1. Does the incremental backup FAIL CLEANLY when its destination PVC fills mid-copy (Done=True with a failure reason, not a hang)?
2. Does the tracker keep referencing the previous FULL checkpoint (the last known-good recovery point)?
3. Does the FULL backup artifact remain restorable (full-only restore hash matches baseline, no incremental marker)?
4. Can the retry with a fresh destination PVC succeed (recovery path)?

## 3. Workflow and mechanics (source-verified)

Two-stage lifecycle: `make e2e TYPE=full` → `make e2e TYPE=incremental` (RHEL 9, **MANIFEST_VARIANT=odf** — see §4). Facts pinned from the repo source:

- The incremental stage applies `manifests/incremental-backup-odf.yaml` (PVC request **30Gi**, storageClassName ocs-storagecluster-ceph-rbd) creating PVC `vm-incremental-pvc-<RUN_ID>-p01` and vmbackup `vm-incremental-<RUN_ID>-p01` together (`oc apply -f`, vm-cbt-backup.sh step 3/5).
- The pass's changed payload is ~15 GiB (1000 files × 15–20 MiB, deterministic plan) — fits 30Gi normally.
- The backup controller attaches the destination PVC and streams the CBT-changed blocks. If the destination fills, the copy write fails → expect the backup to fail with a Done condition carrying a failure reason (analogous to I-02's clean failure), NOT a hang.
- A failed incremental sets run state `incremental_failed` via `mark_incremental_failure` (e2e-stage.sh) — the known workflow dead end (I-02 finding). The Jira's recovery ("use a fresh destination PVC and rerun") therefore cannot go through `make e2e TYPE=incremental` (state gate refuses `incremental_failed`).

### Recovery-path design decision (harness-level, honest to the Jira)

The Jira prescribes: fresh destination PVC + rerun. The workflow's own stage machinery cannot express that after a failed incremental (dead-end state + fixed `-p01` names + existing-object refusal). The trigger therefore implements the recovery EXPLICITLY at the API level, mirroring what the stage does internally (same manifest template, same substitution, fresh pass-02 names):
1. Verify the tracker still references the FULL checkpoint and the failed p01 object's terminal state.
2. Full-only restore verification: run `scripts/vm-cbt-restore-test.sh` against the run — it reconstructs the full PVC alone when `expected_pass_count == 0`. After a failed pass 1 of planned 1, `run.json` records the failure; the manifest's incremental requirement must match. Fallback if the script's gates refuse: direct restore-verify pod against the full PVC only (restore-lib.sh pattern) comparing baseline count/bytes/manifest-sha — the same checks the workflow itself performs.
3. Retry: render `manifests/incremental-backup-odf.yaml` with pass-02 names (`vm-incremental-<RUN_ID>-p02`, `vm-incremental-pvc-<RUN_ID>-p02`) + the tracker source, apply, wait for Done (expect Incremental chaining to the FULL checkpoint), then verify the cumulative restore (full + p02) matches pass-1 expectations (the mutation was already applied to the guest before the failed copy; the retry copies the same changed blocks).

This validates the Jira's product expectation (last known-good recovery point survives; retry succeeds) while documenting the workflow-level gap (needs manual/API retry — same class as the I-02 finding).

## 4. Target and validated disruption

**Target:** the incremental destination PVC `vm-incremental-pvc-<RUN_ID>-p01` (30Gi, ocs-storagecluster-ceph-rbd — RBD CSI enforces the PVC capacity as the filesystem size, live-verified).

**Action (fill to ~95%+):** PRE-FILL the destination before the backup object exists (r02 design; r01's concurrent fill was archived invalid — see below). The trigger pre-creates the p01 PVC from the stage's own template (same name/labels; the stage's later `oc apply` is a no-op), runs a short-lived privileged pod (rhel9/toolbox) mounting it and `fallocate -l 29G /data/.cbt-filler` (instant allocation on the RBD filesystem), waits for the filler to Succeed, deletes it, and waits until no pod mounts the PVC (volume released). The subsequent incremental stage creates the vmbackup against the pre-filled destination; the ~15 GiB changed-block copy cannot fit in the remaining <1 GiB; the backup's writes hit ENOSPC mid-stream. RBD quota smoke-verified: a 1Gi RBD volume accepted 957 MiB then stopped cleanly (fs 100%).

**Why the fill must precede the backup (r01 invalid-run finding):** a CONCURRENT fill during the copy is physically impossible on RWO RBD. r01 fired the filler 1s into the Progressing window and it was blocked the entire copy by `Multi-Attach error for volume "pvc-…" Volume is already used by pod(s) hp-volume-kx96x` — the backup controller hotplugs the destination PVC exclusively to its own attachment pod for the whole copy; no second pod can mount the volume until the controller detaches at Done. r01 verbatim evidence: filler attach succeeded 08:32:58Z, AFTER p01 Done at 08:32:53Z (runs/20261013-cbti05-r01-invalid-multiattach-window/). The Jira's literal "fill during the copy" is infeasible by concurrent mount; the pre-fill satisfies its intent — the backup starts with its destination bound AND ~97% full, and the copy hits the capacity boundary mid-stream.

**Design caveats (self-diagnosing):** (a) if the controller erases/reformats the destination before writing, the backup would succeed against the "filled" PVC — the trigger detects this (UNEXPECTED-SUCCESS branch) and captures a post-backup df + file listing to distinguish "fill erased" from "copy fit in slack"; (b) the fill leaves ~1 GiB slack — smaller than the ~15 GiB payload, so a normal copy cannot fit; (c) the filler is deleted and the volume verified unmounted before the stage starts, so the backup's hotplug attach cannot hit Multi-Attach itself.

**Duration:** the fill is permanent for the run (the PVC and its PV are deleted during post-run/invalid-run cleanup; the RBD volume is reclaimed with them).

**Cluster placement note:** ODF VMs are NOT node-pinned to d38-h18-000-r660 (RBD is network-attached; the launcher can run on any KVM node). The trigger does NOT enforce the HostPath placement guard; it records the actual VM node (evidence only). The filler pod mounts the p01 PVC via RBD CSI — node-agnostic.

## 5. Verification criteria

- Injection validity: filler pod ran on the PVC (same volume), allocation timestamps inside/before the copy window; p01 destination PVC ~full (df inside filler pod or PVC status).
- Clean failure: p01 Done=True with a failure reason (expect an I/O / no-space class reason), within a bounded time (not a hang beyond the workflow's 20m wait).
- Tracker unchanged: still references the FULL checkpoint after the failure (watch stream + final state). Watch for the I-02 pattern (delayed `CheckpointRedefinitionFailed` clearing the tracker ~seconds later) — record which semantic holds here.
- Full artifact restorable: full-only restore hash/count/bytes match baseline (restore-test or direct verifier).
- Retry succeeds: p02 (fresh PVC) completes as Incremental chained to the FULL checkpoint; cumulative restore (full + p02) matches the pass-1 manifest expectations.
- Product verdict mapping: all hold → PASS. Clean failure but tracker cleared / full artifact damaged / retry impossible at product level → FAIL with findings. Retry impossible only at WORKFLOW level (state gate) but possible at API level → PASS with the workflow-gap finding (already recorded under I-02).

## 6. Pre-run guards

Standard (RUN_ID collision, resource-name collision, krknctl n/a — direct injection), filler-pod hygiene (runs in vm-cbt-demo, named `filler-<RUN_ID>`; deleted after allocation), ODF cluster health check (Ceph RBD available; no placement guard — ODF VMs are not node-pinned). Note: the I-04 pool-capacity guard is N/A — the fill is inside the RBD volume's own quota (30Gi), not the HostPath pool.

## 7. Uncertainties

- Timing: the fill must land before the copy finishes (~16-20s window + filler pod scheduling ~5-10s; total budget tight but feasible at 1s polling with immediate fire on existence+Progressing). If the copy completes anyway, harness-invalid → re-run firing the filler on PVC-Bound (pre-Progressing), still within the Jira's window.
- The backup controller may write the destination with sparse/streamed semantics such that some data lands even on a 100%-full fs — irrelevant: the ~15Gi payload cannot fit <1Gi; failure is expected regardless.
- Whether the failure reason explicitly names ENOSPC/no-space or a generic copy error — record verbatim.
- Whether the tracker-clearing semantic (I-02's `CheckpointRedefinitionFailed` after a failed incremental) also fires here — VMI is alive this time (pure destination exhaustion, no VMI deletion); decisive product-behavior datum. Watch tracker + events for ~2 min after failure.
- ODF full-backup duration may differ from the HostPath baseline (large-odf measured ~28s full in .env.example notes) — record actuals; the incremental duration expectation scales accordingly.
- Restore-test gates: after a failed pass, run.json records `incremental_failed`; `vm-cbt-restore-test.sh` may refuse (expected_pass_count vs completed mismatch). The trigger uses the direct-verifier fallback in that case (restore-lib pattern, full PVC only) — equivalent checks, documented in the report.
