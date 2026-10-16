# Agent improvement plan — items I do not accept as written

Revisit list for `virt-cbt-lab-consolidated-agent-improvement-plan.md`.
Every entry: the plan's claim, the evidence that contradicts or under-specifies
it, why it matters, and what to do instead. Nothing here was silently dropped —
each item is either implemented differently or explicitly out of scope for this
iteration.

Status legend: **CONTRADICTS-REPO** (the plan's premise is false for this
checkout), **UNSAFE-IF-TAKEN-LITERALLY**, **SCOPED-OUT** (true but larger than
this iteration), **AMBIGUOUS**.

---

## F1 — "Never default to `make e2e`/`TYPE=all`" collides with CBT-F-01's own contract (UNSAFE-IF-TAKEN-LITERALLY)

- **Plan:** §2 "**Never default to `make e2e` / `TYPE=all` for each chaos experiment.**"
- **Evidence:** CBT-F-01 acceptance criterion 6 requires "a separate clean `TYPE=all` lifecycle using a new run ID … this produces a fresh full backup, an incremental backup, and repository restore/data verification" (`cbt-chaos/scenarios_v2/CBT-F-01/scenario-spec.md`, §4 criterion 6 and §2). The interrupted leg itself is `make e2e TYPE=full` by design (`chaos-trigger.sh:111-122`).
- **Risk:** an agent applying the blanket rule would refuse or "optimise away" a run step that the scenario's pass criteria depend on, producing a false INVALID or a weakened claim.
- **Instead:** the rule is "the smallest valid stage **that satisfies the current acceptance criterion**". Add the exception explicitly to the skills (done) and keep the criterion as the authority.

## F2 — The stage-per-experiment table assumes stages are freely re-runnable (CONTRADICTS-REPO)

- **Plan:** §2 table presents `make vm-backup RUN_ID=<id>`, `make vm-cbt-backup RUN_ID=<id>`, … as a general "preferred command shape" for any experiment.
- **Evidence:** stages are state-machine transitions, not idempotent commands. `vm-cbt-backup.sh:14-22` exits 1 when the plan is complete ("use `TYPE=extend`") and `:26-29` on the wrong lifecycle state; `stage.sh:263-274` exits 2 without `runs/<id>/run.json`; a second full backup on a completed lifecycle is not a supported transition; `TYPE=incremental` requires the *next planned* pass.
- **Risk:** "choose the smallest valid stage" is only safe with the state machine in view; without it, an agent will retry a stage the lifecycle forbids and report a harness failure.
- **Instead:** read `runs/<id>/run.json status` (+ `make stage-list`) before selecting a stage; treat a rejection as a state error, not a product failure. Documented in `docs/agent-workflow-audit.md` §1-2 and in the skills.

## F3 — §4's spawn-reduction table is actionable, but its premise needed the right tree (CORRECTED)

- **Plan:** §4 table ("keep `chaos test team` as lead", "keep one focused monitor", make evidence/injection/CBT verifiers conditional, …) and §3's four review lenses.
- **Evidence:** on `main` (PR #32, `ab93fbe`) the full topology exists under `.agents/skills/`: `cbt-chaos-team` (332 lines) plus 13 role skills and `krkn-scenario`. The first audit pass saw only two skills because the working tree predated that consolidation, so the review's claim that "the §4 table describes a team that no longer exists" was wrong for `main` — corrected here.
- **Actual state:** the single-agent runner already spawns one monitor and forbids a second analyst, which satisfies §4's "one focused monitor". The team Lead already forbids a duplicate observer and requires keyed contracts. What was missing is that neither the Lead nor the runner routed repeated operational checks to scripts: no skill referenced `make stage-list`, the deterministic evaluator, the `STAGE_SKIP_PREFLIGHT` prohibition or the shared audit document.
- **Instead:** keep the 13 roles (they are judgement/observation roles, not relays), and add the missing policy layer — done in both the runner skill and `cbt-chaos-team` ("Lead operating policy", deterministic-verdict reconciliation, `--plan` before `resync`, timings-as-evidence, spawn economy).
- **Process lesson:** resolve "the repository" from a fetched `main` before auditing a plan against it; an audit against a stale working tree produced a wrong conclusion about which skills exist.

## F4 — Model-call/token metrics are not measurable in this harness (SCOPED-OUT → substituted)

- **Plan:** §11 "Measure per run: … Agent spawns/model calls where measurable", §14 "Before/after duration, unnecessary full-E2E count, agent calls, repeated checks".
- **Evidence:** the harness records no token or model-call telemetry. The only deterministic timings are `Step timing: target=… elapsed_seconds=` (`scripts/e2e-stage.sh:321-343`) and the backup timings in `run.json`/`summary.json` (`monitor.sh:136-195`).
- **Instead:** measured wall clock per stage (now persisted into `run.json .stage_timings` and `summary.json .phases`) plus the count of spawned agents recorded by the runner. Token accounting stays a manual observation of the session, not a claim.

## F5 — The 10-20 case evaluation suite does not exist and is not one iteration (SCOPED-OUT)

- **Plan:** §11 "Start with 10-20 realistic tasks …", §10 Phase 2 "Cover at least: [11 negative cases]", "Use fixtures/mocks for evaluator and dispatch tests".
- **Evidence:** `make test` runs 19 hermetic tests (`Makefile:216-235`); of the plan's 11 negative cases, most mapped to no test: `clean-all` refusal, preflight-success≠backup-success, missing-injection-evidence ⇒ INVALID, RUN_ID mismatch, checkpoint mismatch, injection wrong-target, cleanup failure, budget stop (see `docs/agent-workflow-audit.md` §5 G10).
- **Covered since (this iteration):** missing/withheld injection evidence ⇒ never PASS, RUN_ID mismatch ⇒ FAIL, successful backup under an interruption scenario ⇒ INVALID, **injection wrong-target ⇒ INVALID**, **mismatched/attributed checkpoint evidence ⇒ FAIL**, **observer absent ⇒ INCONCLUSIVE (the injector is not the sole authority)**, **signal predating the observer's arming instant ⇒ INCONCLUSIVE**, all in `tests/test-scenario-verdict.sh`.
- **Still uncovered:** `make clean-all` refusal and unhealthy-preflight ⇒ BLOCKED (both need a fake-cluster/preflight harness), cleanup failure, and the experiment-budget stop. These are filesystem-/cluster-shape cases, not evaluator logic, so they remain part of the not-executed record rather than claimed as done.
- **Instead (this iteration):** added the negative cases that a new deterministic evaluator can own (missing injection evidence ⇒ not PASS, run-id mismatch ⇒ FAIL, succeeded backup under an interruption scenario ⇒ INVALID). The rest need a live-cluster or fake-cluster fixture harness; listed for the next iteration rather than claimed as done.

## F6 — Windows CBT-F-01 cannot meet the <15 min target (CONTRADICTS-REPO)

- **Plan / scenario:** the spec pinned the execution variant to `VM_OS=windows` with `GUEST_EXEC_POLL_ATTEMPTS=900` (33 min budget).
- **Evidence:** `runs/20261010-cbt-f-01-r08/logs/workflow.log` — `vm-setup` 2133 s, of which ≈32 min is `QEMU Guest Agent status query failed … attempt N/900`; a second recorded Windows `TYPE=all` leg died in incremental mutation after 2072 s (exit 141, `runs/20261010-cbt-f-01-r08-wrec`). RHEL 9 legs are 137 s / 175 s / 572 s (`runs/20261012-cbtf01-r01`).
- **Risk:** a "<15 min" gate on the Windows variant is unreachable for reasons unrelated to the agentic flow, so the gate would measure the wrong thing.
- **Instead:** OS and guest sizing are caller inputs (spec updated to say so). The agentic-flow gate is measured on the RHEL 9 variant; the Windows variant is recorded as a separate, slower configuration with its own budget. Root-causing the 32 min guest-agent outage is a harness task, not an agent-flow task.

## F7 — "Shared audit/contract document" must not be `cbt-chaos/contracts/*` (AMBIGUOUS)

- **Plan:** §12 "Link to `make help`, `make stage-list`, and the shared audit/contract document."
- **Evidence:** `cbt-chaos/contracts/{observer,trigger,recovery,preflight,report-writer,check-*}.md` are CBT-F-04-flavoured (`contracts/observer.md:5`, `contracts/trigger.md:6`), and `cbt-chaos/contract-gen.sh:44-54` substitutes only `__RUN_ID__`-style tokens, so the scenario identity inside them stays F-04.
- **Instead:** the shared contract is `docs/agent-workflow-audit.md` (stage semantics, exit codes, artifacts). The per-run `contracts/` remain the F-04 campaign's artifacts and are flagged for parameterisation.

## F8 — "Do not inspect existing artifacts" versus the Phase 0 baseline (AMBIGUOUS)

- **Plan:** §10 Phase 0 requires recording the baseline run time, retries and evidence quality; the run skill forbids reading prior runs (`SKILL.md:24,86`) so that history cannot influence a new verdict.
- **Evidence:** both rules are in force simultaneously; `cbt-chaos/scenarios_v2/CBT-F-04/runs/…/ledger.jsonl:18` already records that stray reads caused confusion.
- **Instead:** the ban applies to the *runner* of a scenario; the *improver* may read prior artifacts for timing/Baseline metrics only, must not feed them into a scenario verdict, and must record that use. Stated in `docs/agent-workflow-audit.md` §3.

## F9 — `monitor.sh` is unbounded (CONTRADICTS-REPO, fixed)

- **Plan:** §6 "No indefinite waits", §11 "Zero unbounded retries/planning loops".
- **Evidence:** `scripts/monitor.sh:66,211` polls every 2 s until every planned backup is Done or one fails; a planned-but-never-run backup blocks forever. `e2e-stage.sh:545-561` avoids this only by skipping the monitor when passes are incomplete.
- **Instead (proposed):** add `MONITOR_TIMEOUT_SECONDS` (default e.g. 1800) and exit non-zero with the outstanding backup names. Needs its own small change + test; recorded here for the next iteration because it is shared-harness behaviour outside the agentic flow.
- **Fixed:** `scripts/monitor.sh` now honours `MONITOR_TIMEOUT_SECONDS` (default 1800; `0` = explicit unbounded opt-in), prints the outstanding backup labels/names, and exits **2** so a caller can tell a timeout from a failed backup (`monitor.sh:68-78,223-242`). Covered by `tests/test-monitor-timeout.sh`, documented in `.env.example` and in the matrix row.

## F11 — Stale `watch-resource.sh` watchers survive on the execution host (CONTRADICTS-REPO, fixed)

- **Plan:** §6 "no indefinite waits", §11 "Every run reaches an explicit terminal state".
- **Evidence:** the iteration-2 witness found 10 unrelated `watch-resource.sh` processes still running on the execution host from earlier runs; its own four were removed on teardown. `watch-resource.sh` has no timeout and only revokes readiness on exit (`cbt-chaos/watch-resource.sh:104-110`).
- **Risk:** accumulated watchers keep hitting the API server and can make "is a watch armed?" checks noisy for later runs.
- **Instead (proposed):** give the helper an optional `WATCH_MAX_SECONDS` self-termination and have the run flow record the PIDs it owns so a later run can report (not kill) foreign watchers. Recorded here rather than changed in this iteration because it alters a shared helper's contract.
- **Fixed:** `cbt-chaos/watch-resource.sh` honours `WATCH_MAX_SECONDS` (default `0` = no self-termination, so existing callers keep their contract). On expiry the armed watch is terminated, readiness is revoked, the log names the bound, and the helper exits **3** — distinguishable from a watch that ended on its own (1) or a usage/environment error (2). `WATCH_MAX_SECONDS=3` covers it in `tests/test-chaos-watch-resource.sh`. The "record the PIDs it owns" half is satisfied by the existing `watch_pid=` line in the readiness marker, which the observer's handoff payload carries.

## F12 — Trigger's pre-injection libvirt checkpoint tree is not actually captured (CONTRADICTS-REPO, fixed)

- **Plan / scenario:** the CBT-F-01 spec asks for the launcher's checkpoint tree before and after the disruption.
- **Evidence:** iteration 2's `trigger/trigger.log` shows `Pre-backup checkpoint tree:` with no content, while the tracker watch and the failed backup's `status.checkpoint` were both captured. The trigger's `oc exec … virsh checkpoint-list` returns empty on a fresh VM (no checkpoints yet) and the empty result is indistinguishable from a failed capture.
- **Instead:** record the command's exit status alongside its output, and state in the spec that an empty tree on a fresh lifecycle is expected. The tracker watch plus `tracker_checkpoint_at_failure: ""` already carry the criterion.
- **Fixed (trigger side only):** the capture now distinguishes the two cases explicitly: it records the exit status and the output line count, logs `Pre-backup checkpoint tree (exit=0, lines=N; empty is expected on a fresh lifecycle)`, and on a non-zero exit logs `Checkpoint tree capture failed (exit=N, lines=M); retrying on the next poll` instead of marking the baseline captured (`chaos-trigger.sh:321-342`). `tests/test-cbt-f-01-injection-evidence.sh` asserts the log shape so the two states cannot be conflated again. **Still open (spec side):** the "Instead" also asks the *spec* to say that an empty tree is expected on a fresh lifecycle; `scenario-spec.md` criterion 3 asks for the tree but does not state that, and the sentence is written as diff S1 in `cbt-chaos/scenarios_v2/CBT-F-01/analysis/20261016-cbt-f-01-r04-improvements.md`. It was not applied here because spec edits are human-gated (they change what the team accepts as truth).

## F13 — The interrupted lifecycle's `summary.json` mixes per-invocation verdicts (AMBIGUOUS, fixed additively)

- **Plan:** §7 "Use a deterministic evaluator over structured evidence"; §11 "Keep environment outcomes and the agent's process quality separate".
- **Evidence:** for `20261016-cbt-f-01-r03` the lifecycle `summary.json` reports `verdict: PASS` because the same file is rewritten by each invocation and the last one was the recovery stage, while its own `.cbt.status` and `.restore_hashes.status` remain `PENDING` — the interrupted lifecycle never ran chain/restore verification. The independent witness read this as a contradiction.
- **Risk:** a reader (or a future evaluator) can mistake an invocation verdict for a lifecycle verdict.
- **Instead (proposed):** keep `verdict` as the last invocation's result only if the key is named for it (e.g. `last_invocation_result`), and make the lifecycle-level verdict explicit (`complete`/`incomplete`/`blocked`) so the two can never be confused. `scenario-verdict.sh` already reads the recovery attempt and clean-lifecycle summary explicitly rather than trusting this field.
- **Fixed (additively, so no consumer breaks):** `summary.json` now carries `verdict_scope` (`lifecycle` or `recovery_invocation`) beside the top-level `verdict`, plus a lifecycle-scoped `lifecycle.verdict` computed only from run state and verification (`write-run-summary.sh:79-91,113-114,130-135`). The interrupted-lifecycle case is now readable as `verdict: PASS, verdict_scope: recovery_invocation, lifecycle.verdict: FAIL` instead of a bare PASS. Asserted by the new `summary-recover-scope` fixture in `tests/test-run-summary.sh`.

## F10 — Trigger exit code is ambiguous by construction (partially fixed)

- **Plan:** §7 "the injecting agent cannot be the sole authority"; §11 "flip a right scenario to INVALID".
- **Evidence:** `chaos-trigger.sh` exits `1` both when the observer failed (no signal/baseline/timeout) and when the E2E unexpectedly succeeded; only stderr distinguishes them, and neither writes an artifact.
- **Fixed:** the trigger now writes `trigger/exit-statuses.json` and `trigger/effect-check.json`, and `scenario-verdict.sh` distinguishes observer failure (BLOCKED) from an un-interrupted backup (INVALID).
- **Still open:** the process exit code itself remains ambiguous for a human reading only the terminal; changing the contract would break the documented "expected non-zero" semantics, so it is left as is and flagged.
