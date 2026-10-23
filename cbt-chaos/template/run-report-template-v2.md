# {{VERDICT}} — {{SCENARIO_ID}} — attempt {{ATTEMPT_ID}} — {{RUN_DATE_UTC}}

The Lead writes this report for every terminal attempt, including INVALID and
BLOCKED, before any repaired retry. Store at `runs/<attempt-id>/run-report.md`
inside the scenario directory. Link the scenario plan; record observed facts,
not a restatement of intended behavior. Do not include secrets or private paths.

## Attempt and approval

| Field | Value |
|---|---|
| Scenario / specification / Jira conditions | {{SCENARIO_LINKS}} |
| Attempt / lifecycle IDs | {{ATTEMPT_ID}} / {{LIFECYCLE_IDS}} |
| Previous / repaired attempt relation | {{ATTEMPT_RELATION_OR_NONE}} |
| Scenario iteration / note | {{ITERATION}} / {{NOTE}} |
| Namespace / VM / VM UID | {{SCOPED_IDENTITIES}} |
| Target kind / name / UID before and after | {{TARGET_IDENTITIES}} |
| Approved entrypoint and effective parameters | {{APPROVED_COMMAND_AND_PARAMETERS}} |
| Complete bundle hash / approval reference | {{BUNDLE_HASHES_AND_APPROVAL_REF}} |
| Immediate pre-execution hash verification | {{HASH_CHECK_EVIDENCE}} |
| Phase / verdict / start and close UTC | {{PHASE_VERDICT_TIMESTAMPS}} |

`run.json` is the canonical attempt state: phase, verdict, identities,
attempt/retry relation, timestamps, evidence paths and execution/report statuses.
`analysis.json` records the independent Analyst's assessment; no separate
verdict file, event ledger or index is required. Reference lifecycle
`runs/<lifecycle-id>/{run.json,report.json,summary.json}` in place; do not copy.

New attempt IDs are UTC
`dd-mm-yyyy-hh-mm-ss-<exact-vm-name>-<note>-iteration-<number>` from
`cbt-chaos/run-id.sh`; preserve historical IDs and keep lifecycle IDs separate.

## Injection proof and independent validity

{{CONDITION_BEFORE_ACTION_EVIDENCE_AND_UTC}}

{{ACTION_TARGET_UID_WINDOW_EFFECT_EXCLUSIONS_AND_BLAST_RADIUS_EVIDENCE}}

{{INDEPENDENT_ANALYST_VALIDITY_AND_RAW_EVIDENCE_REFERENCES}}

Link `injection-confirmation.json` and the raw before/after captures and
scenario-specific machine effect checks. A tool exit code or injector assertion
alone is not proof. Record non-execution explicitly for BLOCKED attempts.

## Deterministic outcomes and criterion coverage

| Mandatory criterion | Expected behavior | Observed result (pass / fail / unknown / not reached) | Evidence path + field / UTC / UID | Coverage or unknown reason |
|---|---|---|---|---|
{{CRITERIA_ROWS}}

{{STAGE_EXIT_STATUSES_AND_APPLICABLE_EVALUATOR_RESULTS}}

Preserve failed/unknown deterministic results; never narrate them into PASS.
An expected interrupted-backup nonzero exit is not automatically a product
failure. CR type alone is not proof of physical full/incremental behavior.
Report backup/data correctness, VM/workload availability and resource release
independently. For each applicable recovery layer, cite CLEAR / RESIDUAL /
UNKNOWN, resource identity, probe status and observation interval; justify
not-applicable layers. API success/detach alone is not host/storage release.

## Verdict and limits

{{VERDICT_REASON_AND_DECISIVE_REQUIREMENT}}

- INVALID: injection unproven or wrong target, window or blast radius.
- BLOCKED: prerequisites prevented injection.
- FAIL: confirmed valid injection and observed required product violation;
  root cause may remain unknown.
- INCONCLUSIVE: confirmed valid injection, but mandatory product evidence missing.
- PASS: every mandatory requirement proven.

## Scoped investigation and recovery

{{BOUNDED_INVESTIGATION_FINDINGS_ALTERNATIVES_AND_UNKNOWNS}}

{{RECOVERY_ACTIONS_RESULTS_TIMES_RETAINED_RESOURCES_AND_LIMITS}}

Scope logs by run/object UID and time range; distinguish measured facts from
hypotheses. Link relevant checkpoint, restore/hash and physical-artifact proof
where required. Do not claim recovery or cleanup that was not observed.
Include the terminal residual-resource audit and disposition of relevant
cleanup warnings even if API conditions later cleared. On a harness abort,
state which final probes ran or were unsafe/unavailable; no observation means
UNKNOWN, not clean. Distinguish approved test bounds from product SLAs,
sampled persistence from permanence, and recurrence from demonstrated causality.

## Report notes, bugs and proposed follow-ups

{{REPORT_NOTES_OR_NONE}}

{{DEDUPLICATED_BUG_LINKS_OR_NONE}}

{{PROPOSED_UNEXECUTED_SCENARIO_LINKS_OR_NONE}}

Only confirmed product failures receive Analyst-authored `bugs/<defect-slug>.md`.
Proposals are actual saved new-scenario `jira-issue.md` drafts, marked
**PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW**. For each, list its ID, short
purpose, author area, actual path and source evidence; include area-specialist
drafts as well as the grading owner's. If none were written, state none.
Leave drafts for human review/revision/manual deletion; never auto-prune or
archive them. Saving a Lead-allocated proposal is not execution approval;
expanded collection or execution scope needs its own approval. A repaired
retry is limited to one injection-defect repair after INVALID and requires
fresh approval and a fresh attempt.

## Evidence inventory

{{RELATIVE_EVIDENCE_PATHS_AND_AVAILABILITY_LIMITS}}
