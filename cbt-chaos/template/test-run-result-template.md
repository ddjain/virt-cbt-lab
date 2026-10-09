# VERDICT: {{OVERALL_VERDICT}} — {{SCENARIO_ID}} — {{RUN_DATE}}

> Standalone scenario outcome. Link to the detailed report for the full test plan and evidence narrative.

## Test summary

| Field | Value |
|-------|-------|
| **Scenario ID / title** | {{SCENARIO_ID}} — {{SCENARIO_TITLE}} |
| **Test run label** | {{RUN_LABEL}} |
| **Date (UTC)** | {{RUN_DATE}} |
| **Namespace** | {{NAMESPACE}} |
| **Target VM** | {{VM_NAME}} |
| **Target backup** | {{TARGET_BACKUP_NAME}} (full / incremental) |
| **Overall outcome** | {{OVERALL_VERDICT}} |
| **Detailed report** | [{{REPORT_TITLE}}]({{REPORT_LINK}}) |

## How we ran the scenario

{{HOW_WE_RAN_SCENARIO}}

## One-line result

{{ONE_LINE_PRODUCT_RESULT}}

## Product criteria checklist

| Criterion | Result | Observed behavior |
|-----------|--------|-------------------|
| Intended CBT backup phase and injection window | PASS / FAIL / BLOCKED | {{INJECTION_RESULT}} |
| Correct component/resource disrupted | PASS / FAIL / BLOCKED | {{TARGET_RESULT}} |
| Backup terminal type, status, and reason | PASS / FAIL | {{BACKUP_RESULT}} |
| Checkpoint/tracker state remained correct | PASS / FAIL | {{CHECKPOINT_RESULT}} |
| VM/VMI and CBT recovered | PASS / FAIL | {{RECOVERY_RESULT}} |
| Same-VM post-chaos backup recovery | PASS / FAIL / BLOCKED | {{SAME_VM_POST_CHAOS_RESULT}} |
| Supplemental fresh full/incremental restore lifecycle | PASS / FAIL / N/A | {{SUPPLEMENTAL_LIFECYCLE_RESULT}} |
| Restored guest data and manifest/hash checks | PASS / FAIL / N/A | {{DATA_RESULT}} |

## Key timings (UTC)

| Event | Time | Relative observation |
|-------|------|----------------------|
| Target backup began / object created | {{BACKUP_START_TIME}} | {{BACKUP_START_NOTE}} |
| Active-copy signal observed | {{INJECTION_SIGNAL_TIME}} | {{SIGNAL_NOTE}} |
| Disruption issued / observed | {{DISRUPTION_TIME}} | {{DISRUPTION_NOTE}} |
| Backup terminal state | {{BACKUP_DONE_TIME}} | {{BACKUP_DONE_NOTE}} |
| VM/launcher recovered | {{RECOVERY_TIME}} | {{RECOVERY_NOTE}} |

## CBT product findings

{{PRODUCT_FINDINGS_OR_NONE}}

## Next action

{{NEXT_ACTION_OR_NONE}}
