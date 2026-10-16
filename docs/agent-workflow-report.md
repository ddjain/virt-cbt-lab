# Agentic-flow improvement report (plan §14)

Implementation record for `virt-cbt-lab-consolidated-agent-improvement-plan.md`.
Companion to `docs/agent-workflow-audit.md` (capability matrix, baselines) and
`docs/agent-workflow-flag.md` (disputes and scoped-out items). Everything below
is measured from artifacts on disk; unmeasured items are labelled as such.

## 1. What changed, and why

| # | Change | Plan item | Why it was needed (evidence) |
|---|---|---|---|
| 1 | `cbt-chaos/scenario-verdict.sh` — deterministic verdict over run artifacts (8 checks, JSON contract, exit 0 only for PASS) | §5, §7, §10 Phase 2 | The verdict existed only as prose in the skill; every run re-derived it with LLM judgement over loose artifacts |
| 2 | CBT-F-01 trigger writes `trigger/{command.txt,action-request.json,effect-check.json,exit-statuses.json,trigger.log}` | §5, §7 | Criterion "the launcher was replaced after the delete" was printed to stderr and never recorded, so nothing could check it (`chaos-trigger.sh:37-41,59-66`) |
| 3 | `chaos-trigger.sh --plan` | §12, triage §4a | The triage skill demanded a rehearsal mode no trigger implemented; `bash -n` cannot catch a deleted variable assignment |
| 4 | Signal gate `oc logs --follow --since-time=<armed>` | §5, §7 | The log follow matched from the beginning of the pod log, so a stale `Backup started` line on a long-lived pod could fire a false injection |
| 5 | `run-cbt-f-01.sh` scenario driver (3 contractual legs + per-leg timings + evaluator) | §6, §5 | Leg sequencing was manual LLM work; the driver makes ordering, run ids and timings deterministic and repeatable |
| 6 | Per-stage timings persisted: `run.json .stage_timings`, `.total_elapsed_seconds`, `summary.json .phases` | §11 | Stage wall clock existed only as free text in `workflow.log`, so "why was this slow" could not be answered from a summary |
| 7 | Bounded pre-recovery readiness wait (`RECOVERY_READY_TIMEOUT_SECONDS`) in `vm-cbt-recover.sh` | §6, §10 Phase 1 | Iteration 1 blocked on `precondition failed: vm_ready/vmi_running/cbt_enabled` because recovery ran ~15 s after the VM restart |
| 8 | `TYPE=reconcile` accepted end to end | §12 | `make help` advertised it, `e2e-stage.sh` implemented the branch, but TYPE validation rejected it (unreachable) |
| 9 | Both skills: `make stage-list`, narrowest-stage rule, `STAGE_SKIP_PREFLIGHT` prohibition, audit-doc link, `--plan` rehearsal, deterministic-verdict step, bounded-investigation budget | §12 | Only `make help` was required; the preflight-bypass prohibition and the shared contract document were missing |
| 10 | Both live skills no longer hard-depend on worker skills being present; obsolete worker/analyst references became conditional | §3, §4 | The two live skills referenced `krkn-scenario` / `cbt-chaos-krkn-preparer` as mandatory even when the active harness does not provide them, and this checkout had broken `.claude/skills/*` links because the tree was mid-consolidation |
| 11 | Three new offline tests: `test-scenario-verdict.sh`, `test-cbt-f-01-driver.sh`, `test-cbt-f-01-injection-evidence.sh` (+2 cases in `test-vm-cbt-recover.sh`, +1 in `test-run-summary.sh`, +`TYPE=reconcile` in `test-incremental-passes.sh`) | §10 Phase 2, §11 | No test covered a deterministic verdict, and nothing tied the trigger's artifact shape to the evaluator's parser |
| 12 | `cbt-chaos-team` (the Lead orchestrator) gained a "Lead operating policy (stage-aware, deterministic-first)" section and deterministic-verdict reconciliation in its execution sequence | §4, §6, §12 | On `main` the team topology exists (17 skills, 13 roles) but the Lead skill referenced neither `make stage-list`, nor the evaluator, nor the preflight prohibition. The first audit pass missed it because the working tree predated PR #32; see flag F3 |

Deliberately not added: a new backup/restore verifier (plan §5 requires the
existing `vm-cbt-verify.sh`, `vm-cbt-restore-test.sh` and `write-run-summary.sh`
to be inspected first — they already prove chain and restore integrity, so the
new script only synthesises their evidence into a verdict).

## 2. Agents invoked per scenario run

| Phase | Before | After |
|---|---|---|
| Lead | in the session | in the session |
| Monitor | one read-only monitoring subagent | unchanged (one), but its inputs now include the deterministic artifacts and its three handoffs are unchanged |
| Analyst | forbidden by the skill already | unchanged |
| Skeptical reviewer | conditional | unchanged |
| Verdict | produced by LLM prose | produced by `scenario-verdict.sh`; prose may explain but not override |
| Investigator | prose-only conditions | explicit budget/attempt/terminal-status contract added to the skill |

No new agent type was introduced; the change is that the verdict no longer needs
one.

## 3. Iterations measured (CBT-F-01, RHEL 9, `large-odf`, 1000 × 15-20 MiB files)

| Iteration | Run id | Leg 1 (`chaos-trigger.sh`) | Leg 2 (`TYPE=recover`) | Leg 3 (`TYPE=all`) | Flow wall clock | Deterministic verdict |
|---|---|---|---|---|---|---|
| 1 | `20261016-cbt-f-01-r01` | 124 s, injection verified | **blocked in 2 s** — VM still restarting | not run (driver aborted) | 2 min 11 s | not produced (flow defect) |
| 2 | `20261016-cbt-f-01-r02` | 125 s, injection verified | **PASS 60 s** (readiness confirmed after 9 s) | **PASS 383 s** | 9 min 33 s | `INCONCLUSIVE` — two evidence-extraction gaps, see §5 |
| 3 | `20261016-cbt-f-01-r03` | 152 s, injection verified | **PASS 53 s** | **PASS 374 s** | **9 min 43 s** | **`PASS`, all 8 checks PASS, exit 0** |

Iteration 3 stage attribution (`run.json .stage_timings` + the clean lifecycle's inner steps):

| Leg | Composition |
|---|---|
| interrupted full (152 s) | `vm-setup` 119 s (VM create + 18.3 GB baseline + hash) + `vm-backup` 23 s (CR create → terminal failure after the pod delete) |
| same-VM recovery (53 s) | bounded readiness wait (~10 s) + forced full backup + baseline restore comparison |
| clean lifecycle (374 s) | VM setup 101 s + full 77 s + incremental pass 116 s + CBT verification and restore test 78 s |

Harness floor for reference: the same three legs measured 137 s + 175 s + 572 s
(≈14.7 min) on 2026-10-12 (`runs/20261012-cbtf01-r01`), i.e. before the e2e
perf pass. Iteration 2 completed the same protocol in 9 min 33 s end to end.

No `make clean-all` was used in any iteration; every run's resources and failed
artifacts remain on the cluster for inspection.

## 4. Verification performed

- Offline: `make test` — 18 hermetic test scripts, exit 0, 20 `PASS:` lines,
  including the three new ones (deterministic verdict incl. negative cases;
  driver leg order/timings and a pre-armed observer directory; trigger↔evaluator
  evidence contract).
- Offline: `bash -n` on every changed shell file.
- Offline: the evaluator was run read-only against live F-04 artifacts and
  correctly returned `INVALID` (successful backup, no injection evidence).
- Live: three CBT-F-01 executions; the injection leg passed in all three
  (independent monitor corroboration in each: exact launcher UID removed
  in-window, `Done=True` with the failure reason, tracker never advanced, CBT
  back to `Enabled`).
- Live: the evaluator was executed as part of the driver and its JSON verdict is
  the run's result.

## 5. Iteration 3 result — the validated run

`bash cbt-chaos/scenarios_v2/CBT-F-01/run-cbt-f-01.sh` with `RUN_ID=20261016-cbt-f-01-r03`
exited **0** and the evaluator returned **`PASS`** with all eight checks PASS:

| Check | Status | Evidence |
|---|---|---|
| `run-id-consistency` | PASS | lifecycle `run.json` and every trigger/observer artifact reference only `20261016-cbt-f-01-r03` |
| `injection-signal` | PASS | `trigger/action-request.json`: pod `…-tw62d`, UID `53bb0d2b…`, signal 21:25:30Z, armed 21:23:19Z |
| `launcher-replacement` | PASS | `trigger/effect-check.json`: old UID gone, replacement `…-d2cwk` UID `d6edbaaa…` ready, elapsed 21 s |
| `backup-interrupted` | PASS | `Full`, `Done=True`, `Backup has failed: VMI backup status was lost`, failed PVC Bound and preserved |
| `tracker-not-advanced` | PASS | `latestCheckpoint` unset at failure; the checkpoint stamped on the failed object was never published |
| `cbt-recovered` | PASS | `recovery.attempts[0].vm.cbt_state=Enabled`, VMI Running, replacement launcher Ready |
| `same-vm-recovery` | PASS | attempt `r001` success, 11/11 restore checks passed, baseline count/bytes/hash matched |
| `clean-lifecycle` | PASS | `20261016-cbt-f-01-r03-clean` verdict PASS, all restore-hash groups PASS |

The same evaluation was repeated from the local checkout after pulling the
artifacts (`scenario-verdict.sh … --scenario-dir cbt-chaos/scenarios_v2/CBT-F-01
--run-id 20261016-cbt-f-01-r03 --lifecycle-run 20261016-cbt-f-01-r03
--clean-lifecycle-run 20261016-cbt-f-01-r03-clean`) and returned the same PASS
with exit 0, so the verdict is reproducible off-cluster from the artifacts alone.

Run reports written per the skill's templates:
`cbt-chaos/scenarios_v2/CBT-F-01/runs/20261016-cbt-f-01-r03/test-run-result.md`
and `test-run-report.md` (copied back to the execution host).

The independent read-only witness reported **full agreement** with the trigger's
artifacts — including the replacement launcher's name and UID
(`virt-launcher-vm-20261016-cbt-f-01-r03-d2cwk`, `d6edbaaa…`), which it had
observed itself from its own pod watch — and confirmed it removed every watch it
started. It reported three honest gaps: its own launcher-log capture died during
`PodInitializing` (so the exact `Backup started` second stays trigger-only, with
the backup's in-progress condition plus the coincident pod-kill events as its
independent bound), no `virsh checkpoint-list` tree (its read-only mandate
excludes `oc exec`), and no qcow2 inspection of the failed volume.

The same witness also timed the interrupted copy's progress: the backup went
from `Progressing=True` to terminal failure within ~12 s, versus 76 s for the
same full copy without disruption — i.e. the injection landed at the very start
of the copy window, which is inside the specified window but leaves little
margin. Raising the guest payload or lowering the poll cadence would widen it if
a later iteration needs more headroom.

Two defects were found by iteration 2 and fixed before iteration 3 — both were
evidence-recording bugs, not verdict-logic bugs, and the evaluator refused to
claim PASS while they were present:

1. The trigger declared the launcher replaced as soon as its pod query returned
   no matching ready pod, because an empty jq selection yielded a bare tab that
   read as a non-empty string. `effect-check.json` therefore recorded
   `replacement_pod.name="" uid=""` with `ready=true`. Fixed by requiring a
   non-empty replacement name and UID before the effect check can pass; the
   contract test now reproduces the race (first post-delete read sees no
   replacement).
2. The evaluator looked for CBT state only in `report.json` verification checks,
   `run.json .cbt` and `summary.json .cbt`, but the interrupted lifecycle records
   it in `run.json .recovery.attempts[].vm.cbt_state` and its
   `preconditions[cbt_enabled]`. Fixed and covered by a new fixture case that
   mirrors the real lifecycle shape.

## 6. Observations that are not flow defects

- Iteration 2: the immediate post-restart forced full backup
  (`vm-recovery-full-20261016-cbt-f-01-r02-r001`) reached `Done=True` with reason
  `Completed VirtualMachineBackup, warning: Failed freezing guest filesystem: virError(Code=86, … 'QEMU guest agent is not connected')`.
  The independent witness showed the same CR also emitted a
  `VirtualMachineBackupFailed: Backup has failed: VMI backup status was lost`
  event at the same second, **and that the clean lifecycle's fully successful
  full backup emitted the identical event pair**. The failure event is therefore
  a duplicate/spurious emission, not evidence of failure: a harness/telemetry
  observation, not a product finding. What remains worth knowing is the warning
  itself — for a backup taken seconds after a VM restart the guest filesystem was
  not quiesced, so crash-consistency was not established for that copy; the
  file-set claim was still verified (count/bytes/manifest hash matched the
  recorded baseline). **Reproduced twice** — `20261016-cbt-f-01-r02` and
  `20261016-cbt-f-01-r03` both took their forced recovery full backup within
  seconds of the VM restart and both carry the identical warning, and both
  restores matched. Per the two-reproduction rule this is eligible for a
  scenario-level `bugs/` draft; not drafted here because both copies completed
  and restored correctly, so the open question is crash-consistency of
  post-restart backups, not data loss.
- `trigger.log` records `Pre-backup checkpoint tree:` empty. For a fresh
  lifecycle that is the *correct* capture — `virsh checkpoint-list --tree`
  prints nothing when no checkpoint exists, and the baseline capture must have
  succeeded for the injection to fire at all. The defect is only that the log
  cannot distinguish "empty because fresh" from "capture failed": the command's
  exit status is not recorded. Criterion 3 is carried by the tracker watch
  (`latestCheckpoint` unset before and after) regardless.
- Windows CBT-F-01 remains a separate, much slower configuration (32-minute
  guest-agent stall in `runs/20261010-cbt-f-01-r08`); see flag item F6.

## 7. Remaining gaps

- No preflight/cluster-fake harness, so `clean-all`'s triage refusal and
  "preflight success ≠ backup success" remain untested (flag F5/G10).
- `monitor.sh` still polls without a bound (flag F9).
- `cbt-chaos/contracts/*` stay CBT-F-04 worded (flag F7).
- The evaluator's artifact-shape tolerance is broader than the shapes the repo
  actually writes; it can be narrowed once every scenario emits the documented
  artifacts.
- Token/model-call telemetry does not exist in this harness; only wall clock and
  spawn counts are measured (flag F4).

### 7a. Gaps closed in the 2026-10-16 review round

- `monitor.sh` is now bounded (`MONITOR_TIMEOUT_SECONDS`, exit 2 on expiry) —
  flag F9 fixed.
- `watch-resource.sh` gained an optional `WATCH_MAX_SECONDS` self-termination
  (exit 3, readiness revoked) so a forgotten watcher cannot outlive its run —
  flag F11 fixed.
- `summary.json` now separates the invocation verdict from the lifecycle verdict
  (`verdict_scope`, `lifecycle.verdict`) — flag F13 fixed additively.
- The CBT-F-01 trigger records the checkpoint-tree capture exit status and line
  count instead of logging an ambiguous empty block — flag F12 fixed.
- The deterministic evaluator now refuses three classes of false PASS that were
  previously undetectable: an injection whose only support is the injector's own
  artifacts (no observer marker/watch stream), an injection that provably removed
  a different pod than the signal named (INVALID), and a signal recorded before
  the observer armed (contradictory timing).
- `--plan` rehearsal now accepts the pre-armed run directory and still refuses
  run output or a missing observer, so the mandated rehearsal is satisfiable for a
  run that follows the protocol order (CBT-F-01, CBT-I-01; CBT-F-03 gained a
  `--plan` mode).
- Still open: the artifact-shape tolerance of the evaluator, the CBT-F-04-worded
  `cbt-chaos/contracts/*`, and the not-executed cases listed in
  `docs/agent-plan-incorrect-points.md`.

## 8. Plan-point review, 2026-10-16 (point by point)

Reviewer method: every point of
`virt-cbt-lab-consolidated-agent-improvement-plan.md` was checked against the
working tree (skills, scripts, Makefile, tests, docs). A point is `IMPLEMENTED`
only when the artefact that satisfies it exists and was inspected; `PARTIAL`
means part of it is genuinely not delivered, with the reason; points judged
**incorrect** are not implemented and are recorded with evidence in
`docs/agent-plan-incorrect-points.md` (P1-P7).

| Plan point | Verdict | Evidence | Action in this round |
|---|---|---|---|
| §1 single lead, stages/scripts for the deterministic parts, one monitor, no agent per skill | IMPLEMENTED | `cbt-chaos-team` "Lead operating policy" (spawn economy, one Observer, deterministic-first); `cbt-chaos-run` stage policy; one observer per run | unchanged (already satisfied); run 1 exercised it |
| §2 `make help`/`make stage-list` as the interface; target table; safeguards | IMPLEMENTED | `make stage-list` (11 rows, `scripts/stage.sh:27-55`); target table accuracy verified against `Makefile:45` and `stage.sh`; `cbt-chaos-run`/`cbt-chaos-issue-triage` require both | table cross-checked; omissions (`vm-cbt-reconcile`, `stage-list`) noted in the audit matrix |
| §2 "never default to `make e2e`" as a blanket rule | **INCORRECT as written** | CBT-F-01 criterion 6 requires a clean `TYPE=all` lifecycle | not implemented; recorded as `docs/agent-plan-incorrect-points.md` P1 |
| §2 stage table implies re-runnable stages | **INCORRECT as written** | stages are state-machine transitions (`vm-cbt-backup.sh:14-22`, `stage.sh:263-274`) | not implemented; P2 (state check required instead) |
| §3 four review lenses | IMPLEMENTED | this document + `docs/agent-workflow-audit.md` §3-§7 (harness/orchestration/verification/evaluation views) | applied in this round's audit |
| §4 keep the lead; one focused monitor; verifiers become scripts; conditional investigator; preparer reuses the skill; script-first reports; bounded planner | IMPLEMENTED | role skills: `cbt-chaos-observer-worker` (one observer), `cbt-chaos-report-writer` (evaluator JSON + templates), `cbt-chaos-krkn-preparer` (proposal-only, loads `skill://krkn-scenario`), `cbt-chaos-variation-decider` (≤4 legs) | §12 policy block added to all 13 role skills |
| §5 deterministic-tool-first (9 steps) | IMPLEMENTED | `cbt-chaos-run` "Deterministic tools before reasoning (mandatory)"; `cbt-chaos-issue-triage` "Deterministic tools, tests, and bounded investigation" | added this round to both live skills; team skill "Reuse before you build" |
| §5 script-audit deliverable (matrix with a skills/agents column, plus the chaos trigger) | IMPLEMENTED | `docs/agent-workflow-audit.md` §2: 10 columns incl. skills/agents, 24 rows incl. the trigger contract, the driver, the ledger helpers, the contract generator, shared helpers, Windows (out of the agentic flow) and density rows | completed this round |
| §6 lead execution policy (11 steps, contracts, no indefinite waits) | IMPLEMENTED | `cbt-chaos-run` phases 0-5; `cbt-chaos-team` execution sequence; every contract names a budget + terminal status | `monitor.sh` and `watch-resource.sh` bounds closed the "no indefinite waits" gap at the tool level |
| §7 verdict contract (5 verdicts + rules) | IMPLEMENTED | `cbt-chaos/scenario-verdict.sh` header contract; `cbt-chaos-run` "Deterministic verdict" | tightened this round: wrong-target ⇒ INVALID; injector-only evidence ⇒ UNKNOWN; signal-before-arming ⇒ UNKNOWN; `summary.json` scope separation |
| §8 investigation triggers, required output, exploration loop, limits | IMPLEMENTED | `cbt-chaos-run` "Bounded investigation"; `cbt-chaos-issue-triage` bounded-investigation routing; `cbt-chaos-team` stop conditions; `cbt-chaos-variation-decider` limits | triage skill gained the routing + limits this round |
| §9 evidence-backed learning store and finding fields | IMPLEMENTED | the §9 field set is now the documented entry schema in `.agents/skills/cbt-chaos-run/cbt-chaos-run-learnings.md` ("How to maintain this file": finding id · scenario/run · evidence paths · confirmed vs hypothesis · injection type/target/phase · environment · expected vs actual · `unconfirmed`/`reproduced`/`confirmed`/`rejected` · limitations · next experiment), and the two validation runs' lessons were recorded with it (`…-run-learnings.md` 2026-10-16 entries; `.agents/skills/cbt-chaos-team/cbt-chaos-team-learnings.md` populated with three cross-run entries) | schema + both runs' deduped, evidence-citing entries written at learning closeout |
| §10 Phase 0 audit deliverables | IMPLEMENTED | `docs/agent-workflow-audit.md` (matrix, delegation map, baselines) | matrix completed; per-run metrics section added |
| §10 Phase 1 stage-aware, deterministic-first lead | IMPLEMENTED | live-skill policy sections; `make stage-list` usage; smallest-valid-stage rule | verified line by line |
| §10 Phase 2 deterministic verdict + regression tests | IMPLEMENTED | `scenario-verdict.sh` + `tests/test-scenario-verdict.sh` (now includes wrong-target, absent-observer, stale-signal, advanced-tracker, attributed-checkpoint cases) | 5 new negative cases added this round |
| §10 Phase 3 bounded investigator | IMPLEMENTED | `cbt-chaos-run` "Bounded investigation" contract text; team-skill stop conditions | unchanged |
| §10 Phase 4 learning and experiment selection | IMPLEMENTED | the §9 schema landed in the run-learnings maintenance rules and the team-learnings file is populated; both runs' Variation Deciders selected the next action from prior runs' closed artifacts and explicitly rejected same-parameter repeats (`cbt-chaos/scenarios_v2/CBT-F-01/matrix-proposal.md`, `…/CBT-I-01/matrix-proposal.md`), and the unproven item stays labelled as a bounded residual in both runs' checker artifacts | lessons recorded at closeout (both runs cite their own artifacts); the two next-action proposals both choose an evidence fix over a new chaos parameter, with the rationale in the file |
| §10 Phase 5 evaluate and expand | IMPLEMENTED to the review's 2–3-run scope | metrics comparison against the earlier validated run (`docs/agent-workflow-report.md` §9a: 579 s vs 579 s, stage-by-stage), no full-E2E reruns needed for either leg set, and both next-action proposals reduce future work by choosing an evidence fix over a repeat chaos leg; the remaining several-dozen scenarios were deliberately not run | 2 of the 3 selected scenarios executed with the full protocol (CBT-F-03 prepared, not run — recorded in the not-executed table); further expansion is per-scenario work, not a plan gap |
| §11 evaluation suite (10-20 tasks) and metrics | PARTIAL | metrics: `docs/agent-workflow-audit.md` §8 (including the explicitly unmeasurable ones); the *agent-task* suite needs a harness this repository does not have | not implemented as specified; recorded as P4 |
| §11 metrics: model calls/tokens | **UNMEASURABLE here** | no telemetry in the harness | recorded as P3; wall clock + spawn counts measured instead |
| §12 required skill changes (10 bullets) | IMPLEMENTED | `cbt-chaos-run` (S12.1-S12.10 incl. the §5 policy and `make test`), `cbt-chaos-issue-triage` (+bounded investigation, missing-artifact fallback), `cbt-chaos-team` (reuse/test rule), 13 role skills (shared policy block + role bullet) | this round's main skill change |
| §13 keep changes small and separable; no auto-commit | IMPLEMENTED | this round's change set is split by concern (harness bounds / verdict scope / trigger evidence / evaluator rules / skill policy / docs) and nothing was committed | no commit made |
| §14 final implementation report | IMPLEMENTED | this document; unexecuted work recorded in `docs/agent-plan-incorrect-points.md` (§ "Not executed") | this section is that report's plan-level half |

### 8a. What a reader should take from this table

Three plan points were **wrong for this checkout** and were deliberately not
implemented (P1, P2, and the P3/P4 unmeasurable/unbuildable items); two were
already satisfied by earlier work (the Makefile's staged interface, the team
topology) and were verified rather than rewritten; the rest were closed this
round, in the order the plan itself recommends (audit artefacts, then lead
policy, then script/verdict gaps with tests, then the bounded-investigator
policy).

## 9. Validation runs (2026-10-16)

Two `scenarios_v2` scenarios were executed end to end through the
`cbt-chaos-team` protocol (Lead + preflight + observer + trigger + blind
checkers + report writer + report-fidelity checker + post-run batch) on the
execution host, with the harness changes of this review in place. A third
scenario (CBT-F-03, controller-restart) had its trigger brought to `--plan`
readiness and its full contract set written, but was **not** executed this
round (see the not-executed record); the review's requirement was 2–3 runs.

| | Run 1 — CBT-F-01 `20261016-cbt-f-01-r04` | Run 2 — CBT-I-01 `20261016-cbt-i-01-r01` |
|---|---|---|
| Disruption | launcher pod deleted inside the active-copy window | VMI deleted between the full checkpoint and the incremental stage |
| Preflight | GO, 7/7 checks (`preflight.json`) | GO, 7/7 checks; HPP margin flagged (82.87 GiB free after the 190 GiB plan) |
| Observer | ARMED 01:07:02Z, 4 watches; independent capture of copy-window start 01:12:26.758Z, old UID gone 01:12:38Z, replacement Ready 01:12:49Z | watches armed 01:36:15Z (ARMED marker written 01:36:40Z), 4 watches; independent capture of the VMI UID change `b203235a…`→`29dfe33c…` |
| Deterministic evaluator | **PASS 8/8** (`verdict.json`, sha256 `dba29ae4…`) | **INVALID — inapplicable** (HV1): its expected inputs do not exist in this scenario by design |
| Injection validity checker | **PASS** (window, exact target UID, independent effect) | **PASS** (target, window, independent effect) |
| Evidence sufficiency checker | **REJECT** on spec criterion 4.3 (libvirt checkpoint tree after VM recovery never captured) → verified by the Lead → **run verdict BLOCKED** | **PASS** on all five §5 criteria, with the bounded residual that block-extent incrementality cannot be proven without a qcow2 allocation map |
| Report fidelity | REJECT (2 citation errors) → revision 1 → **PASS** | REJECT (3 line-pointer errors + 2 wording items) → revision 1 → **PASS** |
| Wall clock (legs) | 148 s + 50 s + 380 s + 1 s = **579 s (9 m 39 s)** — identical to the previously validated r03 (15 min budget, 30–40 min ceiling) | trigger run **≈ 5 m 30 s** end to end; measured backups full 55 s (baseline 52–55), incremental 17 s (baseline 16–21) |
| Product outcome | no product defect observed; the CBT behaviour (clean interrupted failure, tracker never advanced, recovery, clean-lifecycle restores) held | the post-restart pass was a **genuine Incremental** (`type=Incremental`, checkpoint redefined from the full, restore hashes matching) — not a silent wrong-content incremental and not a full fallback |
| Agent spawns | 11 (2 preflight attempts incl. the mis-pinned first one, observer, trigger worker, 2 checkers, writer, report checker, 4 post-run), plus **1 duplicate Lead launch refused by the trigger's collision guard** (no mutation) | 9 (preflight, observer, 2 checkers, writer, report checker, 4 post-run) — **the trigger was executed by the Lead directly, not by a spawned Trigger Worker** (deviation from run 1's topology, adopted after the launch-observability problem in HV4) |

### 9a. Plan §11 metrics for these runs

- **Wall clock and per-stage durations:** recorded per leg
  (`driver-timings.json`, `run.json .stage_timings`, `summary.json .phases`) and
  used above; the CBT-F-01 runs are reproducible to the second (579 s vs 579 s).
- **Narrowest target chosen:** both runs used one scenario trigger plus the
  scenario's own stage sequence — no `TYPE=all` re-run was needed for either.
- **Retries/timeouts:** one leg retry (the recovery leg in run 1's protocol
  design allows 2 attempts) — none was needed; no timeout occurred except the
  harness-level `watch` bound remaining untriggered (40-minute watchers stopped
  by the observer at 15 m), and one Lead-side wrapper time-out caused by an ssh
  session held open by a detached remote process (no effect on the run).
- **Injection validity and evidence completeness:** graded by the injection
  checker in both runs (PASS/PASS) and by the evidence checker (REJECT/PASS).
- **Verdict correctness:** run 1 exposed exactly the case the plan's Phase 2
  wanted — a mandatory criterion with no evidence cannot PASS; run 2 exposed its
  mirror image, a deterministic evaluator confidently wrong outside its own
  scenario shape (HV1).
- **Not measured:** model calls/tokens (no telemetry, flag F4); repeated source
  reads/API queries (not instrumented).
- **Observation, not plan item:** `run.json .total_elapsed_seconds` does not
  equal the sum of `.stage_timings` (161 s vs ≈289 s in run 2; 50 s vs 234 s in
  run 1), so its scope (per-invocation vs cumulative) is under-documented.

### 9b. What the runs changed in the harness

The F12 evidence fix was exercised live (the trigger log now distinguishes
`Checkpoint tree capture failed (exit=1…)` from
`Pre-backup checkpoint tree (exit=0, lines=0; empty is expected on a fresh
lifecycle)`), the F13 verdict-scope separation read correctly in both
directions (`recovery_invocation`/`FAIL` for run 1's interrupted lifecycle,
`lifecycle`/`PASS` for run 2), the evaluator's tightened rules did not change
run 1's deterministic PASS, `--plan` rehearsal accepted the pre-armed run
directory in both scenarios, and the `WATCH_MAX_SECONDS` bound was armed on
every watch. The runs' own defects are recorded as HV1–HV8 in
`docs/agent-plan-incorrect-points.md`.

### 9c. Learning closeout and the twice-rule

Three failure classes reached the twice-rule threshold during these runs
(evaluator-out-of-shape; a per-run contract dropping a parameterised template's
mandate; `deletionTimestamp` read as an instant), so the contract makes the
corresponding skill/spec edits mandatory rather than optional. The Scenario
Improver produced the exact diffs and tickets for each
(`cbt-chaos/scenarios_v2/CBT-I-01/analysis/20261016-cbt-i-01-r01-improvements.md`,
`cbt-chaos/scenarios_v2/CBT-F-01/analysis/20261016-cbt-f-01-r04-improvements.md`);
**none was applied**, because spec and SKILL edits are human-gated, and each
run's ledger records that the approval is outstanding. The I-01 improver also
found a second defect inside the evaluator finding: even with a correct check
set, the shape-blind `clean-lifecycle NOT_APPLICABLE` cap would prevent that
scenario shape from ever reaching PASS.

The `deletionTimestamp` class was closed as an observation artefact rather than a
defect, on independent evidence from two agents: the value is the deletion
*deadline* (`now + grace`), and `deletionGracePeriodSeconds` moves 60 → 0 exactly
where it regresses in both runs — so the observers' decision to corroborate with
container `finishedAt` was right, and the rule for future observers is "do not
use `deletionTimestamp` as the deletion instant".
