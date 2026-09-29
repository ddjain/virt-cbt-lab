#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-verify"

workflow_step "1/3 Read VM CBT state"
workflow_action "oc get vm $VM_NAME -n $NAMESPACE -o jsonpath=.status.changedBlockTracking.state"
vm_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
workflow_success "VM $VM_NAME CBT state: ${vm_state:-unknown}"

workflow_step "2/3 Read backup completion, types, and checkpoints"
workflow_action "Query $FULL_BACKUP_NAME, $INCREMENTAL_BACKUP_NAME, and tracker $TRACKER_NAME in namespace $NAMESPACE"
full_type="$(get_backup_type "$FULL_BACKUP_NAME")"
full_done="$(get_backup_done_status "$FULL_BACKUP_NAME")"
full_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
incremental_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
incremental_done="$(get_backup_done_status "$INCREMENTAL_BACKUP_NAME")"
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
latest_checkpoint="$(get_tracker_checkpoint)"
workflow_action "Full: type=$full_type done=$full_done checkpoint=$full_checkpoint"
workflow_action "Incremental: type=$incremental_type done=$incremental_done checkpoint=$incremental_checkpoint"
workflow_action "Tracker $TRACKER_NAME latest checkpoint=$latest_checkpoint"

workflow_step "3/3 Validate CBT and checkpoint relationships"
vm_cbt_is_enabled() {
  [[ "$vm_state" == Enabled ]]
}

full_backup_is_complete() {
  [[ "$full_type" == Full && "$full_done" == True ]]
}

incremental_backup_is_complete() {
  [[ "$incremental_type" == Incremental && "$incremental_done" == True ]]
}

checkpoints_are_distinct_and_present() {
  [[ -n "$full_checkpoint" &&
     -n "$incremental_checkpoint" &&
     "$full_checkpoint" != "$incremental_checkpoint" ]]
}

tracker_matches_incremental_checkpoint() {
  [[ "$latest_checkpoint" == "$incremental_checkpoint" ]]
}

if ! vm_cbt_is_enabled ||
   ! full_backup_is_complete ||
   ! incremental_backup_is_complete ||
   ! checkpoints_are_distinct_and_present ||
   ! tracker_matches_incremental_checkpoint; then
  printf 'CBT verification failed. VM=%s full=%s/%s incremental=%s/%s tracker=%s\n' \
    "$vm_state" "$full_type" "$full_done" "$incremental_type" "$incremental_done" "$latest_checkpoint" >&2
  exit 1
fi

workflow_success "CBT verification passed; full and incremental checkpoints are distinct and tracker matches incremental"
printf 'Full checkpoint:        %s\nIncremental checkpoint: %s\n' \
  "$full_checkpoint" "$incremental_checkpoint"
