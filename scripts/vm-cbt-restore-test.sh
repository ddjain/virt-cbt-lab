#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/restore-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore-lib.sh"
WORKFLOW_NAME="vm-cbt-restore-test"
load_run_id
load_report_id
require_restore_helper_image

restore_checks_json='[]'
record_restore_check() {
  local name="$1" passed="$2"
  restore_checks_json="$(jq -c --arg name "$name" --argjson passed "$passed" \
    '. + [{name: $name, passed: $passed}]' <<<"$restore_checks_json")"
}
restore_passed=true

workflow_step "1/5 Read expected hashes recorded during backup"
workflow_action "Reading $STATE_DIR/full-backup.sha256 and $STATE_DIR/incremental-backup.sha256"
expected_full_hash="$(read_state_file "full-backup.sha256")"
expected_incremental_hash="$(read_state_file "incremental-backup.sha256")"
workflow_success "Expected full hash: $expected_full_hash; expected incremental hash: $expected_incremental_hash"

workflow_step "2/5 Locate the backup PVCs"
full_pvc_name="$(get_backup_pvc_name "$FULL_BACKUP_NAME")"
incremental_pvc_name="$(get_backup_pvc_name "$INCREMENTAL_BACKUP_NAME")"
workflow_action "Checking full backup PVC $full_pvc_name and incremental backup PVC $incremental_pvc_name are Bound"
full_pvc_status="$(oc_cmd get pvc "$full_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
incremental_pvc_status="$(oc_cmd get pvc "$incremental_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
if [[ "$full_pvc_status" == "Bound" ]]; then
  record_restore_check "full_pvc_bound" true
else
  record_restore_check "full_pvc_bound" false
  restore_passed=false
fi
if [[ "$incremental_pvc_status" == "Bound" ]]; then
  record_restore_check "incremental_pvc_bound" true
else
  record_restore_check "incremental_pvc_bound" false
  restore_passed=false
fi
if [[ "$full_pvc_status" != "Bound" || "$incremental_pvc_status" != "Bound" ]]; then
  printf 'Backup PVCs are not both Bound (full=%s incremental=%s).\n' "$full_pvc_status" "$incremental_pvc_status" >&2
else
  workflow_success "Both backup PVCs are Bound"
fi

restore_log=""
if [[ "$restore_passed" == true ]]; then
  workflow_step "3/5 Reconstruct the guest disk and read the guest file"
  workflow_action "Rebase the incremental qcow2 onto the full qcow2, convert both to raw, and mount them read-only"
  restore_log="$(run_restore_verify_pod "$full_pvc_name" "$incremental_pvc_name")"
  printf '%s\n' "$restore_log"

  full_hash="$(restore_log_field "$restore_log" "FULL_HASH")"
  combined_hash="$(restore_log_field "$restore_log" "COMBINED_HASH")"
  full_has_marker="$(restore_log_field "$restore_log" "FULL_HAS_MARKER")"
  combined_has_marker="$(restore_log_field "$restore_log" "COMBINED_HAS_MARKER")"
  workflow_success "Read guest file from the full-only restore and the full+incremental restore"

  workflow_step "4/5 Verify the full backup alone matches the pre-incremental content"
  workflow_action "Comparing restored full-only hash ($full_hash) to expected ($expected_full_hash), marker line must be absent"
  if [[ "$full_hash" == "$expected_full_hash" ]]; then
    record_restore_check "full_restore_hash_match" true
  else
    printf 'Full-backup restore mismatch: expected hash %s, got %s.\n' "$expected_full_hash" "$full_hash" >&2
    record_restore_check "full_restore_hash_match" false
    restore_passed=false
  fi
  if [[ "$full_has_marker" == "no" ]]; then
    record_restore_check "full_restore_marker_absent" true
  else
    printf 'Full-backup restore unexpectedly contains the incremental marker line.\n' >&2
    record_restore_check "full_restore_marker_absent" false
    restore_passed=false
  fi
  [[ "$full_hash" == "$expected_full_hash" && "$full_has_marker" == "no" ]] &&
    workflow_success "Full backup restores the correct pre-incremental content"

  workflow_step "5/5 Verify the full+incremental restore matches the post-incremental content"
  workflow_action "Comparing restored full+incremental hash ($combined_hash) to expected ($expected_incremental_hash), marker line must be present"
  if [[ "$combined_hash" == "$expected_incremental_hash" ]]; then
    record_restore_check "incremental_restore_hash_match" true
  else
    printf 'Full+incremental restore mismatch: expected hash %s, got %s.\n' "$expected_incremental_hash" "$combined_hash" >&2
    record_restore_check "incremental_restore_hash_match" false
    restore_passed=false
  fi
  if [[ "$combined_has_marker" == "yes" ]]; then
    record_restore_check "incremental_restore_marker_present" true
  else
    printf 'Full+incremental restore is missing the incremental marker line; the incremental delta was not applied.\n' >&2
    record_restore_check "incremental_restore_marker_present" false
    restore_passed=false
  fi
  [[ "$combined_hash" == "$expected_incremental_hash" && "$combined_has_marker" == "yes" ]] &&
    workflow_success "Full+incremental restore contains the correct post-incremental content"
else
  printf 'Skipping disk reconstruction (steps 3-5): backup PVCs are not both Bound.\n' >&2
fi

printf '%s\n' "$restore_log" > "$REPORT_DIR/restore-test.log"
write_report_fragment "restore-test" "$(jq -n --argjson checks "$restore_checks_json" \
  '{verification: {checks: $checks}}')"

if [[ "$restore_passed" == true ]]; then
  printf '\n[%s] Restore verification passed: reconstructed disks match the guest data recorded at backup time.\n' "$WORKFLOW_NAME" >&2
else
  printf '\n[%s] Restore verification failed; see checks above and %s/restore-test.log for details.\n' "$WORKFLOW_NAME" "$REPORT_DIR" >&2
  exit 1
fi
