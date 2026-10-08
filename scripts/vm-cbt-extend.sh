#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/workload-manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload-manifest.sh"
WORKFLOW_NAME="vm-cbt-extend"

extension_error() {
  printf 'Cannot extend VM %s: %s\n' "$VM_NAME" "$1" >&2
  exit 1
}

read_vm_state() {
  vm_status="$(jq -r '.status // "unknown"' "$VM_INFO_PATH")"
  current_total="$(jq -r '.incremental_passes_total // 0' "$VM_INFO_PATH")"
  completed_passes="$(jq -r '.incremental_passes_completed // 0' "$VM_INFO_PATH")"
  next_pass="$(jq -r '.next_incremental_pass // empty' "$VM_INFO_PATH")"
  pending_extension="$(jq -c '.extension_pending // empty' "$VM_INFO_PATH")"
}

check_target_resources_absent() {
  local pass="$1" backup_name pvc_name existing
  backup_name="$(incremental_backup_name_for_pass "$pass")"
  pvc_name="$(incremental_backup_pvc_name_for_pass "$pass")"
  if ! existing="$(oc_cmd get vmbackup "$backup_name" -n "$NAMESPACE" \
      --ignore-not-found -o name 2>/dev/null)"; then
    extension_error "could not inspect vmbackup/$backup_name; verify cluster access and retry."
  fi
  if [[ -n "$existing" ]]; then
    extension_error "vmbackup/$backup_name already exists. No resources were deleted; inspect or reconcile pass $pass before retrying."
  fi
  if ! existing="$(oc_cmd get pvc "$pvc_name" -n "$NAMESPACE" \
      --ignore-not-found -o name 2>/dev/null)"; then
    extension_error "could not inspect pvc/$pvc_name; verify cluster access and retry."
  fi
  if [[ -n "$existing" ]]; then
    extension_error "pvc/$pvc_name already exists. No resources were deleted; inspect or reconcile pass $pass before retrying."
  fi
}

write_extension_fragment() {
  local from_total="$1" target_total="$2" requested_at="$3" pass_suffix fragment
  printf -v pass_suffix '%02d' "$target_total"
  fragment="$(jq -n \
    --argjson from_total "$from_total" \
    --argjson to_total "$target_total" \
    --argjson pass "$target_total" \
    --arg requested_at "$requested_at" \
    '{extensions: [{from_total: $from_total, to_total: $to_total,
                    pass: $pass, requested_at: $requested_at}]}')"
  write_report_fragment "extension-pass-$pass_suffix" "$fragment"
}
validate_vm_ready_with_cbt() {
  local vm_json vm_ready cbt_state
  vm_json="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null)" ||
    extension_error "VM $VM_NAME cannot be read from namespace $NAMESPACE."
  vm_ready="$(jq -r '.status.ready // false' <<< "$vm_json")"
  cbt_state="$(jq -r '.status.changedBlockTracking.state // empty' <<< "$vm_json")"
  if [[ "$vm_ready" != true || "$cbt_state" != Enabled ]]; then
    extension_error "VM $VM_NAME must be Ready with CBT Enabled (ready=$vm_ready, CBT=${cbt_state:-unknown})."
  fi
}

# The manifest update is idempotent so an interrupted two-file commit is resumable.
finalize_extension_plan() {
  local from_total="$1" target_total="$2"
  if ! workload_manifest_extend_plan "$manifest_path" "$from_total" "$target_total"; then
    extension_error "could not extend the workload manifest for pass $target_total; no backup was added."
  fi
  if ! vm_info_update \
      '.incremental_passes_total = $target_total |
       .next_incremental_pass = $target_total' \
      --argjson target_total "$target_total"; then
    extension_error "workload manifest targets pass $target_total, but lifecycle state could not be synchronized; rerun EXTEND_TO_PASS=$target_total to resume. No backup resources were created."
  fi
}

extension_target="${EXTEND_TO_PASS:-}"
if ! [[ "$extension_target" =~ ^[1-9][0-9]?$ ]] || ((extension_target < 2 || extension_target > 99)); then
  printf 'EXTEND_TO_PASS must be the target total from 2 to 99; set it to the saved completed-pass count plus one.\n' >&2
  exit 1
fi

load_run_id
vm_info_load "$RUN_ID"
saved_vm_name="$(jq -r '.vm_name' "$VM_INFO_PATH")"
if [[ "$saved_vm_name" != "$VM_NAME" ]]; then
  extension_error "saved lifecycle names $saved_vm_name, not $VM_NAME."
fi
NAMESPACE="$(jq -r '.namespace' "$VM_INFO_PATH")"
VM_OS="$(jq -r '.os_profile' "$VM_INFO_PATH")"
GUEST_BASE_FILE_COUNT="$(jq -r '.guest.baseline.file_count' "$VM_INFO_PATH")"
GUEST_INCREMENTAL_FILE_COUNT="$(jq -r '.guest.incremental_file_count_per_pass' "$VM_INFO_PATH")"
GUEST_INCREMENTAL_PASSES="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
GUEST_FILE_SIZE_MIN_MIB="$(jq -r '.guest.size_range_mib.min_inclusive' "$VM_INFO_PATH")"
GUEST_FILE_SIZE_MAX_MIB="$(jq -r '.guest.size_range_mib.max_inclusive' "$VM_INFO_PATH")"
MANIFEST_VARIANT="$(jq -r '.manifest_variant' "$VM_INFO_PATH")"
manifest_path="$(workload_manifest_path)"
report_path="$REPORT_DIR/report.json"

workflow_step "1/3 Validate extension target and completed lifecycle"
read_vm_state
pending_at_start="$pending_extension"
if ! [[ "$current_total" =~ ^[1-9][0-9]?$ &&
        "$completed_passes" =~ ^[0-9]+$ ]]; then
  extension_error 'saved lifecycle pass counters are invalid; inspect runs/<run-id>/run.json before extending.'
fi

if [[ -z "$pending_extension" && "$vm_status" == complete &&
      "$completed_passes" == "$current_total" && -z "$next_pass" &&
      "$extension_target" == "$current_total" ]]; then
  if ! workload_manifest_validate "$manifest_path" true; then
    extension_error 'the completed workload manifest is invalid; no pass was added.'
  fi
  workflow_progress "Lifecycle already includes $current_total incremental pass(es); no new backup was created. Use EXTEND_TO_PASS=$((current_total + 1)) to add one more."
  exit 0
fi

if [[ -z "$pending_extension" ]]; then
  if [[ "$vm_status" != complete ]]; then
    case "$vm_status" in
      incremental_ready)
        extension_error "lifecycle has completed $completed_passes of $current_total planned passes; run TYPE=incremental VM=$VM_NAME until complete, then extend."
        ;;
      verification_pending|verification_failed)
        extension_error "lifecycle status is $vm_status; run TYPE=verify VM=$VM_NAME successfully before extending."
        ;;
      incremental_failed|incremental_running)
        extension_error "lifecycle has a failed or in-progress incremental pass; inspect/reconcile it before extending."
        ;;
      *)
        extension_error "lifecycle status is $vm_status; only a successfully completed lifecycle can be extended."
        ;;
    esac
  fi
  if [[ "$completed_passes" != "$current_total" || -n "$next_pass" ]]; then
    extension_error "lifecycle counters disagree (completed=$completed_passes total=$current_total next=${next_pass:-none}); verify the saved state before extending."
  fi
  expected_target=$((current_total + 1))
  if ((extension_target != expected_target)); then
    extension_error "one extension adds only the next pass: current total=$current_total, expected EXTEND_TO_PASS=$expected_target, got $extension_target."
  fi
  if ! workload_manifest_validate "$manifest_path" true; then
    extension_error "the workload manifest is not a valid completed $current_total-pass manifest: $manifest_path."
  fi
  manifest_total="$(jq -r '.incremental_passes_total' "$manifest_path")"
  manifest_pass_count="$(jq -r '.incrementals | length' "$manifest_path")"
  state_pass_count="$(jq -r '.backups.incrementals | length' "$VM_INFO_PATH")"
  manifest_baseline_count="$(jq -r '.baseline.file_count' "$manifest_path")"
  manifest_incremental_count="$(jq -r '.incremental_file_count_per_pass' "$manifest_path")"
  manifest_min_mib="$(jq -r '.size_range_mib.min_inclusive' "$manifest_path")"
  manifest_max_mib="$(jq -r '.size_range_mib.max_inclusive' "$manifest_path")"
  if [[ "$manifest_baseline_count" != "$GUEST_BASE_FILE_COUNT" ||
        "$manifest_incremental_count" != "$GUEST_INCREMENTAL_FILE_COUNT" ||
        "$manifest_min_mib" != "$GUEST_FILE_SIZE_MIN_MIB" ||
        "$manifest_max_mib" != "$GUEST_FILE_SIZE_MAX_MIB" ]]; then
    extension_error 'saved VM workload settings do not match workload-manifest.json; no pass was added.'
  fi
  if [[ "$manifest_total" != "$current_total" ||
        "$manifest_pass_count" != "$completed_passes" ||
        "$state_pass_count" != "$completed_passes" ]]; then
    extension_error "run metadata and workload manifest disagree (total=$current_total, state passes=$state_pass_count, manifest total=$manifest_total passes=$manifest_pass_count)."
  fi
  if [[ ! -r "$report_path" ]] || ! jq -e '.verification.overall_passed == true' "$report_path" >/dev/null; then
    extension_error "the last run report does not show successful verification: $report_path. Run TYPE=verify before extending."
  fi

  validate_vm_ready_with_cbt

  full_backup_name="$(jq -r '.backups.full.name // empty' "$VM_INFO_PATH")"
  full_type="$(get_backup_type "$full_backup_name" 2>/dev/null || true)"
  full_done="$(get_backup_done_status "$full_backup_name" 2>/dev/null || true)"
  full_reason="$(get_backup_done_reason "$full_backup_name" 2>/dev/null || true)"
  if [[ -z "$full_backup_name" || "$full_type" != Full || "$full_done" != True ]] || backup_done_reason_is_failure "$full_reason"; then
    extension_error "full backup ${full_backup_name:-missing} is not successfully complete; no pass was added."
  fi

  last_pass_record="$(jq -c '.backups.incrementals[-1] // empty' "$VM_INFO_PATH")"
  last_backup_name="$(jq -r '.name // empty' <<< "$last_pass_record")"
  last_checkpoint="$(jq -r '.checkpoint_name // empty' <<< "$last_pass_record")"
  last_record_pass="$(jq -r '.pass // 0' <<< "$last_pass_record")"
  last_type="$(get_backup_type "$last_backup_name" 2>/dev/null || true)"
  last_done="$(get_backup_done_status "$last_backup_name" 2>/dev/null || true)"
  last_reason="$(get_backup_done_reason "$last_backup_name" 2>/dev/null || true)"
  last_api_checkpoint="$(get_backup_checkpoint "$last_backup_name" 2>/dev/null || true)"
  tracker_checkpoint="$(get_tracker_checkpoint 2>/dev/null || true)"
  if [[ -z "$last_backup_name" || "$last_record_pass" != "$current_total" ||
        "$last_type" != Incremental || "$last_done" != True ||
        -z "$last_checkpoint" || "$last_checkpoint" != "$last_api_checkpoint" ||
        "$tracker_checkpoint" != "$last_checkpoint" ]] || backup_done_reason_is_failure "$last_reason"; then
    extension_error "last incremental backup/checkpoint is not a successful tracker base for pass $extension_target."
  fi

  check_target_resources_absent "$extension_target"
  workflow_action "Pass $extension_target will add $GUEST_INCREMENTAL_FILE_COUNT files at ${GUEST_FILE_SIZE_MIN_MIB}-${GUEST_FILE_SIZE_MAX_MIB} MiB; the selected manifest creates one new incremental PVC."
  vm_info_update \
    '.status = "extension_pending" |
     .extension_pending = {from_total: $from_total, target_total: $target_total,
                           pass: $target_total, status: "preparing",
                           requested_at: $updated_at}' \
    --argjson from_total "$current_total" \
    --argjson target_total "$extension_target"
  pending_extension="$(jq -c '.extension_pending' "$VM_INFO_PATH")"
  current_total="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
  vm_status="$(jq -r '.status' "$VM_INFO_PATH")"
  completed_passes="$(jq -r '.incremental_passes_completed' "$VM_INFO_PATH")"
  next_pass="$(jq -r '.next_incremental_pass // empty' "$VM_INFO_PATH")"
fi

pending_from="$(jq -r '.from_total // empty' <<< "$pending_extension")"
pending_target="$(jq -r '.target_total // empty' <<< "$pending_extension")"
if [[ "$pending_target" != "$extension_target" ||
      ! "$pending_from" =~ ^[1-9][0-9]?$ ]] ||
   ((pending_target != pending_from + 1 || pending_target > 99)); then
  extension_error "pending extension state does not match EXTEND_TO_PASS=$extension_target; inspect $VM_INFO_PATH."
fi

manifest_total="$(jq -r '.incremental_passes_total' "$manifest_path")"
manifest_pass_count="$(jq -r '.incrementals | length' "$manifest_path")"
if [[ "$current_total" == "$pending_from" && "$vm_status" == extension_pending &&
      "$completed_passes" == "$pending_from" ]]; then
  if [[ "$manifest_total" != "$pending_from" && "$manifest_total" != "$pending_target" ]]; then
    extension_error "pending extension expects manifest total $pending_from or $pending_target; found $manifest_total."
  fi
  if [[ "$manifest_pass_count" != "$pending_from" ]]; then
    extension_error "manifest contains $manifest_pass_count passes; expected $pending_from before extension."
  fi
  finalize_extension_plan "$pending_from" "$pending_target"
elif [[ "$current_total" == "$pending_target" && "$manifest_total" == "$pending_target" ]]; then
  :
else
  extension_error "pending extension state is inconsistent (state total=$current_total, manifest total=$manifest_total, status=$vm_status)."
fi

read_vm_state
manifest_total="$(jq -r '.incremental_passes_total' "$manifest_path")"
manifest_pass_count="$(jq -r '.incrementals | length' "$manifest_path")"
if [[ "$current_total" != "$pending_target" || "$manifest_total" != "$pending_target" ]]; then
  extension_error "extension plan is not synchronized (state total=$current_total, manifest total=$manifest_total, target=$pending_target)."
fi
if [[ "$completed_passes" == "$pending_from" ]]; then
  if [[ "$manifest_pass_count" != "$pending_from" ||
        "$next_pass" != "$pending_target" ]]; then
    extension_error "pass $pending_target is pending, but manifest/pass counters do not agree."
  fi
  if [[ -n "$pending_at_start" ]]; then
    validate_vm_ready_with_cbt
  fi
  case "$vm_status" in
    extension_pending)
      vm_info_update \
        '.status = "incremental_ready" |
         .next_incremental_pass = $target_total |
         .extension_pending.status = "ready" |
         .extension_pending.manifest_updated_at = $updated_at' \
        --argjson target_total "$pending_target"
      ;;
    incremental_ready) ;;
    incremental_running|incremental_failed)
      check_target_resources_absent "$pending_target"
      vm_info_update '.status = "incremental_ready" | del(.current_incremental_pass)'
      ;;
    *)
      extension_error "lifecycle status is $vm_status while pass $pending_target is pending; expected extension_pending, incremental_ready, or an uncommitted failed pass."
      ;;
  esac
  check_target_resources_absent "$pending_target"
elif [[ "$completed_passes" == "$pending_target" &&
        "$manifest_pass_count" == "$pending_target" ]]; then
  case "$vm_status" in
    verification_pending|verification_failed|complete) ;;
    *) extension_error "pass $pending_target is recorded, but lifecycle status is $vm_status; run verification or inspect state." ;;
  esac
else
  extension_error "completed passes=$completed_passes do not match pending extension from=$pending_from to=$pending_target."
fi

extension_requested_at="$(jq -r '.extension_pending.requested_at // empty' "$VM_INFO_PATH")"
write_extension_fragment "$pending_from" "$pending_target" "$extension_requested_at"
workflow_progress "Extension target $pending_target is prepared; the dispatcher will add that pass or verify it if already recorded."
