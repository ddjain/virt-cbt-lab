# CBT-EXP-08 — consolidated chaos report

The Lead updates this scenario-root report after every terminal attempt,
including INVALID and BLOCKED, before an optional repaired retry. Historical
archived evidence is linked as recorded, never moved or retroactively regraded.

## Scope

[scenario-spec.md](scenario-spec.md) (EXP-8: tracker deletion mid-copy — second entry path to the no-deadline wedge) and the prepared validation contract [jira-issue.md](jira-issue.md). Approved scope (all iterations): one fresh run-owned VM via `make vm-setup`/`make vm-backup`, one UID-preconditioned mid-copy deletion of the run's own `VirtualMachineBackupTracker` through an owned oc proxy, 900s terminal-or-stuck observation with both-replica controller log window, and a bounded recovery leg (wedged-CR delete ≤300s never forced, tracker re-apply only if absent, fresh-named forceFullBackup + operand checks; no restore leg per spec). Historical note: a 2026-10-14 predecessor run (`artifacts/CBT-EXP-08/runs/20261014-exp08-r01/`, earlier harness) is archived evidence, not a v2 attempt.

## All terminal attempts

| Attempt ID | Date (UTC) | Lifecycle evidence | Verdict | Per-run report | Bundle / approval reference | Previous / repaired attempt | Summary |
|---|---|---|---|---|---|---|---|
| 17-10-2026-05-25-05-vm-20261017052505-fuzzy-forest-7700-tracker-delete-iteration-1 | 2026-10-17 | none — lifecycle never started | BLOCKED | [run-report](runs/17-10-2026-05-25-05-vm-20261017052505-fuzzy-forest-7700-tracker-delete-iteration-1/run-report.md) | request `cbt-exp08-bundle-20261017T050500Z`, fingerprint `821311fe…` (preserved in-run) | none | Approved bundle fail-closed at its hash gate: shared checkout `Makefile` changed out-of-band after preflight; no injection, no mutation. Resolution review: no code change; FIX-1/2/3 (approval-time live re-hash, pre-execute re-hash, dispatcher sync freeze) |
| 17-10-2026-09-14-43-vm-20261017091443-brave-forest-90a3-tracker-delete-iteration-2 | 2026-10-17/18 | `runs/20261017091443-brave-forest-90a3/` (setup only) | BLOCKED | [run-report](runs/17-10-2026-09-14-43-vm-20261017091443-brave-forest-90a3-tracker-delete-iteration-2/run-report.md) | request `cbt-exp08-bundle-20261017T091500Z`, fingerprint `c41c07ac…`; approval.json twice clobbered out-of-band and restored (verified by Main) | retry of iteration-1 | Setup completed; entrypoint hung ~64 min — jq writing identities-before.json (run.sh:988) lacked `-n` and blocked on inherited stdin; Lead SIGTERM, trap closed cleanly; no injection. Resolution review → FIX-A (`jq -n`) + FIX-B (`exec </dev/null`), whole-file audit clean |
| 18-10-2026-01-23-38-vm-20261018012338-calm-mountain-1744-tracker-delete-iteration-3 | 2026-10-18 | `runs/20261018012338-calm-mountain-1744/` | INVALID | [run-report](runs/18-10-2026-01-23-38-vm-20261018012338-calm-mountain-1744-tracker-delete-iteration-3/run-report.md) | request `cbt-exp08-bundle-20261018T013000Z`, fingerprint `d9bd2cd8…` | attempt 3 | Genuine active-copy window proven; same-instant revalidation falsely failed on an operand key mismatch (run.sh:1183 read `.metadata.uid` where condition.json stores `.backup_uid`) → exit 4 WINDOW_MISSED, no fault action. Replay with the correct UID passes. Grading owner confirmed INVALID; one-repair policy repair applied |
| 18-10-2026-10-07-15-vm-20261018100715-wild-falcon-ad5d-tracker-delete-iteration-4 | 2026-10-18 | `runs/20261018100715-wild-falcon-ad5d/` | **FAIL** | [run-report](runs/18-10-2026-10-07-15-vm-20261018100715-wild-falcon-ad5d-tracker-delete-iteration-4/run-report.md) | request `cbt-exp08-bundle-20261018T101500Z`, fingerprint `b2114ff8…` (run.sh `659e7845…` post-repair) | the single authorized repaired retry after the iteration-3 INVALID | **Wedge reproduced from the API-side entry path.** Valid injection (tracker DELETE 200, GET 404, watch event, exclusions clean). Backup never terminal in 900 s (60/60 samples, finalizer retained, resourceVersion frozen — a *silent* wedge). Product never recreated the tracker. Wedged CR undeletable while the tracker was absent (300 s, 145 samples); released only after tracker re-apply; fresh forceFullBackup verified (11/11). Grading owner confirmed FAIL; bug filed |
| 19-10-2026-08-32-54-vm-20261019083254-wild-mountain-cf47-tracker-delete-iteration-5 | 2026-10-19 | `runs/20261019083254-wild-mountain-cf47/` | **FAIL (reproduction confirmed)** | [run-report](runs/19-10-2026-08-32-54-vm-20261019083254-wild-mountain-cf47-tracker-delete-iteration-5/run-report.md) | request `cbt-exp08-bundle-20261019T083500Z`, fingerprint `f750bf6f…` (Makefile-only re-pin `734f6b30…`; scenario files identical to iteration 4; same build verified) | USER-REQUESTED reproducibility confirmation of iteration 4 (fresh request, not a repair retry) | **Same defect, same shape and magnitude, on distinct run-scoped resources and the same build (OCP 4.22.15 / CNV 4.22.12, identical virt-controller digest).** Valid injection (DELETE 200, GET 404, watch event, clean blast radius); 60/60 stuck samples (rv frozen, finalizer retained); tracker never recreated by the product; CR-deletion deadlock 300 s (145 samples) with tracker-404 reason, released only after tracker re-apply; recovery backup verified 11/11. Grading owner confirmed FAIL and **established recurrence** (symptom recurrence, not causality); bug updated with the second reproduction |

Per-run reports live at `runs/<attempt-id>/run-report.md` within this scenario.
Include every terminal attempt, not only successful or valid injections; retain
the original INVALID attempt when a repaired attempt is added.

## Counts

- Total terminal attempts: 5
- PASS: 0
- Product FAIL: 2 (one original + one user-requested reproduction, same defect)
- INVALID injection: 1
- BLOCKED prerequisites: 2
- INCONCLUSIVE product evidence: 0

The five verdict counts sum to the total. INVALID, BLOCKED and INCONCLUSIVE
are not product failures and must not be folded into a product failure rate.
An expected interrupted-backup exit is not itself a product FAIL.

## Confirmed product defects and recurrence

| Deduplicated defect | Bug draft | Supporting attempts / evidence | Observed impact | Root cause status |
|---|---|---|---|---|
| Mid-copy tracker deletion wedges the in-flight backup (silent no-terminal wedge, finalizer retained, destination volume attached ~20 min) and deadlocks the backup CR's own deletion until the tracker is recreated; tracker never recreated by the product | [bugs/mid-copy-tracker-deletion-wedges-backup-and-cr-deletion.md](bugs/mid-copy-tracker-deletion-wedges-backup-and-cr-deletion.md) (cross-references the EXP-06 family ticket; **Reproduced.** per its recurrence section) | iteration 4 (graded FAIL) + iteration 5 (graded FAIL reproduction, distinct resources, same build, identical virt-controller digest; recurrence established — symptoms, not causality); archived 2026-10-14 predecessor as a lead | Loss of backup coverage for the VM; operator must know the recreate-tracker-first repair order; destination volume stays attached during the wedge | Suspected controller tracker-dependency in the completion and abort paths (`backup.go:1088`/`backup.go:1003` abort-path anchors observed in both graded attempts); pre-delete wedge is silent (zero log lines, frozen resourceVersion) — precise function unproven, no source read |

The independent Analyst maintains one `bugs/<defect-slug>.md` per confirmed
observed product defect across attempts. Unknown causes are allowed; unknown
product outcomes, injection defects and harness issues do not create bugs.

## Injection, harness and evidence limitations

- Iterations 1–3 were harness/environment failures (Makefile drift; jq stdin hang; revalidation operand key mismatch), each closed, reviewed by a dedicated resolution-review agent, and repaired under the blocked-resolution/one-repair policies. No product evidence before iteration 4.
- Iterations 4–5 evidence limits (grading owners): the pre-delete wedge is *silent* — zero run-scoped virt-controller lines exist between the tracker delete and the CR delete (verified live on both replicas in both attempts), so the spec §5 "requeue/404 in controller-window.log" mechanism clause is affirmatively NOT met; the FAIL rests on the sample/finalizer/resourceVersion evidence and the abort-path deadlock. Harness follow-up for future scenarios: pin an additional controller-log pull to the wedged-CR delete instant / recovery-done. Host/storage release: API-level CLEAR (attachment chain observed releasing; no VolumeAttachment references), host layer UNKNOWN by design. Restore correctness not exercised (NOT_INCLUDED_BY_SPEC).
- Harness noise in iterations 4–5 (non-product): `rc=143` full-stage join (orchestrated), trap `wait: not a pid` messages for reaped watcher pids.
- Reproducibility scope: two executions on one cluster/build are not a controlled experiment; recurrence of symptoms is established, not identical causal mechanism (root cause undetermined).

## Proposed scenarios — not executed or approved

None. No `proposed_scenarios` were created by this scenario's Lead, grading owners or specialists (`run.json.proposed_scenarios=[]` in all attempts; both FAIL-attempt grading owners filed/updated the product bug instead).

## Coverage, recovery and report notes

- Scenario outcome: **FAIL, reproduced.** The wedge is reachable from the API-side operator action (tracker deletion mid-copy), on the current build, with two independent evidence-complete reproductions on distinct run-scoped resources. The resilient alternative was not observed in either product attempt.
- Recovery knowledge validated twice: deleting the wedged CR alone does not clear it while the tracker is absent; recreating the tracker (any backup manifest re-apply for the VM) unblocks the abort, after which a fresh full backup completes and verifies.
- Retained run-owned objects (no-cleanup design): iterations 2–5 VMs/PVCs, iteration-4/5 re-applied trackers (advanced to their recovery checkpoints), destination/recovery PVCs and recovery backups; both wedged CRs and both original trackers are gone (released via the recovery legs).
- Generic evidence-backed lessons are deduplicated by the Lead in its skill's `improvement.md` (EXP-08-sourced: approval-time live re-hash, jq `-n`/stdin audit, UID-gate null-assertion, rehearsal-root isolation, silent-wedge resourceVersion surfacing, controller-log pull timing), not here.
