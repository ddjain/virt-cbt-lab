#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/oc"
chmod +x "$TEST_TMP/bin/oc"
PATH="$TEST_TMP/bin:$PATH"
export PATH
KUBECONFIG_PATH=
KUBECONFIG=
VM_OS=debian
source "$ROOT_DIR/scripts/common.sh"
RUN_DIR="$TEST_TMP/runs/evidence-test"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/evidence"
WORKFLOW_NAME=workflow-evidence-test

DEBUG=false
quiet_action="$(workflow_action 'routine action detail' 2>&1)"
visible_step="$(workflow_step '[1/2] routine step detail' 2>&1)"
visible_success="$(workflow_success 'routine success detail' 2>&1)"
visible_warning="$(workflow_warning 'routine warning detail' 2>&1)"
quiet_status="$(workflow_status 'routine status detail' 2>&1)"
quiet_progress="$(workflow_progress 'routine progress detail' 2>&1)"
if [[ -n "$quiet_action$quiet_status$quiet_progress" ||
      "$visible_step" != *'WORKFLOW EVIDENCE TEST'* ||
      "$visible_step" != *'[1/2] routine step detail'* ||
      "$visible_success" != *'✓ routine success detail'* ||
      "$visible_warning" != *'⚠ routine warning detail'* ]]; then
  printf 'Normal output must show steps, successes, and warnings while hiding routine details.\n' >&2
  exit 1
fi
CURRENT_STEP='[2/2] simulated failure'
failure_status=0
if failure_output="$(false || workflow_failed 2>&1)"; then
  failure_status=0
else
  failure_status=$?
fi
if [[ "$failure_status" -eq 0 ||
      "$failure_output" != *'✗ [2/2] simulated failure failed'* ]]; then
  printf 'Normal output must show a concise failed-step marker.\n' >&2
  exit 1
fi
workflow_log="$(<"$RUN_DIR/logs/workflow.log")"
if [[ "$workflow_log" != *'[failure] [2/2] simulated failure (exit 1)'* ]]; then
  printf 'Step failure was not retained in workflow.log.\n' >&2
  exit 1
fi
if [[ "$workflow_log" != *'[action] routine action detail'* ||
      "$workflow_log" != *'[step] [1/2] routine step detail'* ||
      "$workflow_log" != *'[success] routine success detail'* ||
      "$workflow_log" != *'[warning] routine warning detail'* ||
      "$workflow_log" != *'[status] routine status detail'* ||
      "$workflow_log" != *'[progress] routine progress detail'* ]]; then
  printf 'Workflow details and timestamps were not retained in workflow.log.\n' >&2
  exit 1
fi
DEBUG=true
WORKFLOW_PHASE_PRINTED=false
visible_action="$(workflow_action 'debug action detail' 2>&1)"
visible_step="$(workflow_step 'debug step detail' 2>&1)"
visible_success="$(workflow_success 'debug success detail' 2>&1)"
visible_status="$(workflow_status 'debug status detail' 2>&1)"
visible_progress="$(workflow_progress 'Backup heartbeat: backup=vm-backup-test phase=progressing conditions=Progressing=True pvc=backup-pvc:Bound elapsed_since_watch=30s' 2>&1)"
visible_warning="$(workflow_warning 'debug warning detail' 2>&1)"
visible_debug="$(workflow_debug 'backup=vm-backup-test conditions=[{"type":"Done","status":"False"}] vmi_backup_status={"completed":false,"failed":false}' 2>&1)"
if [[ "$visible_action" != *'debug action detail'* ||
      "$visible_step" != *'debug step detail'* ||
      "$visible_success" != *'debug success detail'* ||
      "$visible_status" != *'debug status detail'* ||
      "$visible_progress" != *'Backup heartbeat:'* ||
      "$visible_progress" != *'conditions=Progressing=True'* ||
      "$visible_warning" != *'debug warning detail'* ||
      "$visible_debug" != *'"type":"Done"'* ||
      "$visible_debug" != *'vmi_backup_status={"completed":false'* ]]; then
  printf 'DEBUG=true did not print routine workflow diagnostics.\n' >&2
  exit 1
fi

status_path="$(write_backup_status_evidence vm-backup-evidence-test \
  '{"backupName":"vm-backup-evidence-test","startTimestamp":"2026-10-08T00:00:00Z","futureField":{"value":7}}')"
expected_path='evidence/vm-backup-evidence-test-vm-backup-status.json'
if [[ "$status_path" != "$expected_path" ]]; then
  printf 'Unexpected VM backup-status evidence path: %s\n' "$status_path" >&2
  exit 1
fi
jq -e '.backupName == "vm-backup-evidence-test" and .futureField.value == 7' \
  "$RUN_DIR/$status_path" >/dev/null
missing_path="$(write_backup_status_evidence vm-backup-other \
  '{"backupName":"vm-backup-evidence-test"}')"
if [[ -n "$missing_path" ]]; then
  printf 'Mismatched VM backup status should not be recorded as evidence.\n' >&2
  exit 1
fi
printf 'PASS: normal workflow output is concise, DEBUG restores action detail, and VM status is isolated as run evidence.\n'
