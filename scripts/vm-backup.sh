#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-backup"

workflow_step "1/4 Create full-backup resources"
workflow_action "oc apply -f manifests/full-backup.yaml (PVC hello-full-output, tracker $TRACKER_NAME, backup $FULL_BACKUP_NAME)"
oc_cmd apply -f "$ROOT_DIR/manifests/full-backup.yaml"
workflow_success "PVC, tracker, and full backup request created in namespace $NAMESPACE"

workflow_step "2/4 Wait for the full backup to complete"
workflow_action "oc wait vmbackup/$FULL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$FULL_BACKUP_NAME"
workflow_success "$FULL_BACKUP_NAME reports Done=True"

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
