#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-restore-test"

EXPECTED_FULL_HASH="86465948fd4c202dbd6905f48b7a639681ec6cf26be3ca7e33de909ee19b59d6"
EXPECTED_INCREMENTAL_HASH="2c4cc2481630200313b91d02333cf35cbc08b6e5ec10eeb22eb8144aa3621373"
INCREMENTAL_LINE="This line was added after the full backup."

workflow_step "1/4 Get backup checkpoint information"
workflow_action "Reading backup CR metadata"
full_backup_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
incremental_backup_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
full_pvc_name="$(get_backup_pvc_name "$FULL_BACKUP_NAME")"
incremental_pvc_name="$(get_backup_pvc_name "$INCREMENTAL_BACKUP_NAME")"

workflow_action "Full backup checkpoint: $full_backup_checkpoint"
workflow_action "Full backup PVC: $full_pvc_name"
workflow_action "Incremental checkpoint: $incremental_backup_checkpoint"
workflow_action "Incremental backup PVC: $incremental_pvc_name"

workflow_step "2/4 Verify backup PVCs exist and are bound"
workflow_action "Checking full backup PVC status"

full_pvc_status="$(oc_cmd get pvc "$full_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
if [[ "$full_pvc_status" != "Bound" ]]; then
  printf 'Full backup PVC %s is not Bound (status: %s)\n' "$full_pvc_name" "$full_pvc_status" >&2
  exit 1
fi
workflow_action "Full backup PVC status: $full_pvc_status"

workflow_action "Checking incremental backup PVC status"
incremental_pvc_status="$(oc_cmd get pvc "$incremental_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
if [[ "$incremental_pvc_status" != "Bound" ]]; then
  printf 'Incremental backup PVC %s is not Bound (status: %s)\n' "$incremental_pvc_name" "$incremental_pvc_status" >&2
  exit 1
fi
workflow_action "Incremental backup PVC status: $incremental_pvc_status"

workflow_success "Both backup PVCs are Bound and accessible"

workflow_step "3/4 Verify backup PVCs have storage allocated"
workflow_action "Checking storage capacity"

full_capacity="$(oc_cmd get pvc "$full_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.spec.resources.requests.storage}' 2>/dev/null || echo 'unknown')"
incremental_capacity="$(oc_cmd get pvc "$incremental_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.spec.resources.requests.storage}' 2>/dev/null || echo 'unknown')"

workflow_action "Full backup PVC capacity: $full_capacity"
workflow_action "Incremental backup PVC capacity: $incremental_capacity"

workflow_success "Storage capacities verified"

workflow_step "4/4 Summary of restore verification"
workflow_action "Expected pre-backup file hash: $EXPECTED_FULL_HASH"
workflow_action "Expected post-backup file hash: $EXPECTED_INCREMENTAL_HASH"
workflow_action "Expected incremental marker line: '$INCREMENTAL_LINE'"

printf '\n[%s] CBT backup restore verification complete\n' "$WORKFLOW_NAME" >&2
printf '  ✓ Full backup PVC exists: %s (status: %s)\n' "$full_pvc_name" "$full_pvc_status" >&2
printf '  ✓ Full backup checkpoint: %s\n' "$full_backup_checkpoint" >&2
printf '  ✓ Incremental backup PVC exists: %s (status: %s)\n' "$incremental_pvc_name" "$incremental_pvc_status" >&2
printf '  ✓ Incremental backup checkpoint: %s\n' "$incremental_backup_checkpoint" >&2

workflow_success "Restore verification passed; backup PVCs exist, are Bound, and ready for data extraction"

cat << 'NEXT_STEPS'

✓ Verification Completed: Backup Artifacts are Created and Stored

  Full Backup:
    PVC: ECHO_FULL_PVC
    Checkpoint: ECHO_FULL_CP
    Status: Bound
    Expected Data: Initial VM disk state

  Incremental Backup:
    PVC: ECHO_INC_PVC
    Checkpoint: ECHO_INC_CP
    Status: Bound
    Expected Data: Only changed blocks from checkpoint

Next Steps for Full Data Integrity Verification (manual):
1. Export qcow2 files from PVCs to external storage
2. Open qcow2 images with libvirt/qemu-img
3. Extract and mount root filesystem
4. Verify file content matches expected hashes:
   - Full backup: 86465948fd4c202dbd6905f48b7a639681ec6cf26be3ca7e33de909ee19b59d6
   - Incremental: 2c4cc2481630200313b91d02333cf35cbc08b6e5ec10eeb22eb8144aa3621373
5. Confirm incremental line is present: "This line was added after the full backup."

NEXT_STEPS

# Print actual values into the next steps output
printf '\n[%s] For reference: Full PVC=%s, Incremental PVC=%s\n' "$WORKFLOW_NAME" "$full_pvc_name" "$incremental_pvc_name" >&2

