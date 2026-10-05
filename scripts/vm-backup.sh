#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-backup"
load_run_id
load_report_id

workflow_step "1/4 Create full-backup resources"
workflow_action "oc apply -f $(manifest_path full-backup) (PVC $FULL_BACKUP_PVC_NAME, tracker $TRACKER_NAME, backup $FULL_BACKUP_NAME)"
sed \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$FULL_BACKUP_NAME|g" \
  -e "s|__FULL_BACKUP_PVC__|$FULL_BACKUP_PVC_NAME|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc_cmd apply -f -
workflow_success "PVC, tracker, and full backup request created in namespace $NAMESPACE"

workflow_step "2/4 Wait for the full backup to complete"
workflow_action "oc wait vmbackup/$FULL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$FULL_BACKUP_NAME"
full_backup_done_reason="$(get_backup_done_reason "$FULL_BACKUP_NAME")"
workflow_success "$FULL_BACKUP_NAME reports Done=True (reason: $full_backup_done_reason)"

workflow_step "3/4 Validate backup type"
full_backup_type="$(get_backup_type "$FULL_BACKUP_NAME")"
if [[ "$full_backup_type" != Full ]]; then
  printf 'Expected a Full backup; got %s.\n' "$full_backup_type" >&2
  exit 1
fi
workflow_success "$FULL_BACKUP_NAME is a $full_backup_type backup"

workflow_step "4/4 Record the full checkpoint"
full_backup_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
workflow_success "$FULL_BACKUP_NAME checkpoint is $full_backup_checkpoint"

workflow_action "Recording full backup PVC size and VM backup status for the run report"
full_backup_status="$(get_vm_backup_status)"
if [[ "$(jq -r '.backupName // empty' <<<"$full_backup_status")" != "$FULL_BACKUP_NAME" ]]; then
  full_backup_status='{}'
fi
write_report_fragment "full-backup" "$(jq -n \
  --arg name "$FULL_BACKUP_NAME" \
  --arg type "$full_backup_type" \
  --arg checkpoint_name "$full_backup_checkpoint" \
  --arg done_reason "$full_backup_done_reason" \
  --arg pvc_name "$FULL_BACKUP_PVC_NAME" \
  --arg pvc_requested "$(get_pvc_requested "$FULL_BACKUP_PVC_NAME")" \
  --arg pvc_capacity "$(get_pvc_capacity "$FULL_BACKUP_PVC_NAME")" \
  --argjson backup_status "$full_backup_status" \
  '{backups: {full: ({name: $name, type: $type, checkpoint_name: $checkpoint_name, done_reason: $done_reason,
                      pvc_name: $pvc_name, pvc_requested: $pvc_requested, pvc_capacity: $pvc_capacity} + $backup_status)}}')"

# `Done=True` covers both a real completion and a terminal failure (see
# common.sh's backup_done_reason_is_failure comment) — fail loudly here,
# with the reason already written to the report above, rather than letting a
# failed backup masquerade as success through steps 3/4 and surface later as
# an unrelated tracker-checkpoint timeout in vm-cbt-backup.sh.
if backup_done_reason_is_failure "$full_backup_done_reason"; then
  printf '%s reached Done=True but the backup actually failed: %s\n' \
    "$FULL_BACKUP_NAME" "$full_backup_done_reason" >&2
  exit 1
fi
