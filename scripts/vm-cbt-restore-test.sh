#!/usr/bin/env bash
set -euo pipefail
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
workflow_action "Reading $manifest_path for baseline and every incremental-pass restore expectation"
manifest_valid=true
completed_pass_count=0
planned_pass_count=0
if workload_manifest_validate "$manifest_path" true; then
  record_restore_check "workload_manifest_valid" true
  expected_full_count="$(jq -r '.baseline.file_count' "$manifest_path")"
  expected_full_bytes="$(jq -r '.baseline.total_payload_bytes' "$manifest_path")"
  expected_full_manifest="$(jq -r '.baseline.manifest_sha256' "$manifest_path")"
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
else
  manifest_valid=false
  record_restore_check "workload_manifest_valid" false
  restore_passed=false
  expected_full_count=""
  expected_full_bytes=""
  expected_full_manifest=""
  expected_pass_count=0
fi

workflow_step "2/5 Locate the backup PVCs"
full_pvc_name="$(jq -r '.backups.full.pvc_name // empty' "$VM_INFO_PATH")"
workflow_action "Checking full backup PVC $full_pvc_name and $expected_pass_count incremental PVC(s)"
full_pvc_status="$(oc_cmd get pvc "$full_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
if [[ "$full_pvc_status" == Bound ]]; then
  record_restore_check "full_pvc_bound" true
else
  record_restore_check "full_pvc_bound" false "Bound" "$full_pvc_status"
  restore_passed=false
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
if [[ "$full_pvc_status" == Bound && "$incremental_pvcs_bound" == true &&
      "$expected_pass_count" == "$planned_pass_count" && "$manifest_valid" == true ]]; then
  workflow_status "Full and all incremental backup PVCs are Bound"
  workflow_step "3/5 Reconstruct full-only and cumulative incremental disks"
  workflow_action "Rebase each pass onto the preceding checkpoint and hash each restored workload directory"
  if restore_log="$(run_restore_verify_pod "$full_pvc_name" "${incremental_pvcs[@]}")"; then
    if [[ "$DEBUG" == true ]]; then
      printf '%s\n' "$restore_log"
    else
      workflow_status "Restore verifier completed; checking full-only disk and $expected_pass_count cumulative prefix(es)"
    fi
    full_actual_count="$(restore_log_field "$restore_log" "FULL_WORKLOAD_FILE_COUNT")"
    full_actual_bytes="$(restore_log_field "$restore_log" "FULL_WORKLOAD_PAYLOAD_BYTES")"
    full_actual_manifest="$(restore_log_field "$restore_log" "FULL_WORKLOAD_MANIFEST_SHA256")"
    workflow_step "4/5 Verify the full-only restore contains the baseline file set"
    record_workload_comparison "full_restore_file_count_match" "$expected_full_count" "$full_actual_count"
    record_workload_comparison "full_restore_payload_bytes_match" "$expected_full_bytes" "$full_actual_bytes"
    record_workload_comparison "full_restore_manifest_match" "$expected_full_manifest" "$full_actual_manifest"

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
    printf 'Restore pod did not complete successfully (phase: %s); pass-prefix restore checks could not complete.\n' \
      "$restore_pod_phase" >&2
  fi
else
  workflow_action "Skipping disk reconstruction: valid full/pass manifests and all Bound PVCs are required"
fi

write_report_fragment "restore-test" "$(jq -n --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
  --argjson checks "$restore_checks_json" \
  '{guest: {workload_manifest_path: $manifest_path}, verification: {checks: $checks}}')"

if [[ "$restore_passed" == true ]]; then
  printf '\n[%s] Restore verification passed: full-only and every incremental prefix match their workload manifests.\n' "$WORKFLOW_NAME" >&2
else
  printf '\n[%s] Restore verification failed; see checks above and %s/logs/restore-verify-pod.log for details.\n' "$WORKFLOW_NAME" "$REPORT_DIR" >&2
  exit 1
fi
