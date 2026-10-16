# CBT-F-01 Re-run Matrix Proposal — after closed run `20261016-cbt-f-01-r04` (BLOCKED, evidence sufficiency)

Author: Variation Decider (propose only; Lead executes, human approves). Nothing here is executed.
Basis: the closed run `20261016-cbt-f-01-r04` and the scenario's own history `20261016-cbt-f-01-r01`, `-r02`, `-r03` (lifecycle `runs/20261016-cbt-f-01-r0{1,2,3}/summary.json`, `-r02-clean/summary.json`; scenario artifacts `runs/20261016-cbt-f-01-r03/*`, `runs/20261016-cbt-f-01-r04/*`, including `verdict.json`, `checkers/evidence-sufficiency.json`, `checkers/injection-validity.json`, `driver-timings.json`, `reports/test-run-{report,result}.md`, `trigger/trigger.log`). Verdicts are not re-derived.

## Decision: Next action = EVIDENCE-COVERAGE re-run of the baseline chaos leg (spec-4.3 capture fix) — this is NOT a chaos leg

**One line:** Run the baseline chaos leg again with identical parameters and the *only* change being the harness fix that captures the launcher's libvirt checkpoint tree before injection and after VM recovery, because that is the sole action that can convert the existing BLOCKED into a reportable PASS and it is a precondition for any new chaos parameter to be gradeable at all; no chaos parameter should be varied first.

Rationale (marginal value, explicit):

- The product behaviour is already answered and unchanged across the history: `20261016-cbt-f-01-r04` deterministic core PASS 8/8 (`verdict.json`), injection validity PASS (`checkers/injection-validity.json` — `window`, `target`, `independent-effect` all SUPPORTED), and 5 of 6 spec criteria SUPPORTED (`checkers/evidence-sufficiency.json` `criteria[]`). The single REJECT is spec-4.3 (`reject_reasons[0]`).
- The REJECT is an *evidence-coverage* gap, not a product question: the pack holds only the pre-injection tree capture (`trigger/trigger.log:9`, exit 0, empty) after four failed attempts (`trigger/trigger.log:4-7`, exit 1), and no post-copy/post-recovery capture anywhere (`checkers/evidence-sufficiency.json` `missing_evidence[0]`). A verified REJECT cannot be downgraded (`state.json` `"verdict":"BLOCKED"`, `"deterministic_core":"PASS"`; `reports/test-run-result.md`).
- Every new chaos parameter (window position, guest sizing, Windows OS) would produce a pack that *still* lacks the after-recovery tree, so it would be graded INSUFFICIENT on the same spec-4.3 and land BLOCKED for the same reason the current run did. Its marginal value is therefore **zero until the coverage fix lands**; the coverage fix strictly dominates and is a prerequisite.
- All chaos runs to date hit the *early* copy window — each injected at the first `Backup started` signal, 12 s before the forced terminal failure (`20261016-cbt-f-01-r04`: signal 01:12:26Z → failure 01:12:38Z, `reports/test-run-report.md`; `20261016-cbt-f-01-r03`: 21:25:30Z → 21:25:42Z) — inside an undisrupted full copy of ~76–77 s (`runs/20261016-cbt-f-01-r02-clean/summary.json` `backups.full.duration_seconds=77`; `reports/test-run-report.md` clean full 01:15:31Z → 01:16:47Z). So the late window is genuinely uncovered — but it is a *second* question and must not pre-empt answering the first.

## Leg 1 (DONE): `20261016-cbt-f-01-r02` — baseline interrupted-full (early window)

- **Attempt 1 (`20261016-cbt-f-01-r01`) was aborted**: lifecycle `verdict: BLOCKED`, `recovery_attempts[0].blocked_reasons` = `precondition failed: vm_ready`, `vmi_running`, `cbt_enabled` (`runs/20261016-cbt-f-01-r01/summary.json`) — the same-VM recovery ran before the VM had recovered. This tripped hard-stop #3; it was treated as transient and retried once (attempt 2), which is the full 2-attempt budget for that failure mode.
- **Parameters (attempt 2 = `-r02`):** Interrupted full (`TYPE=full`), RHEL9 (`os_profile rhel9`), ODF Ceph-RBD, 1000-file / 15–20 MiB baseline (18,277,728,256 bytes), injection at the first `Backup started` signal (early window).
- **Outcome:** lifecycle PASS, scoped to the same-VM recovery invocation (`runs/20261016-cbt-f-01-r02/summary.json` `verdict_reason`: "The same-VM recovery full backup and baseline restore passed"); the interrupted full failed (`lifecycle.state: full_failed`). Recovery backup carried the guest-agent-not-connected freeze warning — see Leg 2.
- **Proved:** interrupted full fails closed with a clear reason; same-VM forced full recovers and restores to baseline. **Left open:** no scenario-level evidence checker existed for this run (no `checkers/` dir under any `20261016-*-r02*` scenario path), so spec-4.3 was never graded.

## Leg 2 (DONE): `20261016-cbt-f-01-r03` — baseline repeat (early window)

- **Parameters:** identical to Leg 1 (`driver-timings.json`: interrupted_full 152 s, same_vm_recovery 53 s, clean_lifecycle 374 s, verdict 0; wall clock 579 s).
- **Outcome:** PASS (scenario `verdict.json`, deterministic core 8/8). Forced recovery full `Done=True` with the same post-restart guest-agent freeze warning; clean full+incremental lifecycle verified (`reports/test-run-report.md`).
- **Proved:** every acceptance criterion re-passed; recovery/reconcile path works at the early window; the post-restart quiesce warning reproduced (first noted in Leg 1) as a repeatable timing pattern.
- **Left open:** spec-4.3 is *ungraded* here — this run predates the evidence-sufficiency checker ("ran without an evidence checker", `reports/test-run-report.md`), so its PASS rests on the same pre-injection-only tree capture that Leg 3 later REJECTed.

## Leg 3 (DONE): `20261016-cbt-f-01-r04` — baseline repeat under the evidence checker (early window)

- **Parameters as run:** identical to Legs 1–2 (`driver-timings.json`: interrupted_full 148 s, same_vm_recovery 50 s, clean_lifecycle 380 s, verdict 1 s; wall clock 579 s, matching r03). Injection at the first `Backup started` (signal 01:12:26Z), exact target UID `8fa3ecb1…` (`trigger/action-request.json`, `trigger/effect-check.json`).
- **Outcome:** run verdict **BLOCKED (evidence sufficiency)** — deterministic core PASS 8/8 (`verdict.json`, 8 checks), injection validity PASS (`checkers/injection-validity.json`), evidence sufficiency **REJECT** on spec-4.3 (`checkers/evidence-sufficiency.json`; `state.json` `"verdict":"BLOCKED"`).
- **Proved:** the product matched the hypothesis (fail-closed interrupted full, no tracker advancement, VM/CBT recovery, both restores matched baseline) **on the evidence that exists** (`reports/test-run-report.md` executive summary).
- **The gap that blocks it:** spec-4.3's libvirt checkpoint-tree half is not established — only the pre-injection capture exists and it is empty (`trigger/trigger.log:9` after four failures `:4-7`); there is no post-recovery capture and no inspection of the failed artifact (`checkers/evidence-sufficiency.json` `missing_evidence[0..1]`). The evaluator does not model spec-4.3, so its PASS is narrower than the spec's PASS (`reports/test-run-report.md` harness observation #1).

## Leg 4 (proposed, recommended): EVIDENCE-COVERAGE re-run of the baseline chaos leg — spec-4.3 checkpoint-tree capture

> This executes the chaos path once more but **varies no chaos parameter**; its purpose is evidence coverage, not a new product question. It is the next leg because it is a prerequisite for every other leg being reportable (see Decision).

- **Parameters:** identical to Leg 3 — Interrupted full (`TYPE=full`), RHEL9, ODF Ceph-RBD, `GUEST_BASE_FILE_COUNT=1000`, 15–20 MiB range, injection at the first `Backup started` signal (early window), same three-leg driver (interrupted full → same-VM recovery → separate clean lifecycle). Fresh `RUN_ID` + fresh VM; no backup reset; no dimension varied. Harness delta (the *only* change):
  1. **Pre-injection** capture of the launcher's libvirt checkpoint tree via the run launcher's `compute` container (the spec's `virsh checkpoint-list vm-cbt-demo_vm-<RUN_ID> --tree`), with the r04 capture-failure path (four exit-1 retries, `trigger/trigger.log:4-7`) fixed so it records a proven, non-erroring pre-injection tree.
  2. **Post-recovery** capture of the same tree via the **replacement** launcher's `compute` container after VM recovery — the capture entirely absent in r04 (`checkers/evidence-sufficiency.json` `missing_evidence[0]`).
  3. Record whether the checkpoint stamped on the failed backup object (`status.checkpointName`, e.g. `…-2026-10-16_01-12-16`) survived the deletion or was usable (`missing_evidence[1]`).
- **Question it answers:** With product behaviour already evidenced, can spec criterion 4.3 be established — launcher-side checkpoint tree captured before injection and after VM recovery, tracker `latestCheckpoint` still unset after the failure, and no usable checkpoint attributable to the failed copy — so CBT-F-01 is reportable as **PASS** rather than BLOCKED? (Not a chaos question; no new parameter.)
- **Finding/gap resolved:** the spec-4.3 evidence gap that forced the r04 BLOCKED verdict and that also underlies r03's ungraded PASS. Closes `missing_evidence[0..1]`.
- **Preconditions:**
  - (a) Trigger/observer amended to capture the libvirt checkpoint tree pre-injection **and** post-recovery, with the r04 capture-failure path fixed and a non-erroring record on a fresh lifecycle (`trigger/trigger.log:4-9` is the failure to eliminate);
  - (b) observer copy-window poll bug fixed — the `jq`-fed arithmetic test that delayed `observer/PRESERVED` by 6 m 22 s (`observer/finding.md`; harness observation #2 in `reports/test-run-report.md`) — so evidence lands well before any resource could be cleaned;
  - (c) evidence-checker/evaluator coverage aligned so the new capture is actually graded against spec-4.3 (the evaluator's narrower check set is harness observation #1);
  - (d) fresh unique `RUN_ID` and fresh VM; `--plan` rehearsal clean; checksums pass; no other dimension varied; destinations correctly sized by the trigger.
- **Expected observation by outcome:**
  - **REPORTABLE PASS (`SUCCESS`):** pre-injection tree captured (empty/consistent for a fresh lifecycle) and post-recovery tree captured from the replacement launcher; tracker `latestCheckpoint` still unset after the failure with no value from the interrupted copy; failed-object checkpoint not published/usable; spec-4.1/4.2/4.4/4.5/4.6 re-confirmed SUPPORTED → evidence checker SUPPORTS spec-4.3 → run verdict **PASS** (deterministic core PASS + injection PASS + evidence PASS).
  - **`FAILURE-A` (evidence still insufficient):** tree capture still errors or returns nothing usable after the fix (e.g. `virsh` path/permissions/timeout) → run remains BLOCKED on spec-4.3; **stop and re-scope the harness** — do not substitute a new chaos parameter.
  - **`FAILURE-B` (product difference):** a post-recovery checkpoint attributable to the failed copy, a usable failed-artifact checkpoint, or tracker advancement → escalates to a **product FAIL** (hard stop #1/#5).
  - **`FAILURE-C` (infrastructure):** same-VM recovery failure, cluster degradation, or capacity starvation → hard stop #3/#4 (see below).
- **Stop conditions:** (1) any **FAIL** verdict (product) → halt the matrix and escalate before further cluster time; (2) spec-4.3 **still** INSUFFICIENT after the harness fix → stop and re-scope the harness, not the chaos matrix; (3) any hard stop below.
- **Hard stops (Lead-enforced, apply here and to every leg):** any FAIL verdict; **two consecutive BLOCKED** legs; same-VM recovery failure (r01 already tripped this once — its 2-attempt transient budget is spent); cluster degradation/capacity starvation; checkpoint/tracker misadvancement or a usable checkpoint from the failed copy.

## Deferred chaos dimensions — all fail the marginal-value test against Leg 4

Each of these would be graded against the same spec-4.3 and land BLOCKED until Leg 4's coverage fix lands, so none is the next action:

- **Injection window position (late window).** The highest-value *chaos* dimension once the fix is in: all runs so far injected at the first `Backup started` (`20261016-cbt-f-01-r04` and `-r03`; both 12 s into a ~76–77 s copy), so reconciliation/detach/commit closest to copy completion is untested. Deferred, not dropped — it is the correct *next* chaos question **after** Leg 4, if a leg budget remains outside this matrix.
- **Guest sizing.** `GUEST_BASE_FILE_COUNT` / file-size range is the lever that widens the copy window (`scenario-spec.md` §2); sizing changes window length, not the criterion set — same spec-4.3 dependency. Defer.
- **Windows OS variant.** A separate, slower configuration with its own budget (`scenario-spec.md` §2: `windows-server-2022` golden DataSource, 40Gi cloned root disk, run-scoped OOBE Secret, QEMU Guest Agent file ops instead of SSH, 48Gi full / 30Gi incremental destinations). Higher cost, same spec-4.3 dependency. Defer; would need its own matrix proposal and capacity assessment.
- **Incremental-mode chaos window; failed-artifact on-disk/qcow2 inspection.** Evidence-scope items, not new chaos parameters.

## Cumulative matrix

| Leg | Run | Mode | Window | OS / backend | Sizing | Verdict |
|-----|-----|------|--------|--------------|--------|---------|
| 1 (DONE) | `20261016-cbt-f-01-r01` (attempt 1, aborted) → `20261016-cbt-f-01-r02` (attempt 2) | Interrupted full | early (first `Backup started`) | RHEL9 / ODF Ceph-RBD | 1000 files / 15–20 MiB / 18.28 GB | r01 BLOCKED (recovery preconditions); r02 PASS (lifecycle, recovery-invocation scope) — no evidence checker |
| 2 (DONE) | `20261016-cbt-f-01-r03` | Interrupted full | early | RHEL9 / ODF Ceph-RBD | 1000 files / 18.28 GB | PASS (deterministic core 8/8) — spec-4.3 ungraded |
| 3 (DONE) | `20261016-cbt-f-01-r04` | Interrupted full | early | RHEL9 / ODF Ceph-RBD | 1000 files / 18.28 GB | BLOCKED (evidence sufficiency) — deterministic core PASS 8/8, injection PASS, evidence REJECT on spec-4.3 |
| 4 (proposed) | — | Interrupted full (no chaos-parameter change) | early | RHEL9 / ODF Ceph-RBD | unchanged | target: REPORTABLE PASS by closing the spec-4.3 capture gap |

**Uncovered after this matrix (accepted residual):** late-window injection position; guest-sizing sweep; Windows OS variant; incremental-mode chaos window; failed-artifact on-disk inspection. Each fails the marginal-value test against Leg 4 under the leg cap.

## Hard-stop conditions (Lead enforces; apply to every leg)

1. **Any FAIL verdict** on any leg → matrix stops; findings escalated before further cluster time.
2. **Two consecutive BLOCKED legs** → stop and reassess the harness, not the scenario. (r04 is BLOCKED #1; a BLOCKED Leg 4 would be #2 → stop.)
3. **Same-VM recovery failure** (post-chaos follow-up cannot run on the recovered VM) → stop, preserve resources. (r01 tripped this once — `blocked_reasons` `vm_ready`/`vmi_running`/`cbt_enabled`; retried once under the 2-attempt rule and passed as r02. Budget spent.)
4. **Cluster degradation or capacity starvation** (controller replicas not recovering, PVCs pending, node pressure) → stop immediately.
5. **Checkpoint/tracker misadvancement, or a usable checkpoint from the failed copy / an orphaned checkpoint after a completed non-deleted backup** → stop and file the product defect.

## Limits

- At most **4 sequential legs** (Legs 1–3 are done; Leg 4 is the cap).
- Max **5 experiments per batch**.
- Max **2 attempts** for a suspected transient failure (already consumed once by the r01→r02 same-VM recovery failure).
- This is a proposal only: it is for Lead/human approval and nothing is executed from this document.
