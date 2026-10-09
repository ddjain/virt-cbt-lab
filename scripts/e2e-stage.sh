#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
MAKE_COMMAND="${MAKE_COMMAND:-make}"
TYPE="${TYPE:-all}"
VM="${VM:-}"
NAME="${NAME:-}"
DEBUG="${DEBUG:-false}"
VM_OS="${VM_OS:-rhel9}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
EXTEND_TO_PASS="${EXTEND_TO_PASS:-}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-4}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-12}"
MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}"
RUNS_ROOT_DIR="$ROOT_DIR/runs"
E2E_STAGE_WRAPPED=true
export E2E_STAGE_WRAPPED

start_epoch="$(date +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$DEBUG" == true ]]; then
  printf '[%s] [make] E2E pipeline started for TYPE=%s (preflight included).\n' "$started_at" "$TYPE"
else
  printf 'E2E · TYPE=%s · VM_OS=%s\n' "$TYPE" "$VM_OS"
fi

status=0
run_id=""
vm_name=""
vm_info_path=""
run_namespace="$NAMESPACE"

fail() {
  printf '[e2e] %s\n' "$1" >&2
  status=2
}
mark_incremental_failure() {
  [[ -r "$vm_info_path" ]] || return 0
  if ! jq -e '.current_incremental_pass != null' "$vm_info_path" >/dev/null; then
    return 0
  fi
  local failed_at tmp_path
  failed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_path="${vm_info_path}.tmp.$$"
  jq --arg failed_at "$failed_at" \
    '.status = "incremental_failed" |
     .current_incremental_pass.status = "failed" |
     .current_incremental_pass.failed_at = $failed_at |
     .updated_at = $failed_at' "$vm_info_path" > "$tmp_path"
  mv -f "$tmp_path" "$vm_info_path"
}
log_final_verdict() {
  local outcome="$1" message="$2" elapsed="$3" lifecycle="$4"
  local timestamp line log_path box_width=52 index result_row result_symbol
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -v line '[%s] [make] Final verdict: %s' "$timestamp" "$message"
  if [[ "$DEBUG" == true ]]; then printf '%s\n' "$line"; fi
  if [[ -n "$run_id" ]]; then
    log_path="$RUNS_ROOT_DIR/$run_id/logs/workflow.log"
    if [[ -d "$(dirname "$log_path")" ]]; then
      printf '%s\n' "$line" >> "$log_path"
    fi
  fi

  case "$outcome" in
    PASS) result_symbol=✓ ;;
    FAIL) result_symbol=✗ ;;
    INCOMPLETE) result_symbol=◌ ;;
  esac
  printf '╭'
  for ((index = 0; index < box_width; index++)); do printf '─'; done
  printf '╮\n'
  printf '│ %-52s │\n' 'E2E RESULT'
  printf '│ %-52s │\n' ''
  result_row="Result: $result_symbol $outcome"
  printf '│ %s%*s │\n' "$result_row" "$((box_width - ${#result_row}))" ''
  printf '│ %-52s │\n' "Type: $TYPE"
  printf '│ %-52s │\n' "Lifecycle: $lifecycle"
  printf '│ %-52s │\n' "Total elapsed: $elapsed"
  printf '╰'
  for ((index = 0; index < box_width; index++)); do printf '─'; done
  printf '╯\n'
  if [[ "$DEBUG" != true ]]; then printf 'Details: %s\n' "$message"; fi
}

resolve_new_run_id() {
  if [[ -n "$VM" ]]; then
    if [[ "$VM" != vm-* ]]; then
      fail 'VM must use the workflow VM name form vm-<run-id>.'
      return
    fi
    run_id="${VM#vm-}"
    if [[ -n "$NAME" && "$NAME" != "$run_id" ]]; then
      fail 'NAME and VM identify different run IDs.'
      return
    fi
  else
    run_id="${NAME:-}"
    [[ -n "$run_id" ]] || run_id="$(generate_run_id)"
  fi
  if ! valid_run_id "$run_id"; then
    fail "Invalid run ID: $run_id"
    return
  fi
  vm_info_path="$RUNS_ROOT_DIR/$run_id/run.json"
}

load_vm_info() {
  if [[ -z "$VM" || "$VM" != vm-* ]]; then
    fail 'TYPE=incremental, extend, and verify require VM=vm-<run-id>.'
    return
  fi
  vm_name="$VM"
  run_id="${VM#vm-}"
  if ! valid_run_id "$run_id"; then
    fail "Invalid run ID: $run_id"
    return
  fi
  vm_info_path="$RUNS_ROOT_DIR/$run_id/run.json"
  if [[ ! -r "$vm_info_path" ]] || ! jq -e \
      --arg run_id "$run_id" --arg vm_name "$vm_name" \
      '.schema_version == 1 and .run_id == $run_id and .vm_name == $vm_name and
       (.vm_uid | type == "string" and length > 0) and .status != "cleaned"' \
      "$vm_info_path" >/dev/null; then
    fail "No valid managed run metadata found for $VM at $vm_info_path."
    return
  fi
  VM_OS="$(jq -r '.os_profile' "$vm_info_path")"
  run_namespace="$(jq -r '.namespace' "$vm_info_path")"
  GUEST_BASE_FILE_COUNT="$(jq -r '.guest.baseline.file_count' "$vm_info_path")"
  GUEST_INCREMENTAL_FILE_COUNT="$(jq -r '.guest.incremental_file_count_per_pass' "$vm_info_path")"
  GUEST_INCREMENTAL_PASSES="$(jq -r '.incremental_passes_total' "$vm_info_path")"
  GUEST_FILE_SIZE_MIN_MIB="$(jq -r '.guest.size_range_mib.min_inclusive' "$vm_info_path")"
  GUEST_FILE_SIZE_MAX_MIB="$(jq -r '.guest.size_range_mib.max_inclusive' "$vm_info_path")"
  MANIFEST_VARIANT="$(jq -r '.manifest_variant' "$vm_info_path")"
}
print_pipeline_summary() {
  local next_pass
  printf '\nPipeline configuration\n'
  printf '  TYPE=%s\n' "$TYPE"
  printf '  VM_OS=%s\n' "$VM_OS"
  printf '  MANIFEST_VARIANT=%s\n' "$MANIFEST_VARIANT"
  printf '  NAMESPACE=%s\n' "$run_namespace"
  printf '  DEBUG=%s\n' "$DEBUG"
  printf '  GUEST_BASE_FILE_COUNT=%s\n' "$GUEST_BASE_FILE_COUNT"
  printf '  GUEST_INCREMENTAL_FILE_COUNT=%s (new files/pass; modifies 1 baseline file)\n' \
    "$GUEST_INCREMENTAL_FILE_COUNT"
  printf '  GUEST_INCREMENTAL_PASSES=%s\n' "$GUEST_INCREMENTAL_PASSES"
  printf '  GUEST_FILE_SIZE_MIN_MIB=%s\n' "$GUEST_FILE_SIZE_MIN_MIB"
  printf '  GUEST_FILE_SIZE_MAX_MIB=%s\n' "$GUEST_FILE_SIZE_MAX_MIB"
  printf '  EXTEND_TO_PASS=%s\n' "${EXTEND_TO_PASS:-none}"
  if [[ -n "${RESTORE_HELPER_IMAGE:-}" ]]; then
    printf '  RESTORE_HELPER_IMAGE=configured (reference omitted)\n'
  else
    printf '  RESTORE_HELPER_IMAGE=unset\n'
  fi
  printf '  RUN_ID=%s\n' "$RUN_ID"
  printf '  VM_NAME=%s\n' "$VM_NAME"
  printf '\nResource plan\n'

  case "$TYPE" in
    all|full)
      printf '  Namespace: %s (created only if absent)\n' "$run_namespace"
      printf '  VirtualMachine: %s\n' "$VM_NAME"
      printf '  Root DataVolume/PVC: %s\n' "$DV_NAME"
      if [[ "$VM_OS" == windows ]]; then
        printf '  Run-scoped OOBE Secret: windows-oobe-%s\n' "$RUN_ID"
      else
        printf '  Guest SSH service: %s\n' "$SSH_SERVICE"
      fi
      printf '  Backup tracker: %s\n' "$TRACKER_NAME"
      printf '  Full VirtualMachineBackup: %s\n' "$FULL_BACKUP_NAME"
      printf '  Full backup PVC: %s\n' "$FULL_BACKUP_PVC_NAME"
      if [[ "$TYPE" == all ]]; then
        printf '  Incremental backups: %s pass(es), %s-pNN\n' \
          "$GUEST_INCREMENTAL_PASSES" "${INCREMENTAL_BACKUP_NAME%-p01}"
        printf '  Incremental backup PVCs: %s-pNN\n' \
          "${INCREMENTAL_BACKUP_PVC_NAME%-p01}"
        printf '  Restore verification pod: %s (temporary)\n' "$RESTORE_POD_NAME"
      else
        printf '  Incremental backup/PVC resources: deferred; %s pass(es) planned for later stages\n' \
          "$GUEST_INCREMENTAL_PASSES"
        printf '    Backup pattern: %s-pNN\n' "${INCREMENTAL_BACKUP_NAME%-p01}"
        printf '    PVC pattern: %s-pNN\n' "${INCREMENTAL_BACKUP_PVC_NAME%-p01}"
      fi
      ;;
    incremental)
      printf '  Existing VirtualMachine: %s\n' "$VM_NAME"
      next_pass="$(jq -r '.next_incremental_pass // empty' "$vm_info_path")"
      if [[ "$next_pass" =~ ^[1-9][0-9]?$ ]]; then
        printf '  New incremental VirtualMachineBackup: %s\n' \
          "$(incremental_backup_name_for_pass "$next_pass")"
        printf '  New incremental backup PVC: %s\n' \
          "$(incremental_backup_pvc_name_for_pass "$next_pass")"
        if [[ "$next_pass" == "$GUEST_INCREMENTAL_PASSES" ]]; then
          printf '  Restore verification pod: %s (temporary, final pass)\n' "$RESTORE_POD_NAME"
        fi
      else
        printf '  No incremental backup/PVC planned; the saved pass plan is complete\n'
      fi
      ;;
    extend)
      printf '  Existing VirtualMachine: %s\n' "$VM_NAME"
      if [[ "$EXTEND_TO_PASS" =~ ^[1-9][0-9]?$ ]]; then
        printf '  Extension VirtualMachineBackup: %s\n' \
          "$(incremental_backup_name_for_pass "$EXTEND_TO_PASS")"
        printf '  Extension backup PVC: %s\n' \
          "$(incremental_backup_pvc_name_for_pass "$EXTEND_TO_PASS")"
      fi
      printf '  Restore verification pod: %s (temporary)\n' "$RESTORE_POD_NAME"
      ;;
    verify)
      printf '  Existing VirtualMachine: %s\n' "$VM_NAME"
      printf '  Restore verification pod: %s (temporary)\n' "$RESTORE_POD_NAME"
      ;;
  esac
}

run_make() {
  "$MAKE_COMMAND" --no-print-directory "$@"
}

profile_args() {
  printf '%s\n' \
    "VM_OS=$VM_OS" \
    "DEBUG=$DEBUG" \
    "NAMESPACE=$run_namespace" \
    "GUEST_BASE_FILE_COUNT=$GUEST_BASE_FILE_COUNT" \
    "GUEST_INCREMENTAL_FILE_COUNT=$GUEST_INCREMENTAL_FILE_COUNT" \
    "GUEST_INCREMENTAL_PASSES=$GUEST_INCREMENTAL_PASSES" \
    "EXTEND_TO_PASS=$EXTEND_TO_PASS" \
    "GUEST_FILE_SIZE_MIN_MIB=$GUEST_FILE_SIZE_MIN_MIB" \
    "GUEST_FILE_SIZE_MAX_MIB=$GUEST_FILE_SIZE_MAX_MIB" \
    "MANIFEST_VARIANT=$MANIFEST_VARIANT"
}

run_profiled_make() {
  local target="$1"
  shift
  local -a args=()
  local start_epoch end_epoch step_status timing_timestamp timing_line
  while IFS= read -r arg; do args+=("$arg"); done < <(profile_args)
  start_epoch="$(date +%s)"
  if "$MAKE_COMMAND" --no-print-directory "$target" "$@" "${args[@]}"; then
    step_status=0
  else
    step_status=$?
  fi
  end_epoch="$(date +%s)"
  timing_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  timing_line="Step timing: target=$target elapsed_seconds=$((end_epoch - start_epoch))."
  if [[ -n "$run_id" && -d "$RUNS_ROOT_DIR/$run_id/logs" ]]; then
    printf '[%s] [make] %s\n' "$timing_timestamp" "$timing_line" >> "$RUNS_ROOT_DIR/$run_id/logs/workflow.log"
  fi
  if [[ "$DEBUG" == true ]]; then
    printf '[%s] [make] %s\n' "$timing_timestamp" "$timing_line" >&2
  fi
  return "$step_status"
}

case "$TYPE" in
  all)
    resolve_new_run_id
    ;;
  full)
    resolve_new_run_id
    ;;
  incremental|verify|extend)
    load_vm_info
    ;;
  *)
    fail "TYPE must be all, full, incremental, extend, or verify (got: $TYPE)."
    ;;
esac
if ((status == 0)); then
  RUN_ID="$run_id"
  set_resource_names
  vm_info_path="$VM_INFO_PATH"
fi

if ((status == 0)); then
  if [[ "$TYPE" == extend ]]; then
    if ! [[ "$EXTEND_TO_PASS" =~ ^[1-9][0-9]?$ ]] ||
       ((EXTEND_TO_PASS < 2 || EXTEND_TO_PASS > 99)); then
      fail 'TYPE=extend requires EXTEND_TO_PASS=<target total> from 2 to 99; use the next total, e.g. 4 to add pass 4.'
    fi
  elif [[ -n "$EXTEND_TO_PASS" ]]; then
    fail 'EXTEND_TO_PASS is only valid with TYPE=extend.'
  fi
fi
if ((status == 0)); then
  lock_dir="$ROOT_DIR/state/e2e.lock"
  mkdir -p "$ROOT_DIR/state"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
      fail "Another E2E operation is active in this checkout (PID $lock_pid); run lifecycle commands sequentially."
    else
      rm -rf "$lock_dir"
      if ! mkdir "$lock_dir" 2>/dev/null; then
        fail "Could not acquire E2E checkout lock at $lock_dir."
      fi
    fi
  fi
  if ((status == 0)); then
    printf '%s\n' "$$" > "$lock_dir/pid"
    release_e2e_lock() { rm -rf "$lock_dir"; }
    trap release_e2e_lock EXIT
  fi
fi
if ((status == 0)); then
  print_pipeline_summary
fi


if ((status == 0)); then
  if run_profiled_make preflight; then
    :
  else
    status=$?
  fi
fi

if ((status == 0)); then
  case "$TYPE" in
    all)
      if run_profiled_make vm-cbt-demo RUN_ID="$run_id"; then
        vm_name="vm-${run_id}"
      else
        status=$?
        mark_incremental_failure
      fi
      ;;
    full)
      if run_profiled_make vm-setup RUN_ID="$run_id"; then
        vm_name="vm-${run_id}"
        if run_profiled_make vm-backup RUN_ID="$run_id"; then
          :
        else
          status=$?
        fi
      else
        status=$?
      fi
      ;;
    incremental)
      completed="$(jq -r '.incremental_passes_completed' "$vm_info_path")"
      total="$(jq -r '.incremental_passes_total' "$vm_info_path")"
      if ((completed == total)); then
        fail "All $total planned incremental passes are complete for $VM; use TYPE=extend EXTEND_TO_PASS=$((total + 1)) to add one more."
      elif run_profiled_make vm-cbt-backup RUN_ID="$run_id"; then
        completed="$(jq -r '.incremental_passes_completed' "$vm_info_path")"
        total="$(jq -r '.incremental_passes_total' "$vm_info_path")"
        if ((completed == total)); then
          if run_profiled_make vm-cbt-verify RUN_ID="$run_id"; then
            :
          else
            status=$?
          fi
        fi
      else
        status=$?
        mark_incremental_failure
      fi
      vm_name="$VM"
      ;;
    extend)
      if run_profiled_make vm-cbt-extend RUN_ID="$run_id"; then
        load_vm_info
        if ((status == 0)); then
          completed="$(jq -r '.incremental_passes_completed' "$vm_info_path")"
          total="$(jq -r '.incremental_passes_total' "$vm_info_path")"
          if ((completed < total)); then
            if run_profiled_make vm-cbt-backup RUN_ID="$run_id"; then
              completed="$(jq -r '.incremental_passes_completed' "$vm_info_path")"
              total="$(jq -r '.incremental_passes_total' "$vm_info_path")"
            else
              status=$?
              mark_incremental_failure
            fi
          fi
          if ((status == 0)); then
            if run_profiled_make vm-cbt-verify RUN_ID="$run_id"; then
              :
            else
              status=$?
            fi
          fi
        fi
      else
        status=$?
      fi
      vm_name="$VM"
      ;;
    verify)
      if run_profiled_make vm-cbt-verify RUN_ID="$run_id"; then
        :
      else
        status=$?
      fi
      vm_name="$VM"
      ;;
  esac
fi
end_epoch="$(date +%s)"
ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
elapsed_seconds=$((end_epoch - start_epoch))
if ((status == 0)); then result=passed; else result=failed; fi
if [[ "$DEBUG" == true ]]; then
  printf '[%s] [make] E2E pipeline %s for TYPE=%s VM_OS=%s; total_elapsed_seconds=%s; started_at=%s.\n' \
    "$ended_at" "$result" "$TYPE" "$VM_OS" "$elapsed_seconds" "$started_at"
fi
if ((elapsed_seconds >= 3600)); then
  printf -v elapsed_display '%dh %02dm %02ds' \
    "$((elapsed_seconds / 3600))" "$(((elapsed_seconds % 3600) / 60))" "$((elapsed_seconds % 60))"
elif ((elapsed_seconds >= 60)); then
  printf -v elapsed_display '%dm %02ds' "$((elapsed_seconds / 60))" "$((elapsed_seconds % 60))"
else
  printf -v elapsed_display '%ds' "$elapsed_seconds"
fi

if ((status == 0)); then
  if [[ -z "$vm_name" && -n "$run_id" ]]; then vm_name="vm-${run_id}"; fi
  if [[ -n "$vm_name" ]]; then
    lifecycle_info_path="$RUNS_ROOT_DIR/$run_id/run.json"
    monitor_deferred=false
    if [[ -r "$lifecycle_info_path" ]]; then
      planned_passes="$(jq -r '.incremental_passes_total // 0' "$lifecycle_info_path")"
      completed_passes="$(jq -r '.incremental_passes_completed // 0' "$lifecycle_info_path")"
      if [[ "$completed_passes" =~ ^[0-9]+$ && "$planned_passes" =~ ^[0-9]+$ ]] &&
         ((completed_passes < planned_passes)); then
        monitor_deferred=true
      fi
    fi
    if [[ "$monitor_deferred" == true ]]; then
      if [[ "$DEBUG" == true ]]; then
        printf '[%s] [make] Backup timing monitor deferred: %s/%s planned incremental passes complete for VM=%s.\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$completed_passes" "$planned_passes" "$vm_name"
      else
        printf 'Backup timing monitor deferred · %s/%s incremental passes complete\n' \
          "$completed_passes" "$planned_passes"
      fi
    else
      if [[ "$DEBUG" == true ]]; then
        printf '[%s] [make] Collecting API-recorded backup timings for VM=%s.\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$vm_name"
      fi
      if ! run_profiled_make monitor VM="$vm_name"; then
        if [[ "$DEBUG" == true ]]; then
          printf '[%s] [make] WARNING: E2E passed but the backup timing monitor failed for VM=%s.\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$vm_name" >&2
        else
          printf '⚠ Backup timing monitor failed for VM=%s; E2E passed.\n' "$vm_name" >&2
        fi
      fi
    fi
  fi
fi
report_path="unavailable (run ID not resolved)"
if [[ -n "$run_id" ]]; then
  report_path="$RUNS_ROOT_DIR/$run_id/report.json"
fi
lifecycle_summary="not available"
if [[ -n "$run_id" && -r "$RUNS_ROOT_DIR/$run_id/run.json" ]]; then
  lifecycle_completed="$(jq -r '.incremental_passes_completed // 0' "$RUNS_ROOT_DIR/$run_id/run.json")"
  lifecycle_planned="$(jq -r '.incremental_passes_total // 0' "$RUNS_ROOT_DIR/$run_id/run.json")"
  lifecycle_summary="${lifecycle_completed}/${lifecycle_planned} incremental passes complete"
fi
if ((status != 0)); then
  final_outcome=FAIL
  final_verdict="FAIL: E2E pipeline failed for TYPE=$TYPE; inspect the preceding error output."
elif [[ "$TYPE" == full ]]; then
  completed_passes=0
  planned_passes="$GUEST_INCREMENTAL_PASSES"
  lifecycle_info_path="$RUNS_ROOT_DIR/$run_id/run.json"
  if [[ -r "$lifecycle_info_path" ]]; then
    completed_passes="$(jq -r '.incremental_passes_completed // 0' "$lifecycle_info_path")"
    planned_passes="$(jq -r '.incremental_passes_total // 0' "$lifecycle_info_path")"
  fi
  final_outcome=INCOMPLETE
  final_verdict="FULL BACKUP PASS; lifecycle INCOMPLETE (${completed_passes}/${planned_passes} planned incremental passes complete); report pending verification: $report_path"
elif [[ "$TYPE" == incremental ]]; then
  completed_passes=0
  planned_passes=0
  lifecycle_info_path="$RUNS_ROOT_DIR/$run_id/run.json"
  if [[ -r "$lifecycle_info_path" ]]; then
    completed_passes="$(jq -r '.incremental_passes_completed // 0' "$lifecycle_info_path")"
    planned_passes="$(jq -r '.incremental_passes_total // 0' "$lifecycle_info_path")"
  fi
  if ((completed_passes < planned_passes)); then
    final_outcome=INCOMPLETE
    final_verdict="INCREMENTAL PASS (${completed_passes}/${planned_passes}); lifecycle INCOMPLETE; final verification/report pending: $report_path"
  else
    final_outcome=PASS
    final_verdict="PASS; backup chain and restore verification passed; report: $report_path"
  fi
else
  final_outcome=PASS
  final_verdict="PASS; lifecycle and restore verification passed; report: $report_path"
fi
log_final_verdict "$final_outcome" "$final_verdict" "$elapsed_display" "$lifecycle_summary"
if [[ "$final_outcome" == INCOMPLETE &&
      ( "$TYPE" == full || "$TYPE" == incremental ) ]]; then
  next_vm="${vm_name:-vm-${run_id}}"
  printf '\nNext command:\n  make e2e TYPE=incremental VM=%s\n' "$next_vm"
  if ((completed_passes + 1 < planned_passes)); then
    printf 'Repeat this command for the remaining passes; the final pass runs verification.\n'
  else
    printf 'The next incremental pass is final and will run verification automatically.\n'
  fi
fi
if [[ -n "$run_id" && -r "$RUNS_ROOT_DIR/$run_id/run.json" ]]; then
  if summary_path="$(bash "$ROOT_DIR/scripts/write-run-summary.sh" \
      "$run_id" "$TYPE" "$final_outcome")"; then
    printf 'Summary: %s\n' "$summary_path"
  else
    printf '⚠ Could not write summary.json; detailed evidence remains in %s.\n' \
      "$report_path" >&2
  fi
fi


exit "$status"
