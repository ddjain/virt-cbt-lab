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

start_epoch="$(date +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '[%s] [make] E2E pipeline started for TYPE=%s (preflight included).\n' "$started_at" "$TYPE"

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
printf '[%s] [make] E2E pipeline %s for TYPE=%s VM_OS=%s; total_elapsed_seconds=%s; started_at=%s.\n' \
  "$ended_at" "$result" "$TYPE" "$VM_OS" "$elapsed_seconds" "$started_at"

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
      printf '[%s] [make] Backup timing monitor deferred: %s/%s planned incremental passes complete for VM=%s.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$completed_passes" "$planned_passes" "$vm_name"
    else
      if [[ "$DEBUG" == true ]]; then
        printf '[%s] [make] Collecting API-recorded backup timings for VM=%s.\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$vm_name"
      fi
      if ! run_profiled_make monitor VM="$vm_name"; then
        printf '[%s] [make] WARNING: E2E passed but the backup timing monitor failed for VM=%s.\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$vm_name" >&2
      fi
    fi
  fi
fi
exit "$status"
