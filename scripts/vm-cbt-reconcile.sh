#!/usr/bin/env bash
# vm-cbt-reconcile.sh — supported retry path for a failed incremental pass.
#
# When an incremental pass fails (status incremental_failed), the workflow
# previously had no supported transition back to incremental_ready: every
# retry required hand-editing run.json (run 20261015-cbtf04-r03 needed four
# such interventions; see analysis/20261015-cbtf04-r03-improvements.md W3).
#
# This script reconciles the lifecycle ONLY when the failure is safely
# recoverable, validating against live cluster state before any edit:
#   1. Lifecycle status is incremental_failed with a current_incremental_pass.
#   2. The failed pass's backup CR and PVC are ABSENT from the cluster
#      (the caller must delete them first, preserving evidence out-of-band;
#      this script never deletes anything).
#   3. The tracker's latestCheckpoint matches the prior checkpoint that the
#      failed pass was based on (i.e. the failure advanced nothing).
#   4. The full backup (or last successful incremental) is still Done=True
#      with a non-failure reason.
# On success: status -> incremental_ready, current_incremental_pass removed,
# and a reconcile event recorded in run.json for auditability.
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WORKFLOW_NAME="vm-cbt-reconcile"
load_run_id
vm_info_load "$RUN_ID"

if [[ ! -r "$VM_INFO_PATH" ]]; then
  printf 'Missing run metadata for %s; nothing to reconcile.\n' "${VM_NAME:-unknown}" >&2
  exit 1
fi

workflow_step "1/3 Validate failed-pass state"
vm_status="$(jq -r '.status' "$VM_INFO_PATH")"
failed_pass="$(jq -r '.current_incremental_pass // empty' "$VM_INFO_PATH")"
if [[ "$vm_status" != incremental_failed || -z "$failed_pass" ]]; then
  printf 'Nothing to reconcile: lifecycle status is %s%s. Reconcile applies only to a failed incremental pass.\n' \
    "$vm_status" "$( [[ -z "$failed_pass" ]] && printf ' (no current pass)' )" >&2
  exit 1
fi

pass_number="$(jq -r '.pass' <<< "$failed_pass")"
backup_name="$(jq -r '.backup_name' <<< "$failed_pass")"
pvc_name="$(jq -r '.pvc_name // empty' <<< "$failed_pass")"
previous_checkpoint="$(vm_info_previous_checkpoint)"
if [[ -z "$previous_checkpoint" ]]; then
  printf 'No prior checkpoint recorded in run metadata; cannot reconcile.\n' >&2
  exit 1
fi

workflow_step "2/3 Verify live cluster state is a safe retry base"
# The failed pass's resources must be gone (deleted by the operator with
# evidence preserved out-of-band); otherwise retrying would collide.
if oc_cmd get vmbackup "$backup_name" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'Failed backup %s still exists; delete it (preserving evidence) before reconciling.\n' "$backup_name" >&2
  exit 1
fi
if [[ -n "$pvc_name" ]] && oc_cmd get pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'Failed-pass PVC %s still exists; delete it before reconciling.\n' "$pvc_name" >&2
  exit 1
fi

# The tracker must still sit at the checkpoint the failed pass was based on.
tracker_checkpoint="$(get_tracker_checkpoint)"
if [[ "$tracker_checkpoint" != "$previous_checkpoint" ]]; then
  printf 'Tracker is at %s, expected prior checkpoint %s; the failure advanced tracker state. Manual inspection required.\n' \
    "$tracker_checkpoint" "$previous_checkpoint" >&2
  exit 1
fi

# The base the failed pass was retried from must still be a successful backup.
base_backup_name="$(jq -r '.backups.full.name // empty' "$VM_INFO_PATH")"
if (( $(jq -r '.backups.incrementals | length' "$VM_INFO_PATH") > 0 )); then
  base_backup_name="$(jq -r '.backups.incrementals[-1].name' "$VM_INFO_PATH")"
fi
base_done="$(get_backup_done_status "$base_backup_name")"
base_reason="$(get_backup_done_reason "$base_backup_name")"
if [[ "$base_done" != True ]] || backup_done_reason_is_failure "$base_reason"; then
  printf 'Retry base %s is not a successful backup (Done=%s, reason=%s); cannot reconcile.\n' \
    "$base_backup_name" "$base_done" "$base_reason" >&2
  exit 1
fi

workflow_step "3/3 Reset lifecycle to incremental_ready"
reconciled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
vm_info_update \
  '.status = "incremental_ready" |
   del(.current_incremental_pass) |
   .reconcile_events = ((.reconcile_events // []) + [{
     pass: $pass, backup_name: $backup_name, reconciled_at: $reconciled_at,
     reason: "failed pass reconciled after resource deletion; tracker verified at prior checkpoint"}])' \
  --argjson pass "$pass_number" \
  --arg backup_name "$backup_name" \
  --arg reconciled_at "$reconciled_at"
workflow_success "Failed pass $pass_number reconciled; lifecycle is incremental_ready (tracker at $previous_checkpoint)"
