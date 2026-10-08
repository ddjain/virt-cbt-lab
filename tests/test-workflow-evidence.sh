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
quiet_output="$(workflow_action 'routine action detail' 2>&1)"
quiet_step="$(workflow_step 'routine step detail' 2>&1)"
quiet_success="$(workflow_success 'routine success detail' 2>&1)"
quiet_status="$(workflow_status 'routine status detail' 2>&1)"
if [[ -n "$quiet_output$quiet_step$quiet_success$quiet_status" ]]; then
  printf 'Routine workflow details should be hidden from normal terminal output.\n%s%s%s%s\n' \
    "$quiet_output" "$quiet_step" "$quiet_success" "$quiet_status" >&2
  exit 1
fi
progress_output="$(workflow_progress 'important progress' 2>&1)"
if [[ "$progress_output" != *'important progress'* ]]; then
  printf 'Important progress should remain visible in normal output.\n' >&2
  exit 1
fi
workflow_log="$(<"$RUN_DIR/logs/workflow.log")"
if [[ "$workflow_log" != *'[action] routine action detail'* ||
      "$workflow_log" != *'[step] routine step detail'* ||
      "$workflow_log" != *'[success] routine success detail'* ||
      "$workflow_log" != *'[status] routine status detail'* ||
      "$workflow_log" != *'[progress] important progress'* ]]; then
  printf 'Routine workflow detail was not retained in workflow.log.\n' >&2
  exit 1
fi
DEBUG=true
visible_action="$(workflow_action 'debug action detail' 2>&1)"
visible_step="$(workflow_step 'debug step detail' 2>&1)"
visible_success="$(workflow_success 'debug success detail' 2>&1)"
visible_status="$(workflow_status 'debug status detail' 2>&1)"
if [[ "$visible_action" != *'debug action detail'* ||
      "$visible_step" != *'debug step detail'* ||
      "$visible_success" != *'debug success detail'* ||
      "$visible_status" != *'debug status detail'* ]]; then
  printf 'DEBUG=true did not print routine workflow detail.\n' >&2
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
