# {{REPORT_TITLE}}

> Full evidence for a **single `make e2e` run** of a chaos scenario. Paste the **Executive
> summary** + the filled `test-run-result-template.md` at the top of a Jira comment; link or
> attach this whole file for the full evidence trail.

## Header

| Field | Value |
|-------|-------|
| **Scenario ID** | {{SCENARIO_ID}} |
| **Scenario spec** | `cbt-chaos/scenarios/{{SCENARIO_ID}}/scenario-spec.md` |
| **Run NAME** | {{RUN_NAME}} |
| **Date** | {{RUN_DATE}} |
| **Host / cluster** | {{REMOTE_HOST}} (`{{REMOTE_DIR}}`) |
| **Namespace** | {{NAMESPACE}} |
| **VM** | {{VM_NAME}} |
| **Chaos tool** | {{CHAOS_TOOL}} (e.g. `krknctl run pod-scenarios` via `chaos-trigger-v2.sh`) |
| **Report artifact** | `report/{{REPORT_ID}}/report.json` |

## Result at a glance

| | |
|---|---|
| **Overall** | PASS / FAIL / PASS with findings / BLOCKED |
| **`make e2e` exit status** | |
| **Chaos landed in the intended window** | Yes / No |

**One-line result:** {{ONE_LINE_SUMMARY}}

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
