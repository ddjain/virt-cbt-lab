# VERDICT: {{OVERALL_VERDICT}} — {{REPORT_TITLE}}

> Full evidence for a **single `make e2e` run** of a chaos scenario. Paste the **Executive
> summary** + the filled `test-run-result-template.md` at the top of a Jira comment; link or
> attach this whole file for the full evidence trail.

## Header

| Field | Value |
|-------|-------|
| **Scenario ID** | {{SCENARIO_ID}} |
| **Scenario spec** | `{{SCENARIO_SPEC_PATH}}` |
| **Run NAME** | {{RUN_NAME}} |
| **Date** | {{RUN_DATE}} |
| **Host / cluster** | {{REMOTE_HOST}} (`{{REMOTE_DIR}}`) |
| **Namespace** | {{NAMESPACE}} |
| **VM** | {{VM_NAME}} |
| **Chaos tool** | {{CHAOS_TOOL}} (e.g. `krknctl run pod-scenarios` via `chaos-trigger-v2.sh`) |
| **Report artifact** | `{{E2E_REPORT_JSON_PATH}}` |

## Result at a glance

| | |
|---|---|
| **Overall** | PASS / FAIL / PASS WITH FINDINGS / BLOCKED |
| **`make e2e` exit status** | |
| **Chaos landed in the intended window** | Yes / No |

**One-line result:** {{ONE_LINE_SUMMARY}}

## Test plan details

Fill from the v2 `jira-issue.md` or the legacy `scenario-spec.md`; do not omit source criteria.

- **Test ID:** {{SCENARIO_ID}}
- **Test title:** {{TEST_TITLE}}
- **Workflow:** {{WORKFLOW}}
- **Test objective / description:** {{TEST_OBJECTIVE}}
- **Chaos target:** {{CHAOS_TARGET}}
- **Chaos action:** {{CHAOS_ACTION}}
- **When to inject:** {{INJECTION_WINDOW}}
- **Injection signal / condition:** {{INJECTION_SIGNAL}}
- **Chaos duration:** {{CHAOS_DURATION}}
- **Expected behavior:** {{EXPECTED_BEHAVIOR}}
- **Recovery:** {{RECOVERY}}
- **How to verify:** {{HOW_TO_VERIFY}}
- **Expected outcome:** {{EXPECTED_OUTCOME}}
- **Priority:** {{PRIORITY}}
- **Technical scenario:** {{TECHNICAL_SCENARIO}}
- **Chaos phase:** {{CHAOS_PHASE}}

---

## Executive summary

{{3_6_SENTENCES_FOR_DEVELOPERS}}

## Environment

| Component | Version / value | Notes |
|-----------|------------------|-------|
| OpenShift | {{OCP_VERSION}} | `oc get clusterversion` |
| CNV (KubeVirt) | {{CNV_VERSION}} | |
| `krknctl` | {{KRKNCTL_VERSION}} | `krknctl --version` |
| Storage backend | {{STORAGE_BACKEND}} | e.g. hostpath-provisioner, ODF |
| `GUEST_DATA_SIZE_MB` / `GUEST_INCREMENTAL_DATA_SIZE_MB` | {{GUEST_DATA_SIZE_MB}} / {{GUEST_INCREMENTAL_DATA_SIZE_MB}} | |

## Chaos injection details

### Trigger script and configuration

```bash
{{TRIGGER_SCRIPT_INVOCATION}}
```

### Command krknctl actually ran

```bash
{{FULL_KRKNCTL_COMMAND}}
```

### Target

| Component | Selector | Why this target |
|-----------|----------|------------------|
| {{TARGET_COMPONENT}} | {{TARGET_SELECTOR}} | {{RATIONALE}} |

### Independent monitor-subagent evidence

| Check | Result | Evidence |
|-------|--------|----------|
| Watch armed before trigger | PASS / FAIL | {{MONITOR_ARMED_TIME}} |
| Observed injection condition | PASS / FAIL / INCONCLUSIVE | {{OBSERVED_CONDITION_AND_TIME}} |
| Actual target matches Jira/spec component | PASS / FAIL / INCONCLUSIVE | Expected: {{EXPECTED_TARGET}}; observed: {{OBSERVED_TARGET}} |
| Chaos landed inside the intended window | PASS / FAIL / INCONCLUSIVE | {{INJECTION_TIME_AND_OFFSET}} |
| Monitor conclusion | CONFIRMED / NOT CONFIRMED / INCONCLUSIVE | {{MONITOR_CONCLUSION}} |
| Observer evidence | | `{{OBSERVER_EVIDENCE_PATHS}}` |

### Chaos lifecycle timestamps

| Event | Time (UTC) | Notes |
|-------|------------|-------|
| Trigger script / krknctl started | | |
| Trigger condition satisfied | | |
| Pod delete issued | | |
| Old virt-launcher pod `Killing` event | | |
| New virt-launcher pod `Started` | | |
| Target `VirtualMachineBackup` created | | |
| Target `VirtualMachineBackup` `Done` condition set | | |

## Timeline

{{NARRATIVE_OR_TABLE_CHRONOLOGICAL_EVENTS}}

## Backup CR outcome (the `Done` reason check)

> `Done=True` alone does not mean the backup succeeded — KubeVirt sets it on both a genuine
> completion and a terminal failure, distinguished only by `.status.conditions[?(@.type=="Done")].reason`.
> `scripts/common.sh`'s `backup_done_reason_is_failure()` treats any reason starting with
> `"Backup has failed"` as a real failure; everything else (including benign
> `"...warning: Failed freezing guest filesystem..."` messages) is treated as success.

| Field | Full backup | Incremental backup |
|-------|-------------|---------------------|
| Name | {{FULL_BACKUP_NAME}} | {{INCREMENTAL_BACKUP_NAME}} |
| `status.type` | | |
| `Done` condition `status` | | |
| `Done` condition `reason` | | |
| Treated as failure by `backup_done_reason_is_failure`? | | |
| `status.checkpointName` | | |
| Tracker advanced to this checkpoint? | | |

## Workload / data integrity

{{RESTORE_TEST_OUTPUT_OR_N_A}}

## `report.json` excerpt

```json
{{REPORT_JSON_BACKUPS_SECTION}}
```

## Kubernetes events (excerpt)

```
{{OC_GET_EVENTS_EXCERPT}}
```

## Steps to reproduce

1. {{STEP}}

```bash
{{COMMANDS}}
```

## Verdict table

| Criterion | Result |
|-----------|--------|
| {{CRITERION}} | PASS / FAIL / WARN |

## Observations for developers

{{BULLETS_FINDINGS_FOLLOWUPS}}

---

## Appendix

**Full logs, raw `oc get vmbackup -o json`, etc.**

{{APPENDIX_CONTENT_OR_LINKS}}
