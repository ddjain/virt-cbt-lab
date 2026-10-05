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
load_report_id
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
restore_passed=true

workflow_step "1/5 Read and validate the run workload manifest"
manifest_path="$(workload_manifest_path)"
workflow_action "Reading $manifest_path for baseline and combined restore expectations"
if workload_manifest_validate "$manifest_path" true; then
  record_restore_check "workload_manifest_valid" true
  expected_full_count="$(jq -r '.baseline.file_count' "$manifest_path")"
  expected_full_bytes="$(jq -r '.baseline.total_payload_bytes' "$manifest_path")"
  expected_full_manifest="$(jq -r '.baseline.manifest_sha256' "$manifest_path")"
  expected_combined_count="$(jq -r '.incremental.total_file_count' "$manifest_path")"
  expected_combined_bytes="$(jq -r '.incremental.total_payload_bytes' "$manifest_path")"
  expected_combined_manifest="$(jq -r '.incremental.manifest_sha256' "$manifest_path")"
  workflow_success "Manifest expects $expected_full_count baseline and $expected_combined_count combined files"
else
  record_restore_check "workload_manifest_valid" false
  restore_passed=false
  expected_full_count=""
  expected_full_bytes=""
  expected_full_manifest=""
  expected_combined_count=""
  expected_combined_bytes=""
  expected_combined_manifest=""
fi

workflow_step "2/5 Locate the backup PVCs"
full_pvc_name="$(get_backup_pvc_name "$FULL_BACKUP_NAME")"
incremental_pvc_name="$(get_backup_pvc_name "$INCREMENTAL_BACKUP_NAME")"
workflow_action "Checking full backup PVC $full_pvc_name and incremental backup PVC $incremental_pvc_name are Bound"
full_pvc_status="$(oc_cmd get pvc "$full_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
incremental_pvc_status="$(oc_cmd get pvc "$incremental_pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo 'NOT FOUND')"
if [[ "$full_pvc_status" == "Bound" ]]; then
  record_restore_check "full_pvc_bound" true
else
  record_restore_check "full_pvc_bound" false "Bound" "$full_pvc_status"
  restore_passed=false
fi
if [[ "$incremental_pvc_status" == "Bound" ]]; then
  record_restore_check "incremental_pvc_bound" true
else
  record_restore_check "incremental_pvc_bound" false "Bound" "$incremental_pvc_status"
  restore_passed=false
fi
if [[ "$full_pvc_status" != "Bound" || "$incremental_pvc_status" != "Bound" ]]; then
  printf 'Backup PVCs are not both Bound (full=%s incremental=%s).\n' "$full_pvc_status" "$incremental_pvc_status" >&2
else
  workflow_success "Both backup PVCs are Bound"
fi

record_workload_comparison() {
  local name="$1" expected="$2" actual="$3"
  if [[ -n "$expected" && "$actual" == "$expected" ]]; then
    record_restore_check "$name" true "$expected" "$actual"
  else
    printf '%s mismatch: expected %s, got %s.\n' "$name" "${expected:-unavailable}" "${actual:-missing}" >&2
    record_restore_check "$name" false "${expected:-unavailable}" "${actual:-missing}"
    restore_passed=false
  fi
}

if [[ "$full_pvc_status" == "Bound" && "$incremental_pvc_status" == "Bound" &&
      -n "$expected_full_manifest" ]]; then
  workflow_step "3/5 Reconstruct full-only and combined guest disks"
  workflow_action "Rebase/convert the backups, mount each guest disk read-only, and hash its workload directory"
  restore_log="$(run_restore_verify_pod "$full_pvc_name" "$incremental_pvc_name")"
  printf '%s\n' "$restore_log"

  full_actual_count="$(restore_log_field "$restore_log" "FULL_WORKLOAD_FILE_COUNT")"
  full_actual_bytes="$(restore_log_field "$restore_log" "FULL_WORKLOAD_PAYLOAD_BYTES")"
  full_actual_manifest="$(restore_log_field "$restore_log" "FULL_WORKLOAD_MANIFEST_SHA256")"
  combined_actual_count="$(restore_log_field "$restore_log" "COMBINED_WORKLOAD_FILE_COUNT")"
  combined_actual_bytes="$(restore_log_field "$restore_log" "COMBINED_WORKLOAD_PAYLOAD_BYTES")"
  combined_actual_manifest="$(restore_log_field "$restore_log" "COMBINED_WORKLOAD_MANIFEST_SHA256")"

  workflow_step "4/5 Verify the full-only restore contains the baseline file set"
  record_workload_comparison "full_restore_file_count_match" "$expected_full_count" "$full_actual_count"
  record_workload_comparison "full_restore_payload_bytes_match" "$expected_full_bytes" "$full_actual_bytes"
  record_workload_comparison "full_restore_manifest_match" "$expected_full_manifest" "$full_actual_manifest"

  workflow_step "5/5 Verify the full-plus-incremental restore contains the combined file set"
  record_workload_comparison "combined_restore_file_count_match" "$expected_combined_count" "$combined_actual_count"
  record_workload_comparison "combined_restore_payload_bytes_match" "$expected_combined_bytes" "$combined_actual_bytes"
  record_workload_comparison "combined_restore_manifest_match" "$expected_combined_manifest" "$combined_actual_manifest"
else
  printf 'Skipping disk reconstruction: a valid manifest and both Bound backup PVCs are required.\n' >&2
fi

write_report_fragment "restore-test" "$(jq -n --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
  --argjson checks "$restore_checks_json" \
  '{guest: {workload_manifest_path: $manifest_path}, verification: {checks: $checks}}')"

if [[ "$restore_passed" == true ]]; then
  printf '\n[%s] Restore verification passed: full and combined guest disks match their workload manifests.\n' "$WORKFLOW_NAME" >&2
else
  printf '\n[%s] Restore verification failed; see checks above and %s/logs/restore-verify-pod.log for details.\n' "$WORKFLOW_NAME" "$REPORT_DIR" >&2
  exit 1
fi
