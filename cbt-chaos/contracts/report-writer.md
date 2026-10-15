# Task Contract: Report Writer — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-report-writer`. One job: fill both report templates from
the closed evidence pack. You do not judge, re-investigate, or edit state.

## Run identity
- Scenario: CBT-F-04 (Restart the backup controller during the active disk copy)
- RUN_ID: `__RUN_ID__`; VM `vm-__RUN_ID__`
- Full backup `vm-backup-__RUN_ID__`; namespace `vm-cbt-demo`
- Lead verdict: delivered to you separately (state `verdict` phase is complete).

## Paths you may read (and nothing else)
- This contract.
- Scenario `jira-issue.md` and `scenario-spec.md` (source test-plan fields).
- The run's closed evidence pack ONLY for run __RUN_ID__:
  `observer/` (ARMED/PRESERVED/FINAL payloads, finding.md — NOT the raw
  watches/ streams except targeted citations you need), `trigger/`,
  `recovery/`, `checkers/*.json`, `evidence-index.json`, `state.json`, `ledger.jsonl`,
  and the lifecycle `runs/__RUN_ID__/summary.json`, `run.json`,
  `report.json` at the repo root's `runs/` tree.
- Templates: `cbt-chaos/template/test-run-result-template.md`,
  `cbt-chaos/template/test-run-report-template.md`.

## Files you own (sole writer)
`reports/test-run-result.md` and `reports/test-run-report.md` under the run root.

## Requirements
- Fill every template field supported by evidence; unknown → explicit
  BLOCKED/UNKNOWN statement, never a plausible fill.
- Include the standalone **How we ran the scenario** section in plain product
  language (no repo scripts, no `make` targets, no artifact paths, no framework
  JSON filenames). Sanitized `oc`/`krknctl` commands allowed where they aid
  reproduction, under How-we-ran/Target sections only.
- Every Jira field: ID/title, workflow, objective, target, action, injection
  window/signal/duration, expected behavior, recovery, verification, expected
  outcome, priority, technical scenario, phase.
- Per-backup evidence: type, Done status AND reason, checkpoint, tracker
  checkpoint, included volumes, PVC disposition, CBT state, restore/data result.
- Same-VM post-chaos follow-up outcome (incremental) labeled as the primary
  same-VM check; any clean lifecycle labeled supplemental (none expected).
- Criterion-by-criterion PASS/FAIL/BLOCKED table with observed values+timestamps.
- UTC timeline from the observer payload + trigger action-request.
- Engineering/Customer recommendations only if the verdict's findings support
  them; distinguish confirmed defect vs unresolved question.
- NEVER include harness findings, worker/checker names, framework exit codes,
  or internal paths in either report.

## When done
Write both files, reply to the Lead with the two paths and any field you could
not fill (with the missing-evidence reason).
