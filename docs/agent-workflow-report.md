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
