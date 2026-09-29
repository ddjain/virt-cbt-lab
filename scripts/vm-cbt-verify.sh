#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

printf '[vm-cbt-verify] Checking VM CBT status, backup completion, and tracker checkpoint.\n' >&2
vm_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
full_type="$(get_backup_type "$FULL_BACKUP_NAME")"
full_done="$(get_backup_done_status "$FULL_BACKUP_NAME")"
full_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
incremental_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
incremental_done="$(get_backup_done_status "$INCREMENTAL_BACKUP_NAME")"
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
latest_checkpoint="$(get_tracker_checkpoint)"

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

printf 'CBT verification passed.\nFull checkpoint:        %s\nIncremental checkpoint: %s\n' \
  "$full_checkpoint" "$incremental_checkpoint"
