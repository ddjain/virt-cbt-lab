# Test run result — {{SCENARIO_ID}} — {{RUN_DATE}}

> Short outcome for a Jira comment, dashboard, or index. Link to the full report file
> (`test-run-report-template.md` instance) for evidence.

## At a glance

| Field | Value |
|-------|-------|
| **Scenario ID** | {{SCENARIO_ID}} (e.g. `01-virt-launcher-pod-kill-during-copy`) |
| **Run ID / NAME** | {{RUN_NAME}} (the `make e2e NAME=` value, e.g. `chaos01v2-0930-1044`) |
| **Date (UTC)** | {{RUN_DATE}} |
| **Target VM** | {{VM_NAME}} |
| **Target backup** | {{TARGET_BACKUP_NAME}} (full / incremental) |
| **Overall outcome** | PASS / FAIL / BLOCKED / PASS with findings |
| **`make e2e` exit status** | 0 / non-zero |
| **Full report** | {{LINK_OR_PATH_TO_FULL_REPORT}} |

## One-line summary

{{ONE_LINE_WHAT_HAPPENED}}

## Criteria checklist

| Criterion | Result | Notes |
|-----------|--------|-------|
| Chaos landed inside the intended window | PASS / FAIL | compare injection timestamp to `VirtualMachineBackup` creation/Done timestamps |
| `Done` condition status/reason correctly reflects outcome | PASS / FAIL | never rely on `status=True` alone — check `.status.conditions[?(@.type=="Done")].reason` |
| Backup artifact integrity (no `Done=True` over truncated/corrupt bytes) | PASS / FAIL / N/A | `vm-cbt-restore-test.sh` hash + marker-line comparison |
| Checkpoint chain intact (full → incremental → tracker) | PASS / FAIL / N/A | |
| VM/virt-launcher recovery after chaos | PASS / FAIL | `oc get pod`/`oc get vm -o jsonpath='{.status.ready}'` post-run |
| Chaos tooling exit status | PASS / FAIL | krknctl / trigger script exit code |
| Report captured `done_reason` for every backup CR touched | PASS / FAIL | `report/<REPORT_ID>/report.json` → `backups.full.done_reason` and every `backups.incrementals[].done_reason` populated |

## Key timings

| Event | Time (UTC) | Offset from backup creation |
|-------|------------|------------------------------|
| `VirtualMachineBackup` created | | 0s |
| Chaos condition satisfied / kill issued | | |
| virt-launcher pod deleted | | |
| New virt-launcher pod ready | | |
| `Done` condition set | | |

## Follow-ups

- Script/spec changes filed: {{FILES_CHANGED}}
- Next run notes: {{NEXT_RUN_NOTES}}
