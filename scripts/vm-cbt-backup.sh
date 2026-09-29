#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-backup"
require_command ssh

wait_for_full_checkpoint_in_tracker() {
  local expected_checkpoint="$1" tracker_checkpoint=
  for ((attempt = 1; attempt <= 20; attempt++)); do
    tracker_checkpoint="$(get_tracker_checkpoint)"
    if [[ -n "$expected_checkpoint" && "$tracker_checkpoint" == "$expected_checkpoint" ]]; then
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      workflow_action "Tracker $TRACKER_NAME still pending (attempt $attempt/20; expected checkpoint $expected_checkpoint)"
    fi
    sleep 1
  done
  printf 'Backup tracker did not advance to the full checkpoint (expected %s, got %s).\n' \
    "$expected_checkpoint" "$tracker_checkpoint" >&2
  return 1
}

workflow_step "1/5 Confirm the full-backup checkpoint"
workflow_action "oc wait vmbackup/$FULL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$FULL_BACKUP_NAME"
full_backup_type="$(get_backup_type "$FULL_BACKUP_NAME")"
if [[ "$full_backup_type" != Full ]]; then
  printf 'Run make vm-backup first; %s is not a completed full backup.\n' "$FULL_BACKUP_NAME" >&2
  exit 1
fi
if oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf '%s already exists; start a fresh demo namespace before rerunning this step.\n' "$INCREMENTAL_BACKUP_NAME" >&2
  exit 1
fi
full_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
workflow_action "Wait for tracker $TRACKER_NAME to record checkpoint $full_checkpoint"
wait_for_full_checkpoint_in_tracker "$full_checkpoint"
workflow_success "Full backup $FULL_BACKUP_NAME is complete as $full_backup_type; tracker checkpoint recorded"

workflow_step "2/5 Modify guest data after the full checkpoint"
workflow_action "Port-forward service $SSH_SERVICE and append the idempotent CBT test line to ~/hello.txt"
workflow_action "Print the new guest file SHA-256"
guest_mutation_command='
if ! grep -Fqx "This line was added after the full backup." ~/hello.txt; then
  printf "%s\n" "This line was added after the full backup." >> ~/hello.txt
fi
sha256sum ~/hello.txt
'
guest_ssh "$guest_mutation_command"
workflow_success "Guest data changed after checkpoint $full_checkpoint"

workflow_step "3/5 Create the incremental backup request"
workflow_action "oc apply -f manifests/incremental-backup.yaml (PVC hello-incremental-output and backup $INCREMENTAL_BACKUP_NAME)"
oc_cmd apply -f "$ROOT_DIR/manifests/incremental-backup.yaml"
workflow_success "Incremental backup request $INCREMENTAL_BACKUP_NAME submitted from tracker $TRACKER_NAME"

workflow_step "4/5 Wait for incremental backup completion"
workflow_action "oc wait vmbackup/$INCREMENTAL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$INCREMENTAL_BACKUP_NAME"
workflow_success "$INCREMENTAL_BACKUP_NAME reports Done=True"

workflow_step "5/5 Validate incremental type and checkpoint"
incremental_backup_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
if [[ "$incremental_backup_type" != Incremental ]]; then
  printf 'Expected an Incremental backup; got %s.\n' "$incremental_backup_type" >&2
  exit 1
fi
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
workflow_success "$INCREMENTAL_BACKUP_NAME is $incremental_backup_type (checkpoint $incremental_checkpoint)"
