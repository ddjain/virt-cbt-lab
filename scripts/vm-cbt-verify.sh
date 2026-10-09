#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-verify"
load_run_id

workflow_step "1/4 Read VM CBT state"
workflow_action "oc get vm $VM_NAME -n $NAMESPACE -o jsonpath=.status.changedBlockTracking.state"
vm_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
workflow_status "VM $VM_NAME CBT state: ${vm_state:-unknown}"
if [[ "$vm_state" == Enabled ]]; then
  workflow_success "CBT Enabled"
else
  workflow_warning "CBT state is ${vm_state:-unknown}"
fi

vm_info_load "$RUN_ID"

workflow_step "2/4 Read full backup and incremental pass status"
full_type="$(get_backup_type "$FULL_BACKUP_NAME" 2>/dev/null || true)"
full_done="$(get_backup_done_status "$FULL_BACKUP_NAME" 2>/dev/null || true)"
full_reason="$(get_backup_done_reason "$FULL_BACKUP_NAME" 2>/dev/null || true)"
full_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME" 2>/dev/null || true)"
incremental_passes="$(jq -c '.backups.incrementals' "$VM_INFO_PATH")"
incremental_pass_count="$(jq -r 'length' <<< "$incremental_passes")"
incremental_passes_completed="$(jq -r '.incremental_passes_completed' "$VM_INFO_PATH")"
incremental_passes_total="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
latest_checkpoint="$(get_tracker_checkpoint 2>/dev/null || true)"
workflow_action "Full: type=$full_type done=$full_done checkpoint=$full_checkpoint"
workflow_action "Incremental passes recorded=$incremental_pass_count completed=$incremental_passes_completed planned=$incremental_passes_total"
workflow_action "Tracker $TRACKER_NAME latest checkpoint=${latest_checkpoint:-missing}"
workflow_success "Backups read · full $full_type · incrementals $incremental_passes_completed/$incremental_passes_total"

workflow_step "3/4 Validate CBT and incremental checkpoint chain"
verify_checks_json='[]'
record_check() {
  local name="$1" passed="$2"
  verify_checks_json="$(jq -c --arg name "$name" --argjson passed "$passed" \
    '. + [{name: $name, passed: $passed}]' <<<"$verify_checks_json")"
}
record_result() {
  local name="$1" passed="$2"
  if [[ "$passed" == true ]]; then
    record_check "$name" true
  else
    record_check "$name" false
    verify_passed=false
  fi
}
verify_passed=true

if [[ "$vm_state" == Enabled ]]; then
  record_check "vm_cbt_is_enabled" true
else
  record_result "vm_cbt_is_enabled" false
fi
if [[ "$full_type" == Full && "$full_done" == True ]] &&
   ! backup_done_reason_is_failure "$full_reason"; then
  record_check "full_backup_is_complete" true
else
  record_result "full_backup_is_complete" false
fi

if [[ "$incremental_pass_count" == "$incremental_passes_total" &&
      "$incremental_passes_completed" == "$incremental_passes_total" ]]; then
  record_check "incremental_pass_count_matches_plan" true
else
  record_result "incremental_pass_count_matches_plan" false
fi

previous_checkpoint="$full_checkpoint"
for ((index = 0; index < incremental_pass_count; index++)); do
  pass_record="$(jq -c --argjson index "$index" '.[$index]' <<< "$incremental_passes")"
  pass_number="$(jq -r '.pass' <<< "$pass_record")"
  backup_name="$(jq -r '.name' <<< "$pass_record")"
  recorded_checkpoint="$(jq -r '.checkpoint_name' <<< "$pass_record")"
  backup_type="$(get_backup_type "$backup_name" 2>/dev/null || true)"
  backup_done="$(get_backup_done_status "$backup_name" 2>/dev/null || true)"
  backup_reason="$(get_backup_done_reason "$backup_name" 2>/dev/null || true)"
  backup_checkpoint="$(get_backup_checkpoint "$backup_name" 2>/dev/null || true)"
  printf -v pass_label '%02d' "$pass_number"
  workflow_action "Pass $pass_number: $backup_name type=$backup_type done=$backup_done checkpoint=$backup_checkpoint"
  pass_ok=false
  if [[ "$backup_type" == Incremental && "$backup_done" == True ]] &&
     ! backup_done_reason_is_failure "$backup_reason"; then
    pass_ok=true
  fi
  record_result "incremental_pass_${pass_label}_is_complete" "$pass_ok"
  if [[ -n "$backup_checkpoint" && "$backup_checkpoint" == "$recorded_checkpoint" ]]; then
    record_check "incremental_pass_${pass_label}_checkpoint_matches_state" true
  else
    record_result "incremental_pass_${pass_label}_checkpoint_matches_state" false
  fi
  if [[ -n "$backup_checkpoint" && "$backup_checkpoint" != "$previous_checkpoint" ]]; then
    record_check "incremental_pass_${pass_label}_checkpoint_is_distinct" true
  else
    record_result "incremental_pass_${pass_label}_checkpoint_is_distinct" false
  fi
  previous_checkpoint="$backup_checkpoint"
done

if [[ -n "$full_checkpoint" && "$previous_checkpoint" != "$full_checkpoint" &&
      "$latest_checkpoint" == "$previous_checkpoint" ]]; then
  record_check "tracker_matches_final_incremental_checkpoint" true
else
  record_result "tracker_matches_final_incremental_checkpoint" false
fi

if [[ "$verify_passed" != true ]]; then
  printf '        ✗ CBT/checkpoint validation failed\n' >&2
  printf 'CBT verification failed. VM=%s full=%s/%s passes=%s/%s tracker=%s\n' \
    "$vm_state" "$full_type" "$full_done" "$incremental_pass_count" \
    "$incremental_passes_total" "$latest_checkpoint" >&2
else
  workflow_progress "CBT verification passed; all incremental checkpoints are distinct and the tracker matches the final pass"
  workflow_success "CBT and checkpoint chain verified"
  printf 'Checkpoint chain: full=%s final_incremental=%s\n' \
    "$full_checkpoint" "$previous_checkpoint"
fi

workflow_step "4/4 Verify the backups actually restore the correct guest data"
workflow_action "Running scripts/vm-cbt-restore-test.sh to rebuild and read the guest disk"
restore_test_passed=true
if "$ROOT_DIR/scripts/vm-cbt-restore-test.sh"; then
  workflow_status "Restore test passed; full and all cumulative incremental prefixes match their workload manifests"
  workflow_success "Restored full and incremental workload prefixes verified"
else
  restore_test_passed=false
  printf '        ✗ Restore verification failed\n' >&2
  printf 'Restore test failed; the backup does not reconstruct the expected guest data.\n' >&2
fi

workflow_action "Collecting the VM's virt-launcher pod log for the run report"
virt_launcher_pod="$(oc_cmd get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$virt_launcher_pod" ]]; then
  collect_pod_log "$virt_launcher_pod" "virt-launcher.log"
else
  printf '[vm-cbt] No virt-launcher pod found for VM %s; skipping log collection.\n' "$VM_NAME" >&2
fi

write_report_fragment "verify" "$(jq -n \
  --arg tracker_name "$TRACKER_NAME" \
  --arg latest_checkpoint "$latest_checkpoint" \
  --argjson checks "$verify_checks_json" \
  '{tracker: {name: $tracker_name, latest_checkpoint: $latest_checkpoint}, verification: {checks: $checks}}')"

workflow_step "Merge run report"
report_path="$REPORT_DIR/report.json"
jq -s '
  def deepmerge($a; $b):
    if ($a | type) == "object" and ($b | type) == "object" then
      reduce ($b | keys_unsorted[]) as $k
        ($a; .[$k] = (if ($a[$k] | type) == "array" and ($b[$k] | type) == "array" and ($k == "checks" or $k == "incrementals" or $k == "extensions")
                      then ($a[$k] + $b[$k])
                      elif ($a | has($k)) then deepmerge($a[$k]; $b[$k])
                      else $b[$k] end))
    else $b end;
  reduce .[] as $x ({}; deepmerge(.; $x))
' "$REPORT_DIR"/fragments/*.json > "$report_path"

overall_passed=false
if [[ "$verify_passed" == true && "$restore_test_passed" == true ]]; then
  overall_passed=true
fi
jq --arg run_id "$RUN_ID" --argjson overall_passed "$overall_passed" \
  '.run_id = $run_id | .verification.overall_passed = $overall_passed |
   .verification.restore_log_path = "logs/restore-verify-pod.log" |
   .logs = {workflow: "logs/workflow.log", virt_launcher: "logs/virt-launcher.log",
            restore_verify_pod: "logs/restore-verify-pod.log"}' \
  "$report_path" > "$report_path.tmp" && mv "$report_path.tmp" "$report_path"
if [[ "$overall_passed" == true ]]; then
  vm_info_update \
    '.status = "complete" |
     .verified_at = $updated_at |
     del(.verification_failed_at) |
     if .extension_pending != null then
       .extensions = ((.extensions // []) + [(.extension_pending +
         {status: "complete", verified_at: $updated_at})]) |
       del(.extension_pending)
     else . end'
else
  vm_info_update '.status = "verification_failed" | .verification_failed_at = $updated_at'
fi
summary_result=FAIL
if [[ "$overall_passed" == true ]]; then summary_result=PASS; fi
if summary_path="$(bash "$ROOT_DIR/scripts/write-run-summary.sh" \
    "$RUN_ID" verify "$summary_result")"; then
  if [[ "${E2E_STAGE_WRAPPED:-false}" != true ]]; then
    printf 'Summary: %s\n' "$summary_path"
  fi
else
  printf '⚠ Could not write summary.json; detailed evidence remains in %s.\n' \
    "$report_path" >&2
fi

workflow_progress "Run report written to $report_path"
workflow_success "Verification report written"

if [[ "$overall_passed" != true ]]; then
  exit 1
fi
