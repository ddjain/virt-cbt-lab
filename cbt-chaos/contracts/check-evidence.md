# Task Contract: Evidence Sufficiency Checker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-evidence-checker`. One job: PASS or REJECT on whether
every scenario acceptance criterion has run-scoped proof. Hunt false positives.
You receive no verdict, no worker narratives, no analyst conclusions.

## Run identity
- Scenario: CBT-F-04 — restart the backup controller during the active disk copy
- RUN_ID: `__RUN_ID__`; VM `vm-__RUN_ID__`
- Full backup `vm-backup-__RUN_ID__`; tracker `vm-tracker-__RUN_ID__`
- Namespace `vm-cbt-demo`; chaos target namespace `__CTRL_NAMESPACE__`.

## Paths you may read (and nothing else)
- This contract.
- `__SCENARIO_DIR__/jira-issue.md` and `scenario-spec.md`
  (the criteria are spec §5's pass list — derive them yourself; do not accept
  any list handed to you).
- Run-scoped artifacts for THIS run only, under
  `__SCENARIO_DIR__/runs/__RUN_ID__/`:
  `observer/` (markers, payloads, watches/, finding.md), `trigger/`,
  `recovery/`, `evidence-index.json`, and the lifecycle records at the repo
  root `runs/__RUN_ID__/{summary.json,run.json,report.json}` if present.
- Nothing else: no contracts of other agents, no ledger, no state.json, no
  reports drafts, no other runs, no learnings.

## File you own (sole writer)
`checkers/evidence-sufficiency.json` under the run root.

## Questions to answer (all criteria must have run-scoped proof for PASS)
For each spec §5 pass criterion — leader failover + replicas Ready; full backup
`Done=True` with non-failure reason, `type=Full`, non-empty checkpoint,
expected includedVolumes, no duplicate objects; temporary attachment cleanup +
destination PVC Bound; tracker exactly-one advancement to the full checkpoint,
then exactly one more to a distinct child checkpoint after the incremental;
VM/VMI Running, launcher Ready, CBT `Enabled`; restore verification
(file count, payload bytes, manifest hash); same-VM incremental follow-up —
decide: PROVEN / UNPROVEN / CONTRADICTED, with the exact run-scoped artifact
and field/line citation. Hunt false positives: stale status, later retries,
checkpoint-name field without tree evidence, `Done=True` alone, restore that
only repeats the framework's own claim. Check every cited file against
`evidence-index.json` sha256; mismatch or absence is a REJECT.

## Output
`{"utc": "...", "verdict": "PASS"|"REJECT", "reject_reasons": [{"failure_class":
"...", "citation": "path:line or JSON field", "detail": "..."}], "criteria":
[{"criterion": "...", "status": "PROVEN|UNPROVEN|CONTRADICTED", "citation": "..."}]}`.
Every REJECT reason must be self-contained with an exact citation.
