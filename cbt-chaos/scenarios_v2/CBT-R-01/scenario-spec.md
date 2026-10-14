# Scenario: Stop restore verification while rebuilding the backup image

## 1. Identity

- **Jira issue:** CBT-R-01 — "Stop restore verification while rebuilding the backup image" (P2, technical scenario: pod-scenarios, phase: active restore)
- **Run family:** restore-verification workflow, verifier-pod interruption
- **Precedents:** I-05/I-08 direct-verifier pattern (rendering the workflow's own restore-verify pod outside the stage); I-06 Multi-Attach knowledge (verifier pods mount backup PVCs read-only)

## 2. Objective and hypothesis

**Jira objective:** interrupting the restore verification process must not alter the backup artifacts, and verification must be safely rerunnable.

**Product questions:**
1. Does killing the verifier pod mid-conversion (qemu-img rebase/convert) leave the backup PVCs BOUND and UNCHANGED (they are mounted readOnly — the artifacts must be untouched)?
2. Does a rerun of the same verification produce the SAME results (hashes/marker semantics) as the uninterrupted baseline?
3. Does the interrupted pod leave any stale state that blocks the rerun (e.g., leftover attachment, pod name collision)?

## 3. Workflow and mechanics (source-verified)

The workflow's restore verification (`run_restore_verify_pod`, restore-lib.sh:28) renders `manifests/restore-verify-pod.yaml` with the full PVC + N incremental PVCs mounted readOnly, applies it as pod `vm-restore-verify-<RUN_ID>`, waits up to 1800s for Succeeded/Failed, and greps `FULL_WORKLOAD_*` / `PASS_NN_*` outputs. The pod's script does qemu-img convert/rebase of the backup qcow2s into an emptyDir and hashes the reconstructed workload directories — the conversion phase is the interruption target ("during conversion or rebase").

**Design (direct-verifier approach, I-05/I-08 pattern):**
1. Run the normal `make e2e TYPE=full` + `TYPE=incremental` lifecycle (workload baseline + full + p01 with the workflow's own restore verification at the final pass — this is the BASELINE verification result, hashes recorded in the run's restore-test fragment).
2. Chaos leg: render and apply the SAME verifier pod (same manifest, same PVCs — full + p01, readOnly) but with a DIFFERENT pod name (`vm-restore-verify-<RUN_ID>-chaos` to avoid collision with the workflow's own verifier name). Arm krkn pod-scenarios with a k8s trigger on the pod's Running phase (or command trigger on `oc get pod <name> -o jsonpath='{.status.phase}' | grep -q Running`); krkn deletes the verifier pod (grace 0) while it is converting.
3. Evidence: pod phase timeline (Running → terminated), the pod's partial log (qemu-img lines) proving conversion was in flight at kill time.
4. Artifact-unchanged checks: PVC Bound states before/after; PV names/uids unchanged; (artifact content re-proven by the rerun's hash equality — the strongest possible "unchanged" evidence: if the rerun produces the exact baseline hashes, the artifacts were not altered).
5. Rerun leg: apply the same verifier pod again (fresh name or same name after deletion), wait Succeeded, compare FULL_WORKLOAD_* and PASS_01_* outputs with the baseline from step 1 — must be EXACT.
6. Also compare against the workload-manifest.json baseline (file_count/bytes/sha).

**krkn semantics:** pod-scenarios with `--namespace vm-cbt-demo --label-selector` targeting the chaos verifier pod uniquely. The verifier pod's labels (from restore-verify-pod.yaml): managed-by/run-id labels — the run-id label uniquely identifies run pods, and the pod name prefix distinguishes the chaos verifier. krkn pod-scenarios supports `--name-pattern` (I-06-proven) — use pattern matching the chaos verifier pod name. Trigger: command trigger on the pod being Running (2s poll) — the conversion window is minutes (18 GiB convert + 36 GiB rebase), comfortably catchable.

## 4. Target and validated disruption

**Target:** the chaos verifier pod `vm-restore-verify-<RUN_ID>-chaos` (a standalone pod, NOT the workflow's own verifier — the workflow stage has already completed).

**Action:** krkn pod-scenarios force-delete (grace 0) while the pod's log shows qemu-img conversion in flight.

**Injection window:** pod Running AND conversion started (first qemu-img/progress log line seen) — gate on Running; verify conversion-in-flight from the partial log post-hoc (a kill in the image-pull/attach phase would not satisfy "during conversion"; the log check catches this).

**Duration:** immediate.

**Blast radius:** one disposable verifier pod. The backup PVCs are mounted readOnly — a pod kill cannot write to them. No workflow stage is active.

## 5. Verification criteria

- Injection validity: krkn kill line names the chaos verifier pod; pod termination timestamped; the pod's partial log shows conversion in flight at kill time.
- Backup PVCs remain Bound and unchanged: PVC phase Bound before/after; rerun hash equality (decisive — bit-exact reconstruction impossible from altered artifacts).
- Verification rerun succeeds and matches: rerun pod Succeeded; FULL_* and PASS_01_* outputs exactly equal the baseline (both the workflow's stage-1 verification and the manifest baseline).
- No stale state: no leftover VolumeAttachment blocking the rerun; rerun pod schedules promptly.
- Verdict mapping: all hold → PASS. Artifacts altered / rerun mismatch / rerun blocked → FAIL.

## 6. Pre-run guards

Standard (RUN_ID collision, resource collision). RESTORE_HELPER_IMAGE set (from .env). The chaos verifier uses a distinct pod name to avoid the workflow's verifier-name collision (delete_restore_pod in restore-lib deletes `vm-restore-verify-<RUN_ID>` on apply — using the same name would be fine too since the rerun deletes first, but a distinct name keeps the workflow's artifacts clean).

## 7. Uncertainties

- Conversion duration: full-only convert of ~18 GiB + cumulative rebase ~36 GiB took ~3.5-4.5 min in prior runs (I-06 pinned restore). The kill gate (Running) may fire during image pull (~5-10s) — the partial-log check distinguishes; if the kill lands pre-conversion, re-run the chaos leg (the verifier is disposable and re-renderable without touching the workflow state).
- Pod log retrieval after force-delete: `oc logs` on a deleted pod fails; capture the log via a background `oc logs -f` stream started at pod Running (tee to evidence file) so the partial log survives the kill.

## 8. Evidence to capture

krkn log (kill line + timestamp), chaos pod partial log (background stream), pod phase timeline, PVC states before/after (name, phase, PV uid), rerun pod log (full), baseline comparison table (workflow stage-1 verify vs rerun vs manifest), VolumeAttachment absence check. All under `cbt-chaos/scenarios_v2/CBT-R-01/runs/<RUN_ID>/`.
