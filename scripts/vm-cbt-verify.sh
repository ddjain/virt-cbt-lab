#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-verify"
load_run_id
load_report_id

workflow_step "1/4 Read VM CBT state"
workflow_action "oc get vm $VM_NAME -n $NAMESPACE -o jsonpath=.status.changedBlockTracking.state"
vm_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
workflow_success "VM $VM_NAME CBT state: ${vm_state:-unknown}"

workflow_step "2/4 Read backup completion, types, and checkpoints"
workflow_action "Query $FULL_BACKUP_NAME, $INCREMENTAL_BACKUP_NAME, and tracker $TRACKER_NAME in namespace $NAMESPACE"
full_type="$(get_backup_type "$FULL_BACKUP_NAME")"
full_done="$(get_backup_done_status "$FULL_BACKUP_NAME")"
full_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
incremental_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
incremental_done="$(get_backup_done_status "$INCREMENTAL_BACKUP_NAME")"
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
latest_checkpoint="$(get_tracker_checkpoint)"
workflow_action "Full: type=$full_type done=$full_done checkpoint=$full_checkpoint"
workflow_action "Incremental: type=$incremental_type done=$incremental_done checkpoint=$incremental_checkpoint"
workflow_action "Tracker $TRACKER_NAME latest checkpoint=$latest_checkpoint"

workflow_step "3/4 Validate CBT and checkpoint relationships"
vm_cbt_is_enabled() {
  [[ "$vm_state" == Enabled ]]
}

full_backup_is_complete() {
  [[ "$full_type" == Full && "$full_done" == True ]]
}

incremental_backup_is_complete() {
  [[ "$incremental_type" == Incremental && "$incremental_done" == True ]]
}

checkpoints_are_distinct_and_present() {
  [[ -n "$full_checkpoint" &&
     -n "$incremental_checkpoint" &&
     "$full_checkpoint" != "$incremental_checkpoint" ]]
}

tracker_matches_incremental_checkpoint() {
  [[ "$latest_checkpoint" == "$incremental_checkpoint" ]]
}

# Run every check (rather than stopping at the first failure) so the report
# and the printed summary show the full picture for debugging.
verify_checks_json='[]'
record_check() {
  local name="$1" passed="$2"
  verify_checks_json="$(jq -c --arg name "$name" --argjson passed "$passed" \
    '. + [{name: $name, passed: $passed}]' <<<"$verify_checks_json")"
}

verify_passed=true
for check in vm_cbt_is_enabled full_backup_is_complete incremental_backup_is_complete \
             checkpoints_are_distinct_and_present tracker_matches_incremental_checkpoint; do
  if "$check"; then
    record_check "$check" true
  else
    record_check "$check" false
    verify_passed=false
  fi
done

if [[ "$verify_passed" != true ]]; then
  printf 'CBT verification failed. VM=%s full=%s/%s incremental=%s/%s tracker=%s\n' \
    "$vm_state" "$full_type" "$full_done" "$incremental_type" "$incremental_done" "$latest_checkpoint" >&2
else
  workflow_success "CBT verification passed; full and incremental checkpoints are distinct and tracker matches incremental"
  printf 'Full checkpoint:        %s\nIncremental checkpoint: %s\n' \
    "$full_checkpoint" "$incremental_checkpoint"
fi

workflow_step "4/4 Verify the backups actually restore the correct guest data"
workflow_action "Running scripts/vm-cbt-restore-test.sh to rebuild and read the guest disk"
restore_test_passed=true
if "$ROOT_DIR/scripts/vm-cbt-restore-test.sh"; then
  workflow_success "Restore test passed; full and full+incremental restores match the recorded guest data"
else
  restore_test_passed=false
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
        ($a; .[$k] = (if ($a[$k] | type) == "array" and ($b[$k] | type) == "array" and $k == "checks"
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
jq --arg run_id "$RUN_ID" --arg report_id "$REPORT_ID" --argjson overall_passed "$overall_passed" \
  '.run_id = $run_id | .report_id = $report_id | .verification.overall_passed = $overall_passed |
   .verification.restore_log_path = "logs/restore-verify-pod.log" |
   .logs = {virt_launcher: "logs/virt-launcher.log", restore_verify_pod: "logs/restore-verify-pod.log"}' \
  "$report_path" > "$report_path.tmp" && mv "$report_path.tmp" "$report_path"

workflow_success "Run report written to $report_path"

if [[ "$overall_passed" != true ]]; then
  exit 1
fi
