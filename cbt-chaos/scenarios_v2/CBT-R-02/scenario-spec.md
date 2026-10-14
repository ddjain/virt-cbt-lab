# Scenario: Create storage I/O contention during restore verification

## 1. Identity

- **Jira issue:** CBT-R-02 — "Create storage I/O contention during restore verification" (P2, technical scenario: node-io-hog, phase: active restore)
- **Run family:** restore-verification workflow, storage I/O contention during offline restore conversion
- **Precedents:** I-04 (node-io-hog semantics: krknctl buffered 1m writes are page-cache-absorbed — NO contention; the decisive variant was a direct hog pod with `stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync` on the storage path); R-01 (standalone direct-verifier pattern with the workflow's own rendered manifest, `FULL_QCOW2=` gate, rerun-hash baseline comparison)

## 2. Objective and hypothesis

**Jira objective:** measure how storage contention affects offline restore conversion without changing the stored backup artifacts; restore should slow down but complete within the existing verification timeout (1800s) with the same hashes.

**Product questions:**
1. Does sustained synchronous-write I/O load on the CBT storage path (the HostPath pool directory holding the backup PVC images) during the verifier's qemu-img convert/rebase measurably slow the conversion?
2. Does the verifier still complete within the 1800s workflow timeout and produce EXACTLY the baseline hashes (artifacts unchanged, data correct)?
3. Does the contention leave any residue on the cluster (hog cleaned up, PVC bindings unchanged)?

## 3. Workflow and mechanics (source-verified)

The restore verifier (R-01 pattern) renders `manifests/restore-verify-pod.yaml` with the full + p01 backup PVCs mounted read-only, converts the full qcow2 to raw (`qemu-img convert`) and rebases+converts the incremental overlay — all reads from the backup PVCs' hostPath-backed directory and writes to the pod's emptyDir (node-local scratch on the same node).

**Storage layout (verified live):** HPP `cbt-demo-hpp` HostPathProvisioner storage pool `cbt-demo-pool` = `/var/hpvolumes` on node `d38-h18-000-r660`; PVs node-pinned via `topology.hostpath.csi/node`; the verifier pod therefore also runs on `d38-h18-000-r660`. The I/O hog must target the same path/node.

**Design (I-04 variant-2 hog + R-01 verifier pattern):**
1. Normal full + 1-pass incremental lifecycle with the workflow's own restore verification (BASELINE hashes + BASELINE conversion timing from `runs/<RID>/logs/restore-verify-pod.log` + pod start/finish timestamps).
2. Contention leg: apply the direct hog pod (I-04's exact recipe: krkn-hub hog image `workload-krkn-hog`, privileged, hostPath `/var/hpvolumes` mounted at /hog-data, `stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync`, nodeSelector d38-h18-000-r660, restartPolicy Never) with a duration covering the whole verifier run (Jira says 180s; the verifier conversion runs ~3-4.5 min, so run the hog for the full verifier duration + margin — the Jira's 180s minimum is satisfied by construction and the whole conversion is contended; stress-ng `--timeout 420`).
   - Blast-radius control (I-04 finding): direct the hog at the HPP pool directory `/var/hpvolumes`, which lives on `/dev/sda4` — the node's /var filesystem also hosting other cluster workloads' local storage. The hog writes are confined to the pool dir; free space (≥300GiB) absorbs the 16GiB of hog writes; the node is the dedicated CBT worker. I-04 r03 ran this exact hog on this exact path for 60s with no cluster impact (SLOs green, VM healthy).
3. Verifier leg: apply the standalone verifier (`vm-restore-verify-<RUN_ID>-chaos` name, same rendered manifest), gated so the hog is ALREADY running (stress-ng started) before the verifier's conversion begins; the hog's `--timeout` covers the conversion.
4. Timing comparison: baseline verifier conversion duration (pod Started→Succeeded) vs contended verifier duration. Also `qemu-img` per-stage progress is not in the log (terse) — the wall-clock duration and the pod's container CPU time are the measurable slow-down evidence.
5. Hash comparison: contended verifier outputs must EXACTLY equal baseline (six fields).
6. Cleanup: delete hog pod + namespace; confirm PVC bindings unchanged.

**krkn semantics:** the Jira's "technical scenario: node-io-hog" is krknctl node-io-hog — I-04 PROVED its buffered writes are page-cache-absorbed (no contention) on this exact cluster/path. The Jira's intent (real storage contention) requires the direct hog pod; I-04's r02→r03 progression sanctions this fallback. I will run krknctl node-io-hog FIRST (validates the Jira's named tool + its trigger capability) and the direct dsync hog as the decisive contention source, reporting both.

## 4. Target and validated disruption

**Target:** the HostPath pool filesystem (`/var/hpvolumes` on d38-h18-000-r660) serving the backup PVCs during the verifier's read phase.

**Action:** sustained O_DSYNC 1m writes from 8 hdd workers (the I-04-proven contention profile) for the verifier's whole conversion.

**Injection window:** verifier pod Running AND `FULL_QCOW2=` logged (conversion started) — no wait: hog must be running BEFORE conversion to contend the whole window; the hog starts first (gated on hog pod Running + stress-ng process up), then the verifier is applied.

**Duration:** ≥180s (Jira) — hog `--timeout 420s` covers the full conversion.

**Blast radius:** one hog pod on the CBT worker node, writes confined to the pool directory; the dedicated CBT node + ≥300GiB free guard.

## 5. Verification criteria

- Contention active during conversion: hog pod Running with stress-ng started before verifier's `FULL_QCOW2=` line and (if conversion < hog timeout) still running at verifier completion; timing overlap documented.
- Verifier completes within the 1800s timeout under contention (workflow's own budget).
- Contended outputs exactly equal the baseline six fields (artifacts unchanged + data correct under contention).
- Slow-down measured: contended duration vs baseline duration reported (slower expected; NOT a failure criterion per Jira — completing within timeout with same hashes is the criterion).
- No residue: hog pod/namespace deleted; PVC states identical.

## 6. Pre-run guards

- HostPath pool ≥400GiB free (I-04 guard, verified 312GiB free… re-check at trigger time; hog writes ≤16GiB absorbed).
- RUN_ID collision guards (no existing runs/<RID>, no cluster resources matching).
- RESTORE_HELPER_IMAGE set.

## 7. Uncertainties

- Baseline conversion duration (~3.5-4.5 min) vs hog 420s timeout: if conversion runs longer than 420s under contention (3-4x slowdown would need >12 min — timeout 1800s headroom), the hog may end first; the run remains valid if the overlap covered the measured window. Record both timestamps.
- Whether the page-cache vs dsync distinction matters for the verifier's READ path (reads of the backup qcow2s): reads contend with the hog's writes only at the disk-queue level (same filesystem, same device). This is exactly what the Jira asks to measure.
- `/dev/sda4` also hosts kubelet pods dir — the hog's writes contend with local scratch on the same device; this IS the intended contention surface (the verifier's emptyDir scratch is on the same device). Watch for collateral (node NotReady) via the observer; abort threshold: none needed, 60s I-04 r03 precedent showed no impact.

## 8. Evidence to capture

Hog pod spec + phase timeline + stress-ng exit; verifier pod spec, start/finish timestamps, containerStatuses (CPU time), full log (six output fields); baseline log + timing from the workflow run tree; PVC before/after; hog cleanup proof; timing comparison table. All under `cbt-chaos/scenarios_v2/CBT-R-02/runs/<RUN_ID>/`.
