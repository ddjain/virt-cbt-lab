#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-recover"
load_run_id
vm_info_load "$RUN_ID"

persist_attempt() {
  local report_json report_tmp now
  now="$(workflow_timestamp)"
  attempt_json="$(jq --arg updated_at "$now" '.updated_at = $updated_at' <<<"$attempt_json")"
  vm_info_update \
    '(.recovery.attempts // []) as $items |
     .recovery.attempts = (if any($items[]?; .id == $attempt.id)
       then [$items[] | if .id == $attempt.id then $attempt else . end]
       else $items + [$attempt] end) |
     .recovery.status = $attempt.status |
     .backups.full_failure = (if $original_failed then (.backups.full_failure // $failure) else .backups.full_failure end)' \
    --argjson attempt "$attempt_json" \
    --argjson failure "$full_failure_json" \
    --argjson original_failed "$backup_failed"
  report_json='{}'
  if [[ -r "$RUN_DIR/report.json" ]]; then report_json="$(jq -c '.' "$RUN_DIR/report.json")"; fi
  report_tmp="$RUN_DIR/report.json.tmp.$$"
  trap 'rm -f "$report_tmp"' EXIT
  jq --argjson attempt "$attempt_json" --argjson failure "$full_failure_json" \
    --argjson original_failed "$backup_failed" \
    --arg run_id "$RUN_ID" --arg vm_name "$VM_NAME" --arg namespace "$NAMESPACE" \
    '(.recovery.attempts // []) as $items |
     .run_id = $run_id | .vm_name = $vm_name | .namespace = $namespace |
     .recovery.attempts = (if any($items[]?; .id == $attempt.id)
       then [$items[] | if .id == $attempt.id then $attempt else . end]
       else $items + [$attempt] end) |
     .backups.full_failure = (if $original_failed then (.backups.full_failure // $failure) else .backups.full_failure end)' \
    <<<"$report_json" > "$report_tmp"
  mv -f "$report_tmp" "$RUN_DIR/report.json"
  trap - EXIT
  write_report_fragment "recovery-${attempt_id}" "$(jq -n --argjson attempt "$attempt_json" '{recovery:{attempts:[$attempt]}}')"
}

set_attempt_status() {
  local next_status="$1" reason="${2:-}" now
  now="$(workflow_timestamp)"
  attempt_json="$(jq --arg status "$next_status" --arg reason "$reason" --arg updated_at "$now" '
    .status = $status | .updated_at = $updated_at |
    (if $reason == "" then del(.failure_reason) else .failure_reason = $reason end)
  ' <<<"$attempt_json")"
  persist_attempt
}
recovery_unexpected_failure() {
  local command_status=$? current_status=""
  trap - ERR
  if [[ -n "${attempt_id:-}" && -n "${attempt_json:-}" ]]; then
    current_status="$(jq -r '.status // empty' <<<"$attempt_json" 2>/dev/null || true)"
    if [[ "$current_status" == creating ]]; then
      set_attempt_status failed \
        "Unexpected command failure (exit $command_status); inspect recorded resource state before retrying"
    fi
  fi
  printf 'Recovery stage command failed (exit %s); recorded artifacts remain available for inspection.\n' \
    "$command_status" >&2
  return "$command_status"
}
trap recovery_unexpected_failure ERR

workflow_step "1/4 Inspect the original failed full and supported API schema"
vm_json="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
vmi_json="$(oc_cmd get vmi "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
failed_backup_name="$(jq -r '.backups.full_failure.name // .backups.full.name // empty' "$VM_INFO_PATH")"
[[ -n "$failed_backup_name" ]] || failed_backup_name="$FULL_BACKUP_NAME"
failed_backup_json="$(oc_cmd get vmbackup "$failed_backup_name" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
failed_pvc_name="$(jq -r '.spec.pvcName // empty' <<<"$failed_backup_json")"
[[ -n "$failed_pvc_name" ]] || failed_pvc_name="$(jq -r '.backups.full_failure.pvc_name // .backups.full.pvc_name // empty' "$VM_INFO_PATH")"
[[ -n "$failed_pvc_name" ]] || failed_pvc_name="$FULL_BACKUP_PVC_NAME"
failed_pvc_json="$(oc_cmd get pvc "$failed_pvc_name" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
tracker_json="$(oc_cmd get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
backup_crd_json="$(oc_cmd get crd virtualmachinebackups.backup.kubevirt.io -o json 2>/dev/null || printf '{}')"

vm_uid="$(jq -r '.metadata.uid // empty' <<<"$vm_json")"
saved_vm_uid="$(jq -r '.vm_uid' "$VM_INFO_PATH")"
vm_ready="$(jq -r '[.status.conditions[]? | select(.type == "Ready") | .status] | last // "False"' <<<"$vm_json")"
vmi_phase="$(jq -r '.status.phase // "Unknown"' <<<"$vmi_json")"
cbt_state="$(jq -r '.status.changedBlockTracking.state // "Unknown"' <<<"$vm_json")"
backup_type="$(jq -r '.status.type // "Unknown"' <<<"$failed_backup_json")"
backup_done="$(jq -r '[.status.conditions[]? | select(.type == "Done") | .status] | last // "False"' <<<"$failed_backup_json")"
backup_reason="$(jq -r '[.status.conditions[]? | select(.type == "Done") | .reason] | last // ""' <<<"$failed_backup_json")"
failed_checkpoint="$(jq -r '.status.checkpointName // ""' <<<"$failed_backup_json")"
included_volumes="$(jq -c '.status.includedVolumes // []' <<<"$failed_backup_json")"
pvc_phase="$(jq -r '.status.phase // "NotFound"' <<<"$failed_pvc_json")"
tracker_checkpoint="$(jq -r '.status.latestCheckpoint.name // ""' <<<"$tracker_json")"
tracker_readable=false
if jq -e '.metadata.name != null' <<<"$tracker_json" >/dev/null; then tracker_readable=true; fi
pvc_spec="$(jq -c '
  {storageClassName:(.spec.storageClassName // ""),
   accessModes:(.spec.accessModes // []),
   storage:(.spec.resources.requests.storage // ""),
   volumeMode:(.spec.volumeMode // "")}
' <<<"$failed_pvc_json")"
storage_class="$(jq -r '.storageClassName' <<<"$pvc_spec")"
access_modes="$(jq -c '.accessModes' <<<"$pvc_spec")"
storage_request="$(jq -r '.storage' <<<"$pvc_spec")"
volume_mode="$(jq -r '.volumeMode' <<<"$pvc_spec")"
api_schema_supported=false
if jq -e '
  any(.spec.versions[]?;
    .name == "v1alpha1" and .served == true and
    .schema.openAPIV3Schema.properties.spec.properties.forceFullBackup.type == "boolean" and
    .schema.openAPIV3Schema.properties.spec.properties.source.properties.apiGroup.type == "string" and
    .schema.openAPIV3Schema.properties.spec.properties.source.properties.kind.type == "string" and
    .schema.openAPIV3Schema.properties.spec.properties.source.properties.name.type == "string")
' <<<"$backup_crd_json" >/dev/null; then api_schema_supported=true; fi

attempt_number="$(jq -r '(.recovery.attempts // []) | length + 1' "$VM_INFO_PATH")"
if ((attempt_number > 999)); then
  printf 'Recovery attempt limit reached for run %s; refusing to derive another resource identity.\n' "$RUN_ID" >&2
  exit 1
fi
printf -v attempt_id 'r%03d' "$attempt_number"
backup_candidate="vm-recovery-full-${RUN_ID}-${attempt_id}"
pvc_candidate="vm-recovery-pvc-${RUN_ID}-${attempt_id}"
probe_candidate() {
  local kind="$1" name="$2" output
  if output="$(oc_cmd get "$kind" "$name" -n "$NAMESPACE" -o name 2>&1)"; then
    printf 'present'
  elif [[ "$output" == *NotFound* || "$output" == *'not found'* ]]; then
    printf 'absent'
  else
    printf 'unknown'
  fi
}
backup_candidate_state="$(probe_candidate vmbackup "$backup_candidate")"
pvc_candidate_state="$(probe_candidate pvc "$pvc_candidate")"

workflow_step "2/4 Check recovery preconditions"
preconditions='[]'
add_check() {
  local name="$1" passed="$2" actual="$3"
  preconditions="$(jq -c --arg name "$name" --argjson passed "$passed" --arg actual "$actual" \
    '. + [{name:$name, passed:$passed, actual:$actual}]' <<<"$preconditions")"
}
[[ -n "$vm_uid" && "$vm_uid" == "$saved_vm_uid" ]] && check_vm_uid=true || check_vm_uid=false
[[ "$vm_ready" == True ]] && check_vm_ready=true || check_vm_ready=false
[[ "$vmi_phase" == Running ]] && check_vmi_running=true || check_vmi_running=false
[[ "$cbt_state" == Enabled ]] && check_cbt=true || check_cbt=false
backup_failed=false
if [[ "$backup_type" == Full && "$backup_done" == True ]] &&
   backup_done_reason_is_failure "$backup_reason"; then backup_failed=true; fi
[[ "$failed_pvc_json" != '{}' ]] && check_failed_pvc=true || check_failed_pvc=false
[[ "$failed_pvc_name" == "$FULL_BACKUP_PVC_NAME" ]] && check_pvc_identity=true || check_pvc_identity=false
[[ "$tracker_readable" == true ]] && check_tracker_readable=true || check_tracker_readable=false
[[ "$api_schema_supported" == true ]] && check_api_schema=true || check_api_schema=false
[[ -n "$storage_class" && "$storage_request" =~ ^[1-9][0-9]*([.][0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|K|M|G|T|P|E)?$ ]] && check_storage_profile=true || check_storage_profile=false
[[ "$access_modes" == '["ReadWriteOnce"]' ]] && check_access_mode=true || check_access_mode=false
[[ "$backup_candidate_state" == absent ]] && check_backup_name=true || check_backup_name=false
[[ "$pvc_candidate_state" == absent ]] && check_pvc_name=true || check_pvc_name=false
[[ "$(jq 'length' <<<"$included_volumes")" -gt 0 ]] && check_included_volumes=true || check_included_volumes=false
add_check "vm_uid_matches_run" "$check_vm_uid" "${vm_uid:-missing}"
add_check "vm_ready" "$check_vm_ready" "$vm_ready"
add_check "vmi_running" "$check_vmi_running" "$vmi_phase"
add_check "cbt_enabled" "$check_cbt" "$cbt_state"
add_check "original_full_done_failed" "$backup_failed" "type=$backup_type done=$backup_done reason=${backup_reason:-missing}"
add_check "failed_backup_pvc_retained" "$check_failed_pvc" "name=$failed_pvc_name phase=$pvc_phase"
add_check "failed_backup_pvc_identity_matches_run" "$check_pvc_identity" "$failed_pvc_name"
add_check "tracker_readable" "$check_tracker_readable" "latest_checkpoint=${tracker_checkpoint:-empty}"
add_check "force_full_backup_schema_supported" "$check_api_schema" "VirtualMachineBackup v1alpha1 forceFullBackup:boolean"
add_check "recovery_pvc_profile_available" "$check_storage_profile" "storageClass=${storage_class:-missing} request=${storage_request:-missing}"
add_check "recovery_pvc_access_mode_supported" "$check_access_mode" "$access_modes"
add_check "recovery_backup_name_available" "$check_backup_name" "$backup_candidate_state"
add_check "recovery_pvc_name_available" "$check_pvc_name" "$pvc_candidate_state"
add_check "expected_included_volumes_available" "$check_included_volumes" "count=$(jq 'length' <<<"$included_volumes")"
blocked_reasons="$(jq -c '[.[] | select(.passed != true) | "precondition failed: " + .name]' <<<"$preconditions")"

started_at="$(workflow_timestamp)"
full_failure_json="$(jq -n \
  --arg name "$failed_backup_name" --arg type "$backup_type" --arg done_status "$backup_done" \
  --arg done_reason "$backup_reason" --arg checkpoint_name "$failed_checkpoint" \
  --arg pvc_name "$failed_pvc_name" --arg pvc_phase "$pvc_phase" \
  --arg tracker_checkpoint "$tracker_checkpoint" \
  '{name:$name,type:$type,done_status:$done_status,done_reason:$done_reason,
    checkpoint_name:$checkpoint_name,pvc_name:$pvc_name,pvc_phase:$pvc_phase,
    tracker_checkpoint_at_failure:$tracker_checkpoint}')"
next_attempt_id="$attempt_id"
stale_attempt_ids="$(jq -r '.recovery.attempts[]? | select(.status == "creating") | .id' "$VM_INFO_PATH")"
while IFS= read -r stale_attempt_id; do
  [[ -n "$stale_attempt_id" ]] || continue
  attempt_id="$stale_attempt_id"
  attempt_json="$(jq -c --arg id "$stale_attempt_id" '.recovery.attempts[] | select(.id == $id)' "$VM_INFO_PATH")"
  stale_backup_name="$(jq -r '.proposed_resources.backup_name' <<<"$attempt_json")"
  stale_pvc_name="$(jq -r '.proposed_resources.pvc_name' <<<"$attempt_json")"
  stale_backup_state="$(probe_candidate vmbackup "$stale_backup_name")"
  stale_pvc_state="$(probe_candidate pvc "$stale_pvc_name")"
  attempt_json="$(jq --arg backup_state "$stale_backup_state" --arg pvc_state "$stale_pvc_state" \
    '.proposed_resources.backup_name_state = $backup_state |
     .proposed_resources.pvc_name_state = $pvc_state' <<<"$attempt_json")"
  set_attempt_status failed \
    "Recovery process was interrupted; prior candidate resource states are backup=$stale_backup_state pvc=$stale_pvc_state"
done <<<"$stale_attempt_ids"
attempt_id="$next_attempt_id"

attempt_json="$(jq -n \
  --arg id "$attempt_id" \
  --arg status "$(if [[ "$blocked_reasons" == '[]' ]]; then printf creating; else printf blocked; fi)" \
  --arg started_at "$started_at" \
  --arg vm_name "$VM_NAME" --arg vm_uid "$vm_uid" --arg saved_vm_uid "$saved_vm_uid" \
  --arg vm_ready "$vm_ready" --arg vmi_phase "$vmi_phase" --arg cbt_state "$cbt_state" \
  --arg backup_name "$failed_backup_name" --arg backup_type "$backup_type" \
  --arg backup_done "$backup_done" --arg backup_reason "$backup_reason" \
  --arg failed_checkpoint "$failed_checkpoint" --argjson included_volumes "$included_volumes" \
  --arg failed_pvc_name "$failed_pvc_name" --arg pvc_phase "$pvc_phase" \
  --arg tracker_name "$TRACKER_NAME" --arg tracker_checkpoint "$tracker_checkpoint" \
  --arg backup_candidate "$backup_candidate" --arg backup_candidate_state "$backup_candidate_state" \
  --arg pvc_candidate "$pvc_candidate" --arg pvc_candidate_state "$pvc_candidate_state" \
  --arg storage_class "$storage_class" --arg storage_request "$storage_request" \
  --argjson access_modes "$access_modes" --arg volume_mode "$volume_mode" \
  --argjson preconditions "$preconditions" --argjson blocked_reasons "$blocked_reasons" \
  --argjson api_schema_supported "$api_schema_supported" \
  '{id:$id,status:$status,started_at:$started_at,resources_applied:{pvc:false,backup:false},
    blocked_reasons:$blocked_reasons,preconditions:$preconditions,
    vm:{name:$vm_name,uid:$vm_uid,saved_uid:$saved_vm_uid,ready:$vm_ready,vmi_phase:$vmi_phase,cbt_state:$cbt_state},
    failed_full:{name:$backup_name,type:$backup_type,done_status:$backup_done,done_reason:$backup_reason,
      checkpoint_name:$failed_checkpoint,included_volumes:$included_volumes,pvc_name:$failed_pvc_name,pvc_phase:$pvc_phase},
    tracker:{name:$tracker_name,checkpoint_before:$tracker_checkpoint},
    proposed_resources:{backup_name:$backup_candidate,backup_name_state:$backup_candidate_state,
      pvc_name:$pvc_candidate,pvc_name_state:$pvc_candidate_state,storage_class:$storage_class,
      storage_request:$storage_request,access_modes:$access_modes,volume_mode:$volume_mode},
    api_contract:{status:(if $api_schema_supported then "schema_validated" else "unavailable" end),
      api_version:"backup.kubevirt.io/v1alpha1",source_kind:"VirtualMachineBackupTracker",
      source_name:$tracker_name,force_full_backup:true}}')"
if [[ "$blocked_reasons" != '[]' ]]; then
  persist_attempt
  workflow_step "4/4 Stop before creating recovery resources"
  workflow_status "Recovery $attempt_id is BLOCKED; failed resources were not changed"
  printf 'BLOCKED: recovery preconditions failed; no backup or PVC was created. Evidence: %s/report.json\n' "$RUN_DIR" >&2
  exit 0
fi
persist_attempt

workflow_step "3/4 Create a distinct recovery PVC and forced full backup"
pvc_json="$(jq -n \
  --arg name "$pvc_candidate" --arg namespace "$NAMESPACE" \
  --arg storage_class "$storage_class" --arg storage "$storage_request" \
  --arg managed_key "$RUN_LABEL_MANAGED_BY_KEY" --arg managed_value "$RUN_LABEL_MANAGED_BY_VALUE" \
  --arg run_key "$RUN_LABEL_RUN_ID_KEY" --arg run_id "$RUN_ID" \
  --argjson access_modes "$access_modes" --arg volume_mode "$volume_mode" \
  '{apiVersion:"v1",kind:"PersistentVolumeClaim",
    metadata:{name:$name,namespace:$namespace,labels:{($managed_key):$managed_value,($run_key):$run_id}},
    spec:({storageClassName:$storage_class,accessModes:$access_modes,
      resources:{requests:{storage:$storage}}} + (if $volume_mode == "" then {} else {volumeMode:$volume_mode} end))}')"
if ! oc_cmd create -f - <<<"$pvc_json" >/dev/null; then
  set_attempt_status failed "Could not create the unique recovery PVC $pvc_candidate; no existing resources were overwritten"
  printf 'Failed to create recovery PVC %s; prior failed artifacts remain untouched.\n' "$pvc_candidate" >&2
  exit 1
fi
attempt_json="$(jq '.resources_applied.pvc = true' <<<"$attempt_json")"
persist_attempt
if ! oc_cmd wait "pvc/$pvc_candidate" -n "$NAMESPACE" \
    --for=jsonpath='{.status.phase}'=Bound --timeout=20m >/dev/null; then
  set_attempt_status failed "Recovery PVC $pvc_candidate did not become Bound; PVC is preserved"
  printf 'Recovery PVC %s did not become Bound; the created PVC is preserved for diagnosis.\n' "$pvc_candidate" >&2
  exit 1
fi

backup_json_spec="$(jq -n \
  --arg namespace "$NAMESPACE" --arg backup_name "$backup_candidate" \
  --arg tracker "$TRACKER_NAME" --arg pvc "$pvc_candidate" \
  --arg managed_key "$RUN_LABEL_MANAGED_BY_KEY" --arg managed_value "$RUN_LABEL_MANAGED_BY_VALUE" \
  --arg run_key "$RUN_LABEL_RUN_ID_KEY" --arg run_id "$RUN_ID" \
  '{apiVersion:"backup.kubevirt.io/v1alpha1",kind:"VirtualMachineBackup",
    metadata:{name:$backup_name,namespace:$namespace,
      labels:{($managed_key):$managed_value,($run_key):$run_id}},
    spec:{source:{apiGroup:"backup.kubevirt.io",kind:"VirtualMachineBackupTracker",name:$tracker},
      pvcName:$pvc,forceFullBackup:true}}')"
if ! oc_cmd create -f - <<<"$backup_json_spec" >/dev/null; then
  set_attempt_status failed "Could not create recovery backup $backup_candidate; the recovery PVC is preserved"
  printf 'Failed to create recovery backup %s; recovery PVC %s is preserved.\n' \
    "$backup_candidate" "$pvc_candidate" >&2
  exit 1
fi
attempt_json="$(jq '.resources_applied.backup = true' <<<"$attempt_json")"
persist_attempt
workflow_action "Waiting for $backup_candidate to reach Done=True"
if ! wait_for_backup_done "$backup_candidate" "$pvc_candidate" Full; then
  set_attempt_status failed "Recovery backup $backup_candidate did not reach terminal Done=True; created resources are preserved"
  printf 'Recovery backup %s did not complete; backup and PVC are preserved.\n' "$backup_candidate" >&2
  exit 1
fi

recovery_backup_json="$(oc_cmd get vmbackup "$backup_candidate" -n "$NAMESPACE" -o json)"
recovery_type="$(jq -r '.status.type // "Unknown"' <<<"$recovery_backup_json")"
recovery_done="$(jq -r '[.status.conditions[]? | select(.type == "Done") | .status] | last // "False"' <<<"$recovery_backup_json")"
recovery_reason="$(jq -r '[.status.conditions[]? | select(.type == "Done") | .reason] | last // ""' <<<"$recovery_backup_json")"
recovery_checkpoint="$(jq -r '.status.checkpointName // ""' <<<"$recovery_backup_json")"
recovery_pvc_name="$(jq -r '.spec.pvcName // ""' <<<"$recovery_backup_json")"
force_full="$(jq -r '.spec.forceFullBackup // false' <<<"$recovery_backup_json")"
actual_volumes="$(jq -c '[.status.includedVolumes[]? | {diskTarget,volumeName}] | sort_by(.diskTarget,.volumeName)' <<<"$recovery_backup_json")"
expected_volumes="$(jq -c '[.[] | {diskTarget,volumeName}] | sort_by(.diskTarget,.volumeName)' <<<"$included_volumes")"
pvc_json_after="$(oc_cmd get pvc "$pvc_candidate" -n "$NAMESPACE" -o json)"
recovery_pvc_phase="$(jq -r '.status.phase // "Unknown"' <<<"$pvc_json_after")"
tracker_checkpoint_after=""
for ((tracker_wait = 1; tracker_wait <= 30; tracker_wait++)); do
  tracker_json_after="$(oc_cmd get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json 2>/dev/null || printf '{}')"
  tracker_checkpoint_after="$(jq -r '.status.latestCheckpoint.name // ""' <<<"$tracker_json_after")"
  if [[ -n "$recovery_checkpoint" && "$tracker_checkpoint_after" == "$recovery_checkpoint" ]]; then break; fi
  sleep 2
done
backup_valid=true
[[ "$recovery_type" == Full ]] || backup_valid=false
[[ "$recovery_done" == True ]] || backup_valid=false
backup_done_reason_is_failure "$recovery_reason" && backup_valid=false
[[ -n "$recovery_reason" ]] || backup_valid=false
[[ -n "$recovery_checkpoint" && "$recovery_checkpoint" != "$failed_checkpoint" ]] || backup_valid=false
[[ "$force_full" == true ]] || backup_valid=false
[[ "$recovery_pvc_name" == "$pvc_candidate" ]] || backup_valid=false
[[ "$recovery_pvc_phase" == Bound ]] || backup_valid=false
[[ "$actual_volumes" == "$expected_volumes" ]] || backup_valid=false
[[ "$tracker_checkpoint_after" == "$recovery_checkpoint" ]] || backup_valid=false
if [[ "$tracker_checkpoint" != "" && "$recovery_checkpoint" == "$tracker_checkpoint" ]]; then backup_valid=false; fi
attempt_json="$(jq \
  --arg name "$backup_candidate" --arg type "$recovery_type" --arg done_status "$recovery_done" \
  --arg done_reason "$recovery_reason" --arg checkpoint "$recovery_checkpoint" \
  --arg pvc_name "$recovery_pvc_name" --arg pvc_phase "$recovery_pvc_phase" \
  --arg tracker_after "$tracker_checkpoint_after" --argjson included_volumes "$actual_volumes" \
  --argjson passed "$backup_valid" --arg completed_at "$(workflow_timestamp)" \
  '.recovery_full = {name:$name,type:$type,done_status:$done_status,done_reason:$done_reason,
     checkpoint_name:$checkpoint,pvc_name:$pvc_name,pvc_phase:$pvc_phase,
     included_volumes:$included_volumes,force_full_backup:true,tracker_checkpoint_after:$tracker_after,
     verification_passed:$passed,completed_at:$completed_at}' \
  <<<"$attempt_json")"
persist_attempt
if [[ "$backup_valid" != true ]]; then
  set_attempt_status failed "Recovery backup/API/tracker/PVC verification failed; both recovery resources are preserved"
  printf 'Recovery backup %s failed verification; created backup, PVC, and original failed artifacts are preserved.\n' \
    "$backup_candidate" >&2
  exit 1
fi

set_attempt_status backup_verified
workflow_success "Recovery backup verified · type Full · checkpoint $recovery_checkpoint · PVC Bound · tracker advanced"
workflow_step "4/4 Restore the selected recovery full and compare the saved baseline"
if ! bash "$ROOT_DIR/scripts/vm-cbt-restore-test.sh" --recovery-attempt "$attempt_id"; then
  attempt_json="$(jq -c --arg id "$attempt_id" '.recovery.attempts[] | select(.id == $id)' "$VM_INFO_PATH")"
  set_attempt_status restore_failed "Recovery restore did not match the saved baseline; all backup resources are preserved"
  printf 'Recovery restore failed; backup %s and PVC %s remain preserved.\n' \
    "$backup_candidate" "$pvc_candidate" >&2
  exit 1
fi
attempt_json="$(jq -c --arg id "$attempt_id" '.recovery.attempts[] | select(.id == $id)' "$VM_INFO_PATH")"
set_attempt_status success
workflow_success "Same-VM recovery full and baseline restore verified · attempt $attempt_id"
