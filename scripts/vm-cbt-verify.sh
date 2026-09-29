#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

printf '[vm-cbt-verify] Checking VM CBT status, backup completion, and tracker checkpoint.\n' >&2
vm_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
full_type="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.type}')"
full_done="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.conditions[?(@.type=="Done")].status}')"
full_checkpoint="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.checkpointName}')"
incremental_type="$(oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.type}')"
incremental_done="$(oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.conditions[?(@.type=="Done")].status}')"
incremental_checkpoint="$(oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.checkpointName}')"
latest_checkpoint="$(oc_cmd get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.latestCheckpoint.name}')"

if [[ "$vm_state" != Enabled || "$full_type" != Full || "$full_done" != True || \
      "$incremental_type" != Incremental || "$incremental_done" != True || \
      -z "$full_checkpoint" || -z "$incremental_checkpoint" || \
      "$full_checkpoint" == "$incremental_checkpoint" || \
      "$latest_checkpoint" != "$incremental_checkpoint" ]]; then
  printf 'CBT verification failed. VM=%s full=%s/%s incremental=%s/%s tracker=%s\n' \
    "$vm_state" "$full_type" "$full_done" "$incremental_type" "$incremental_done" "$latest_checkpoint" >&2
  exit 1
fi

printf 'CBT verification passed.\nFull checkpoint:        %s\nIncremental checkpoint: %s\n' \
  "$full_checkpoint" "$incremental_checkpoint"
