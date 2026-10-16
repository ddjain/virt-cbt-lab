# Task Contract: Report Fidelity Checker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-report-checker`. One job: PASS or REJECT on report
fidelity. You are blind to the Lead's verdict, worker narratives, and analyst
conclusions; grade only the reports against the run-scoped evidence.

## Run identity
- Scenario: CBT-F-04; RUN_ID: `__RUN_ID__`; VM `vm-__RUN_ID__`
- Reports under review: `reports/test-run-result.md` and `reports/test-run-report.md`
  in the run root.

## Paths you may read (and nothing else)
- This contract.
- `__SCENARIO_DIR__/jira-issue.md` and `scenario-spec.md`.
- The two report drafts above.
- Run-scoped artifacts for THIS run only, under
  `__SCENARIO_DIR__/runs/__RUN_ID__/`:
  `observer/` (markers, payloads, finding.md), `trigger/`, `recovery/`,
  `checkers/*.json`, `evidence-index.json`.
- The lifecycle records for THIS run's NAME `__RUN_ID__` on the
  execution host (`__REMOTE_DIR__/runs/__RUN_ID__/`:
  `summary.json`, `run.json`, `report.json`, `fragments/`, `logs/`) — these
  ARE part of the run's evidence universe. Before grading any "no
  run-scoped evidence" claim, check BOTH trees; cite the exact file+line
  when claiming absence.
- Nothing else: no ledger, no state.json, no contracts of other agents, no
  other runs, no learnings.

## File you own (sole writer)
`checkers/report-fidelity.json` under the run root.

## Rules
- **Pack gate (do this first and last).** Run
  `cbt-chaos/pack-validate.sh --verify-freeze <run-root>` as your first action:
  if it exits non-zero, record verdict `BLOCKED` with reason
  `pack-freeze-mismatch` and stop — you cannot grade a pack that is not the one
  the Lead froze. Immediately before writing your output, run it again and
  record both exit codes and `checkers/pack-freeze.json#index_sha256` in your
  JSON. A failure on the second run is `pack-mutated-during-grading`: report it
  as a reject reason, never as a pass.

## Questions to answer (all must hold for PASS)
1. Are both reports standalone for an engineer without this repository — no
   repo scripts, `make` targets, framework exit codes, internal artifact paths,
   worker/checker/framework names?
2. Does every stated fact trace to run-scoped evidence (object names, UIDs,
   UTC timestamps, condition status/reason, tracker/checkpoint values, restore
   results)? No invented or plausible-filled values; gaps stated as
   BLOCKED/UNKNOWN.
3. Are all source test-plan fields present (ID/title, workflow, objective,
   target, action, injection window/signal/duration, expected behavior,
   recovery, verification, expected outcome, priority, technical scenario, phase)?
4. Is there a How-we-ran section in plain product language, and does it match
   the evidence sequence?
5. Are harness findings correctly ABSENT from both reports?
6. Are recommendations properly labeled (engineering vs customer, confirmed vs
   hypothesis)?
7. Does the short report link to the detailed report and stay readable?

## Output
`{"utc": "...", "verdict": "PASS"|"REJECT", "reject_reasons": [{"failure_class":
"...", "citation": "report path:line or evidence path:line", "detail": "..."}]}`.
Every REJECT reason must be self-contained with an exact citation.
