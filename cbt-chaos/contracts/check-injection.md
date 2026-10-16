# Task Contract: Injection Validity Checker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-injection-checker`. One job: PASS or REJECT on injection
validity. You receive no verdict, no worker narratives, no analyst conclusions.

## Run identity
- Scenario: CBT-F-04 — restart the backup controller during the active disk copy
- RUN_ID: `__RUN_ID__`; VM `vm-__RUN_ID__`
- Full backup `vm-backup-__RUN_ID__`; namespace `vm-cbt-demo`;
  chaos target namespace `__CTRL_NAMESPACE__` (virt-controller leader pod).

## Paths you may read (and nothing else)
- This contract.
- `__SCENARIO_DIR__/jira-issue.md` and `scenario-spec.md`
  (derive expected target/action/signal/window yourself).
- Run-scoped artifacts for THIS run only, under
  `__SCENARIO_DIR__/runs/__RUN_ID__/`:
  `observer/` (markers, payloads, watches/, finding.md), `trigger/`,
  `recovery/`, `evidence-index.json`.
- Nothing else: no contracts of other agents, no ledger, no state.json, no
  reports, no other runs, no learnings.

## File you own (sole writer)
`checkers/injection-validity.json` under the run root.

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
1. Did the disruption hit the exact Lease-holder `virt-controller` pod in
   `__CTRL_NAMESPACE__` (exact name, UID), and only that one pod?
2. Did the action occur inside the specified window — after the run's full
   backup was actively copying (launcher compute-log `Backup started` line for
   the exact backup `vm-backup-__RUN_ID__`) and before its terminal state?
3. Is the effect independently proven (observer ctrl-pods/lease/ctrl-events
   watches: pod deletion + replacement + holderIdentity transition), not merely
   requested (Krkn/trigger log lines alone are insufficient)?
4. Do the recorded UTC times support the ordering (signal → action request →
   effect → backup terminal), within stated clock uncertainty?
5. Does every cited evidence file exist and match `evidence-index.json` sha256?

## Output
`{"utc": "...", "verdict": "PASS"|"REJECT", "reject_reasons": [{"failure_class":
"...", "citation": "path:line or JSON field", "detail": "..."}], "evidence":
[{"question": 1-5, "answer": "...", "citation": "..."}]}`.
Every REJECT reason must be self-contained with an exact citation.
