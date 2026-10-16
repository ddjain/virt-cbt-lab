# {{SCENARIO_ID}} — consolidated chaos report

The Lead updates this scenario-root report after every terminal attempt,
including INVALID and BLOCKED, before an optional repaired retry. Historical
archived evidence is linked as recorded, never moved or retroactively regraded.

## Scope

{{SCENARIO_SPEC_AND_JIRA_LINKS_AND_APPROVED_SCOPE}}

## All terminal attempts

| Attempt ID | Date (UTC) | Lifecycle evidence | Verdict | Per-run report | Bundle / approval reference | Previous / repaired attempt | Summary |
|---|---|---|---|---|---|---|---|
{{ATTEMPT_ROWS}}

Per-run reports live at `runs/<attempt-id>/run-report.md` within this scenario.
Include every terminal attempt, not only successful or valid injections; retain
the original INVALID attempt when a repaired attempt is added.

## Counts

- Total terminal attempts: {{TOTAL_ATTEMPTS}}
- PASS: {{PASS_COUNT}}
- Product FAIL: {{FAIL_COUNT}}
- INVALID injection: {{INVALID_COUNT}}
- BLOCKED prerequisites: {{BLOCKED_COUNT}}
- INCONCLUSIVE product evidence: {{INCONCLUSIVE_COUNT}}

The five verdict counts sum to the total. INVALID, BLOCKED and INCONCLUSIVE
are not product failures and must not be folded into a product failure rate.
An expected interrupted-backup exit is not itself a product FAIL.

## Confirmed product defects and recurrence

| Deduplicated defect | Bug draft | Supporting attempts / evidence | Observed impact | Root cause status |
|---|---|---|---|---|
{{DEFECT_ROWS_OR_NONE}}

The independent Analyst maintains one `bugs/<defect-slug>.md` per confirmed
observed product defect across attempts. Unknown causes are allowed; unknown
product outcomes, injection defects and harness issues do not create bugs.

## Injection, harness and evidence limitations

{{NON_PRODUCT_FINDINGS_WITH_ATTEMPT_AND_EVIDENCE_LINKS_OR_NONE}}

{{ONE_REPAIR_RELATION_FRESH_APPROVAL_AND_OUTCOME_OR_NONE}}

Only one injection-defect repair after INVALID is allowed, with fresh bundle
approval and a fresh attempt; never erase the first attempt or silently retry.

## Proposed scenarios — not executed or approved

{{NEW_SCENARIO_JIRA_DRAFT_LINKS_AND_EVIDENCE_RATIONALE_OR_NONE}}

Each follow-up is a new `scenarios_v2/<new-ID>/jira-issue.md`, explicitly marked
proposed/unexecuted. Link it; do not provide unsafe fault commands or imply that
a recommendation authorizes execution. New scope requires approval.

## Coverage, recovery and report notes

{{CROSS_ATTEMPT_COVERAGE_UNKNOWNS_RECOVERY_LIMITS_AND_NOTES}}

Generic evidence-backed lessons, if useful, are deduplicated by the Lead in
its skill's `improvement.md` (1–3 lines per lesson), not a new scenario ledger.
