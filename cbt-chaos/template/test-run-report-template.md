# VERDICT: {{OVERALL_VERDICT}} — {{REPORT_TITLE}}

> Standalone record of CBT backup behavior, disruption, recovery, and data verification.

## Test identification

| Field | Value |
|-------|-------|
| **Scenario ID** | {{SCENARIO_ID}} |
| **Test title** | {{TEST_TITLE}} |
| **Test run label** | {{RUN_LABEL}} |
| **Date (UTC)** | {{RUN_DATE}} |
| **Namespace** | {{NAMESPACE}} |
| **Target VM** | {{VM_NAME}} |
| **Same-VM post-chaos backup target** | {{POST_CHAOS_SAME_VM}} |
| **Supplemental fresh recovery VM** | {{SUPPLEMENTAL_RECOVERY_VM_OR_NA}} |
| **Overall outcome** | {{OVERALL_VERDICT}} |

## Test plan

- **Workflow:** {{WORKFLOW_IN_PRODUCT_TERMS}}
- **Objective / hypothesis:** {{TEST_OBJECTIVE}}
- **Target component/resource:** {{CHAOS_TARGET}}
- **Action:** {{CHAOS_ACTION}}
- **Injection window:** {{INJECTION_WINDOW}}
- **Signal / condition:** {{INJECTION_SIGNAL}}
- **Duration:** {{CHAOS_DURATION}}
- **Expected behavior:** {{EXPECTED_BEHAVIOR}}
- **Recovery:** {{RECOVERY}}
- **Verification:** {{HOW_TO_VERIFY}}
- **Expected outcome:** {{EXPECTED_OUTCOME}}
- **Priority:** {{PRIORITY}}
- **Technical scenario:** {{TECHNICAL_SCENARIO}}
- **Phase:** {{CHAOS_PHASE}}

## Executive summary

{{EXECUTIVE_SUMMARY}}

## How we ran the scenario

{{HOW_WE_RAN_SCENARIO}}

## Environment

| Component | Version / value |
|-----------|-----------------|
| OpenShift | {{OCP_VERSION}} |
| KubeVirt / CNV | {{CNV_VERSION}} |
| Storage backend | {{STORAGE_BACKEND}} |
| Guest baseline data | {{BASELINE_DATA_PROFILE}} |
| Incremental data | {{INCREMENTAL_DATA_PROFILE}} |

## Target and disruption

| Expected target | Observed target | Identity evidence |
|-----------------|-----------------|-------------------|
| {{EXPECTED_TARGET}} | {{OBSERVED_TARGET}} | {{TARGET_IDENTITY_EVIDENCE}} |

- **Action observed:** {{OBSERVED_ACTION}}
- **Active-copy signal:** {{OBSERVED_SIGNAL}}
- **Injection window result:** PASS / FAIL / BLOCKED — {{INJECTION_WINDOW_RESULT}}
- **Independent observation:** {{MONITOR_CONCLUSION}}
- **Recovery of disrupted workload:** {{DISRUPTION_RECOVERY_RESULT}}

## How backup and recovery behaved

| Stage / backup | Type | `Done` status | `Done` reason | Checkpoint | Tracker state | PVC / included volume | Restore/data result |
|----------------|------|---------------|---------------|------------|---------------|----------------------|---------------------|
{{BACKUP_ROWS}}


## Same-VM post-chaos backup verification

{{SAME_VM_POST_CHAOS_RESULT}}
## Supplemental clean lifecycle verification (if run)

{{SUPPLEMENTAL_RECOVERY_SUMMARY}}

## Data integrity

| Restore point | Expected file count / bytes / hash | Observed file count / bytes / hash | Result |
|---------------|------------------------------------|-----------------------------------|--------|
{{RESTORE_ROWS}}

## UTC timeline

| Event | Time (UTC) | Observation |
|-------|------------|-------------|
| Backup began / target backup created | {{BACKUP_START_TIME}} | {{BACKUP_START_OBSERVATION}} |
| Injection signal observed | {{SIGNAL_TIME}} | {{SIGNAL_OBSERVATION}} |
| Disruption issued and observed | {{DISRUPTION_TIME}} | {{DISRUPTION_OBSERVATION}} |
| Target backup reached terminal state | {{BACKUP_DONE_TIME}} | {{BACKUP_DONE_OBSERVATION}} |
| Original workload recovered | {{ORIGINAL_RECOVERY_TIME}} | {{ORIGINAL_RECOVERY_OBSERVATION}} |
| Post-chaos backup/restore verification completed | {{POST_CHAOS_COMPLETE_TIME}} | {{POST_CHAOS_COMPLETE_OBSERVATION}} |

## Acceptance criteria

| Product criterion | Result | Evidence-based rationale |
|-------------------|--------|--------------------------|
{{CRITERION_ROWS}}

## CBT product findings and next actions

{{PRODUCT_FINDINGS_AND_ACTIONS_OR_NONE}}

## Evidence summary

{{STANDALONE_EVIDENCE_SUMMARY}}
