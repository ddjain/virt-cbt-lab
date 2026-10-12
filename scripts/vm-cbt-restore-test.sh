#!/usr/bin/env bash
set -euo pipefail
recovery_attempt_id=""
if (($#)); then
  if (($# != 2)) || [[ "$1" != "--recovery-attempt" || ! "$2" =~ ^r[0-9]{3}$ ]]; then
    printf 'Usage: %s [--recovery-attempt rNNN]\n' "$0" >&2
    exit 2
  fi
  recovery_attempt_id="$2"
fi
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/restore-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore-lib.sh"
# shellcheck source=scripts/workload-manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload-manifest.sh"
WORKFLOW_NAME="vm-cbt-restore-test"
load_run_id
vm_info_load "$RUN_ID"
require_restore_helper_image
recovery_mode=false
recovery_record_json=""
if [[ -n "$recovery_attempt_id" ]]; then
  recovery_mode=true
  if ! recovery_record_json="$(jq -ce --arg id "$recovery_attempt_id" \
      '[.recovery.attempts[]? | select(.id == $id)] | first // empty' "$VM_INFO_PATH")"; then
    printf 'Recovery attempt %s is not recorded for run %s.\n' "$recovery_attempt_id" "$RUN_ID" >&2
    exit 1
  fi
  if [[ "$(jq -r '.status' <<<"$recovery_record_json")" != backup_verified ]]; then
    printf 'Recovery attempt %s is not backup-verified; refusing to restore it.\n' "$recovery_attempt_id" >&2
    exit 1
  fi
fi

restore_checks_json='[]'
record_restore_check() {
  local name="$1" passed="$2" expected="${3:-}" actual="${4:-}"
  restore_checks_json="$(jq -c --arg name "$name" --argjson passed "$passed" \
    --arg expected "$expected" --arg actual "$actual" \
    '. + [{name: $name, passed: $passed} +
      (if $expected == "" and $actual == "" then {} else {expected: $expected, actual: $actual} end)]' \
    <<<"$restore_checks_json")"
}

record_workload_comparison() {
  local name="$1" expected="$2" actual="$3" passed=true
  if [[ "$expected" != "$actual" ]]; then
    passed=false
    restore_passed=false
  fi
  record_restore_check "$name" "$passed" "$expected" "$actual"
}
restore_passed=true

workflow_step "1/5 Read and validate the run workload manifest"
manifest_path="$(workload_manifest_path)"
if [[ "$recovery_mode" == true ]]; then
  workflow_action "Reading $manifest_path baseline for recovery attempt $recovery_attempt_id"
else
  workflow_action "Reading $manifest_path for baseline and every incremental-pass restore expectation"
fi
manifest_valid=true
completed_pass_count=0
planned_pass_count=0
manifest_incremental_requirement=true
if [[ "$recovery_mode" == true ]]; then manifest_incremental_requirement=false; fi
if workload_manifest_validate "$manifest_path" "$manifest_incremental_requirement"; then
  record_restore_check "workload_manifest_valid" true
  expected_full_count="$(jq -r '.baseline.file_count' "$manifest_path")"
  expected_full_bytes="$(jq -r '.baseline.total_payload_bytes' "$manifest_path")"
  expected_full_manifest="$(jq -r '.baseline.manifest_sha256' "$manifest_path")"
  if [[ "$recovery_mode" == true ]]; then
    expected_pass_count=0
    record_restore_check "recovery_attempt_selected" true "$recovery_attempt_id"
    workflow_status "Manifest baseline expects $expected_full_count files and $expected_full_bytes bytes"
    workflow_success "Baseline manifest valid for recovery attempt $recovery_attempt_id"
  else
    expected_pass_count="$(jq -r '.incrementals | length' "$manifest_path")"
    completed_pass_count="$(jq -r '.incremental_passes_completed' "$VM_INFO_PATH")"
    planned_pass_count="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
    if [[ "$expected_pass_count" == "$completed_pass_count" &&
          "$expected_pass_count" == "$planned_pass_count" ]]; then
      record_restore_check "incremental_pass_count_matches_state" true
    else
      record_restore_check "incremental_pass_count_matches_state" false \
        "$planned_pass_count completed/$planned_pass_count planned" "$expected_pass_count manifest"
      restore_passed=false
    fi
    workflow_status "Manifest expects $expected_full_count baseline files and $expected_pass_count incremental prefix(es)"
    workflow_success "Manifest valid · $expected_full_count baseline files · $expected_pass_count incremental prefixes"
  fi
else
  manifest_valid=false
  record_restore_check "workload_manifest_valid" false
  restore_passed=false
  expected_full_count=""
  expected_full_bytes=""
  expected_full_manifest=""
  expected_pass_count=0
fi

workflow_step "2/5 Locate and validate the selected backup PVC"
if [[ "$recovery_mode" == true ]]; then
  recovery_full="$(jq -c '.recovery_full' <<<"$recovery_record_json")"
  full_backup_name="$(jq -r '.name' <<<"$recovery_full")"
  full_pvc_name="$(jq -r '.pvc_name' <<<"$recovery_full")"
  recovery_checkpoint="$(jq -r '.checkpoint_name' <<<"$recovery_full")"
else
  full_backup_name="$(jq -r '.backups.full.name // empty' "$VM_INFO_PATH")"
  full_pvc_name="$(jq -r '.backups.full.pvc_name // empty' "$VM_INFO_PATH")"
fi
workflow_action "Checking full backup PVC $full_pvc_name and $expected_pass_count incremental PVC(s)"
full_pvc_status="$(oc_cmd get pvc "$full_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
if [[ "$full_pvc_status" == Bound ]]; then
  record_restore_check "full_pvc_bound" true
else
  record_restore_check "full_pvc_bound" false "Bound" "$full_pvc_status"
  restore_passed=false
fi
recovery_source_valid=true
if [[ "$recovery_mode" == true ]]; then
  recovery_backup_json="$(oc_cmd get vmbackup "$full_backup_name" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
  recovery_backup_type="$(jq -r '.status.type // "Unknown"' <<<"$recovery_backup_json")"
  recovery_backup_done="$(jq -r '[.status.conditions[]? | select(.type == "Done") | .status] | last // "False"' <<<"$recovery_backup_json")"
  recovery_backup_reason="$(jq -r '[.status.conditions[]? | select(.type == "Done") | .reason] | last // ""' <<<"$recovery_backup_json")"
  recovery_backup_checkpoint="$(jq -r '.status.checkpointName // ""' <<<"$recovery_backup_json")"
  recovery_backup_pvc="$(jq -r '.spec.pvcName // ""' <<<"$recovery_backup_json")"
  recovery_backup_force_full="$(jq -r '.spec.forceFullBackup // false' <<<"$recovery_backup_json")"
  [[ "$recovery_backup_type" == Full ]] && check_recovery_type=true || check_recovery_type=false
  recovery_backup_success=false
  if [[ "$recovery_backup_done" == True ]] && ! backup_done_reason_is_failure "$recovery_backup_reason"; then
    recovery_backup_success=true
  fi
  [[ -n "$recovery_backup_reason" ]] && check_recovery_reason=true || check_recovery_reason=false
  [[ -n "$recovery_checkpoint" && "$recovery_backup_checkpoint" == "$recovery_checkpoint" ]] && check_recovery_checkpoint=true || check_recovery_checkpoint=false
  [[ "$recovery_backup_pvc" == "$full_pvc_name" ]] && check_recovery_pvc=true || check_recovery_pvc=false
  [[ "$recovery_backup_force_full" == true ]] && check_force_full=true || check_force_full=false
  record_restore_check "recovery_backup_is_full" "$check_recovery_type" "Full" "$recovery_backup_type"
  record_restore_check "recovery_backup_succeeded" "$recovery_backup_success" "Done=True with success reason" "$recovery_backup_done:$recovery_backup_reason"
  record_restore_check "recovery_checkpoint_matches_attempt" "$check_recovery_checkpoint" "$recovery_checkpoint" "$recovery_backup_checkpoint"
  record_restore_check "recovery_backup_uses_selected_pvc" "$check_recovery_pvc" "$full_pvc_name" "$recovery_backup_pvc"
  record_restore_check "recovery_force_full_backup" "$check_force_full" "true" "$recovery_backup_force_full"
  if [[ "$check_recovery_type" != true || "$recovery_backup_success" != true ||
        "$check_recovery_checkpoint" != true || "$check_recovery_pvc" != true ||
        "$check_force_full" != true ]]; then
    recovery_source_valid=false
    restore_passed=false
  fi
fi

incremental_pvcs=()
incremental_pvcs_bound=true
for ((pass = 1; pass <= expected_pass_count; pass++)); do
  pass_record="$(jq -c --argjson pass "$pass" '.backups.incrementals[] | select(.pass == $pass)' "$VM_INFO_PATH")"
  pvc_name="$(jq -r '.pvc_name // empty' <<< "$pass_record")"
  if [[ -z "$pvc_name" ]]; then
    record_restore_check "incremental_pass_$(printf '%02d' "$pass")_pvc_bound" false "PVC name" "missing"
    incremental_pvcs_bound=false
    restore_passed=false
    continue
  fi
  incremental_pvcs+=("$pvc_name")
  pvc_status="$(oc_cmd get pvc "$pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
  if [[ "$pvc_status" == Bound ]]; then
    record_restore_check "incremental_pass_$(printf '%02d' "$pass")_pvc_bound" true
  else
    record_restore_check "incremental_pass_$(printf '%02d' "$pass")_pvc_bound" false "Bound" "$pvc_status"
    incremental_pvcs_bound=false
    restore_passed=false
  fi
done
restore_sources_ready=true
if [[ "$recovery_mode" == true && "$recovery_source_valid" != true ]]; then restore_sources_ready=false; fi
if [[ "$full_pvc_status" == Bound && "$incremental_pvcs_bound" == true &&
      "$expected_pass_count" == "$planned_pass_count" && "$manifest_valid" == true &&
      "$restore_sources_ready" == true ]]; then
  if [[ "$recovery_mode" == true ]]; then
    workflow_status "Selected recovery full PVC is Bound"
    workflow_success "Selected recovery backup and PVC are ready for baseline restore"
    workflow_action "Reconstructing only recovery attempt $recovery_attempt_id; restore PVCs are mounted read-only"
  else
    workflow_status "Full and all incremental backup PVCs are Bound"
    workflow_success "Full and incremental backup PVCs are Bound"
    workflow_action "Rebase each pass onto the preceding checkpoint and hash each restored workload directory"
  fi
  workflow_step "3/5 Reconstruct full-only and cumulative incremental disks"
  if restore_log="$(run_restore_verify_pod "$full_pvc_name" "${incremental_pvcs[@]}")"; then
    if [[ "$DEBUG" == true ]]; then
      printf '%s\n' "$restore_log"
    else
      workflow_status "Restore verifier completed; checking the baseline and $expected_pass_count incremental prefix(es)"
    fi
    full_actual_count="$(restore_log_field "$restore_log" "FULL_WORKLOAD_FILE_COUNT")"
    full_actual_bytes="$(restore_log_field "$restore_log" "FULL_WORKLOAD_PAYLOAD_BYTES")"
    full_actual_manifest="$(restore_log_field "$restore_log" "FULL_WORKLOAD_MANIFEST_SHA256")"
    workflow_step "4/5 Verify the full-only restore contains the baseline file set"
    if [[ "$recovery_mode" == true ]]; then
      record_workload_comparison "recovery_full_restore_file_count_match" "$expected_full_count" "$full_actual_count"
      record_workload_comparison "recovery_full_restore_payload_bytes_match" "$expected_full_bytes" "$full_actual_bytes"
      record_workload_comparison "recovery_full_restore_manifest_match" "$expected_full_manifest" "$full_actual_manifest"
    else
      record_workload_comparison "full_restore_file_count_match" "$expected_full_count" "$full_actual_count"
      record_workload_comparison "full_restore_payload_bytes_match" "$expected_full_bytes" "$full_actual_bytes"
      record_workload_comparison "full_restore_manifest_match" "$expected_full_manifest" "$full_actual_manifest"
    fi

    for ((pass = 1; pass <= expected_pass_count; pass++)); do
      printf -v pass_suffix '%02d' "$pass"
      pass_manifest="$(jq -c --argjson pass "$pass" '.incrementals[] | select(.pass == $pass)' "$manifest_path")"
      expected_count="$(jq -r '.total_file_count' <<< "$pass_manifest")"
      expected_bytes="$(jq -r '.total_payload_bytes' <<< "$pass_manifest")"
      expected_manifest="$(jq -r '.manifest_sha256' <<< "$pass_manifest")"
      actual_count="$(restore_log_field "$restore_log" "PASS_${pass_suffix}_WORKLOAD_FILE_COUNT")"
      actual_bytes="$(restore_log_field "$restore_log" "PASS_${pass_suffix}_WORKLOAD_PAYLOAD_BYTES")"
      actual_manifest="$(restore_log_field "$restore_log" "PASS_${pass_suffix}_WORKLOAD_MANIFEST_SHA256")"
      workflow_step "5/5 Verify restore after incremental pass $pass/$expected_pass_count"
      record_workload_comparison "pass_${pass_suffix}_restore_file_count_match" "$expected_count" "$actual_count"
      record_workload_comparison "pass_${pass_suffix}_restore_payload_bytes_match" "$expected_bytes" "$actual_bytes"
      record_workload_comparison "pass_${pass_suffix}_restore_manifest_match" "$expected_manifest" "$actual_manifest"
    done
  else
    restore_pod_phase="${RESTORE_POD_PHASE:-unknown}"
    record_restore_check "restore_pod_completed" false "Succeeded" "$restore_pod_phase"
    restore_passed=false
    printf 'Restore pod did not complete successfully (phase: %s); restore checks could not complete.\n' \
      "$restore_pod_phase" >&2
  fi
else
  workflow_action "Skipping disk reconstruction: baseline, selected backup, PVC, and pass-plan checks must all be valid"
  restore_passed=false
fi

if [[ "$recovery_mode" == true ]]; then
  restore_status=passed
  [[ "$restore_passed" == true ]] || restore_status=failed
  restore_record="$(jq -n --arg status "$restore_status" --arg attempt_id "$recovery_attempt_id" \
    --arg finished_at "$(workflow_timestamp)" --argjson checks "$restore_checks_json" \
    '{attempt_id:$attempt_id,status:$status,finished_at:$finished_at,checks:$checks}')"
  vm_info_update \
    '.recovery.attempts = [.recovery.attempts[] |
       if .id == $attempt_id then .restore = $restore |
         .status = (if $restore.status == "passed" then "restore_verified" else "restore_failed" end)
       else . end]' \
    --arg attempt_id "$recovery_attempt_id" --argjson restore "$restore_record"
  report_json='{}'
  if [[ -r "$RUN_DIR/report.json" ]]; then report_json="$(jq -c '.' "$RUN_DIR/report.json")"; fi
  report_tmp="$RUN_DIR/report.json.tmp.$$"
  trap 'rm -f "$report_tmp"' EXIT
  report_attempt="$(jq -c --arg id "$recovery_attempt_id" \
    '.recovery.attempts[] | select(.id == $id)' "$VM_INFO_PATH")"
  jq --argjson attempt "$report_attempt" --arg id "$recovery_attempt_id" \
    '.recovery.attempts = [.recovery.attempts[] |
       if .id == $id then $attempt else . end]' \
    <<<"$report_json" > "$report_tmp"
  mv -f "$report_tmp" "$RUN_DIR/report.json"
  trap - EXIT
  write_report_fragment "recovery-restore-${recovery_attempt_id}" \
    "$(jq -n --argjson restore "$restore_record" '{recovery:{restore_attempts:[$restore]}}')"
else
  write_report_fragment "restore-test" "$(jq -n --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
    --argjson checks "$restore_checks_json" \
    '{guest: {workload_manifest_path: $manifest_path}, verification: {checks: $checks}}')"
fi

if [[ "$restore_passed" == true ]]; then
  if [[ "$recovery_mode" == true ]]; then
    workflow_success "Recovery attempt $recovery_attempt_id baseline file set, bytes, and hashes match"
  else
    workflow_success "Full-only and all $expected_pass_count incremental prefixes match"
  fi
else
  printf '        ✗ Restore verification failed; see checks above and %s/logs/restore-verify-pod.log for details.\n' \
    "$REPORT_DIR" >&2
  exit 1
fi
