#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/oc"
chmod +x "$TEST_TMP/bin/oc"
PATH="$TEST_TMP/bin:$PATH"
export PATH
unset KUBECONFIG KUBECONFIG_PATH || true

source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/workload-manifest.sh"
if valid_run_id '../outside'; then
  printf 'A path-like run ID passed validation.\n' >&2
  exit 1
fi
generated_run_id="$(generate_run_id)"
if ! [[ "$generated_run_id" =~ ^[0-9]{14}-[a-z]+-[a-z]+-[0-9a-f]{4}$ ]] ||
   ! valid_run_id "$generated_run_id"; then
  printf 'Generated run ID does not have the timestamp-prefixed format: %s\n' \
    "$generated_run_id" >&2
  exit 1
fi
RUN_ID="$generated_run_id"
generated_incremental_pvc_name="$(incremental_backup_pvc_name_for_pass 99)"
if (( ${#generated_incremental_pvc_name} > 63 )); then
  printf 'Generated run ID makes the incremental PVC name exceed 63 characters: %s\n' \
    "$generated_incremental_pvc_name" >&2
  exit 1
fi


generated_run_id="$(generate_run_id)"
if ! [[ "$generated_run_id" =~ ^[0-9]{14}-[a-z]+-[a-z]+-[0-9a-f]{4}$ ]] ||
   ! valid_run_id "$generated_run_id"; then
  printf 'Generated run ID does not have the timestamp-prefixed format: %s\n' \
    "$generated_run_id" >&2
  exit 1
fi
RUN_ID="$generated_run_id"
generated_incremental_pvc_name="$(incremental_backup_pvc_name_for_pass 99)"
if (( ${#generated_incremental_pvc_name} > 63 )); then
  printf 'Generated run ID makes the incremental PVC name exceed 63 characters: %s\n' \
    "$generated_incremental_pvc_name" >&2
  exit 1
fi

RUN_ID=multi-pass-test
VM_NAME="vm-$RUN_ID"
NAMESPACE=vm-cbt-demo
VM_OS=debian
RUNS_ROOT_DIR="$TEST_TMP/runs"
REPORT_DIR="$RUNS_ROOT_DIR/$RUN_ID"
WORKLOAD_MANIFEST_NAME=workload-manifest.json
GUEST_WORKLOAD_DIR=/home/cbt-demo/cbt-workload
GUEST_BASE_FILE_COUNT=2
GUEST_INCREMENTAL_FILE_COUNT=2
GUEST_INCREMENTAL_PASSES=3
GUEST_FILE_SIZE_MIN_MIB=1
GUEST_FILE_SIZE_MAX_MIB=2
MANIFEST_VARIANT=default
set_resource_names
initialize_run_directory
[[ "$VM_INFO_PATH" == "$RUNS_ROOT_DIR/$RUN_ID/run.json" ]]
if initialize_run_directory >/dev/null 2>&1; then
  printf 'An existing run directory was unexpectedly reusable.\n' >&2
  exit 1
fi
records_for_plan() {
  local phase="$1" count="$2" pass="${3:-}" plan name size hash
  if [[ "$phase" == baseline ]]; then
    plan="$(workload_file_plan baseline "$count")"
  else
    plan="$(workload_file_plan incremental "$count" "$pass")"
  fi
  while IFS='|' read -r name size; do
    [[ -n "$name" ]] || continue
    hash="$(printf 'CBT-WORKLOAD-V1:%s\n' "$name" | workload_sha256_stdin)"
    printf 'FILE_RECORD=%s|%s|%s\n' "$name" "$size" "$hash"
  done <<< "$plan"
}
records_for_modification() {
  local pass="$1" plan name size_bytes sha256
  plan="$(workload_modified_file_plan "$pass")"
  IFS='|' read -r name size_bytes <<< "$plan"
  sha256="$(workload_modified_file_sha256 "$name" "$pass" "$size_bytes")"
  printf 'FILE_RECORD=%s|%s|%s\n' "$name" "$size_bytes" "$sha256"
}


(
  RUN_NAME=multi-pass-chaos-test
  NAMESPACE=vm-cbt-demo
  VM_NAME="vm-$RUN_NAME"
  TARGET_BACKUP=incremental
  INCREMENTAL_PASS=3
  unset TARGET_BACKUP_NAME INCREMENTAL_BACKUP_PVC_NAME
  source "$ROOT_DIR/cbt-chaos/scenarios/trigger-common.sh"
  chaos_set_run_names
  [[ "$TARGET_BACKUP_NAME" == "vm-incremental-${RUN_NAME}-p03" ]]
  [[ "$INCREMENTAL_BACKUP_PVC_NAME" == "vm-incremental-pvc-${RUN_NAME}-p03" ]]
)
printf 'PASS: chaos triggers target pass-specific backup and PVC names.\n'

baseline_records="$(workload_records_from_output "$(records_for_plan baseline "$GUEST_BASE_FILE_COUNT")")"
workload_manifest_initialize "$baseline_records"
vm_info_initialize "test-vm-uid"
jq -e --arg run_id "$RUN_ID" --arg vm_uid "test-vm-uid" \
  '.run_id == $run_id and .vm_uid == $vm_uid and .vm_name == ("vm-" + $run_id)' \
  "$VM_INFO_PATH" >/dev/null
vm_info_update '.backups.full = {name:"vm-backup-test", type:"Full", checkpoint_name:"checkpoint-full"} | .status="incremental_ready"'
[[ "$(vm_info_previous_checkpoint)" == "checkpoint-full" ]]
workload_manifest_validate "$(workload_manifest_path)" false

if workload_manifest_validate "$(workload_manifest_path)" true >/dev/null 2>&1; then
  printf 'Incomplete manifest unexpectedly passed final validation.\n' >&2
  exit 1
fi
manifest_path="$(workload_manifest_path)"
expected_cumulative_payload_bytes="$(jq -r '.baseline.total_payload_bytes' "$manifest_path")"
manifest_snapshot="$(jq -c . "$manifest_path")"
pass_two_records="$(workload_records_from_output "$(records_for_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT" 2)")"
pass_two_modified_records="$(workload_records_from_output "$(records_for_modification 2)")"
if workload_manifest_append_incremental 2 "$pass_two_records" "$pass_two_modified_records" "2026-01-01T00:00:02Z" >/dev/null 2>&1; then
  printf 'Out-of-order incremental pass unexpectedly modified the workload manifest.\n' >&2
  exit 1
fi
[[ "$(jq -c . "$manifest_path")" == "$manifest_snapshot" ]]


expected_cumulative_records="$baseline_records"
for pass in 1 2 3; do
  [[ "$(vm_info_next_pass)" == "$pass" ]]
  pass_records="$(workload_records_from_output "$(records_for_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT" "$pass")")"
  pass_modified_records="$(workload_records_from_output "$(records_for_modification "$pass")")"
  modification_plan="$(workload_modified_file_plan "$pass")"
  IFS='|' read -r modified_path modified_size <<< "$modification_plan"
  previous_modified_hash="$(jq -r --arg path "$modified_path" \
    '[.[] | select(.path == $path) | .sha256] | last // empty' <<< "$expected_cumulative_records")"
  modified_hash="$(jq -r '.[0].sha256' <<< "$pass_modified_records")"
  [[ -n "$previous_modified_hash" && "$previous_modified_hash" != "$modified_hash" ]]
  expected_cumulative_records="$(workload_records_apply_modifications "$expected_cumulative_records" "$pass_modified_records")"
  expected_cumulative_records="$(workload_records_concat "$expected_cumulative_records" "$pass_records")"
  workload_manifest_append_incremental "$pass" "$pass_records" "$pass_modified_records" "2026-01-01T00:00:0${pass}Z"
  manifest_state_records="$(workload_manifest_current_records "$manifest_path" "$pass")"
  workload_manifest_verify_inventory "$manifest_state_records" "$expected_cumulative_records" "Pass $pass manifest"
  record="$(jq -cn --argjson pass "$pass" --arg name "vm-incremental-${RUN_ID}-p$(printf '%02d' "$pass")" \
    --arg checkpoint "checkpoint-$pass" --arg modified_hash "$modified_hash" \
    --arg modified_path "$modified_path" \
    '{pass:$pass,name:$name,checkpoint_name:$checkpoint,status:"done",
      files_modified:1,modified_manifest_sha256:$modified_hash,modified_path:$modified_path}')"
  vm_info_update \
    '.backups.incrementals += [$record] |
     .incremental_passes_completed = $pass |
     .next_incremental_pass = (if $pass == $total then null else ($pass + 1) end) |
     .status = (if $pass == $total then "verification_pending" else "incremental_ready" end)' \
    --argjson pass "$pass" --argjson total "$GUEST_INCREMENTAL_PASSES" --argjson record "$record"
  [[ "$(vm_info_previous_checkpoint)" == "checkpoint-$pass" ]]
  workload_manifest_validate "$(workload_manifest_path)" false
  pass_index=$((pass - 1))
  added_payload_bytes="$(jq -r ".incrementals[$pass_index].added_payload_bytes" "$manifest_path")"
  added_files_payload_bytes="$(jq -r ".incrementals[$pass_index].files | map(.size_bytes) | add // 0" "$manifest_path")"
  [[ "$added_payload_bytes" == "$added_files_payload_bytes" ]]
  [[ "$(jq -r ".incrementals[$pass_index].modified_file_count" "$manifest_path")" == 1 ]]
  [[ "$(jq -r ".incrementals[$pass_index].files_modified[0].path" "$manifest_path")" == "$modified_path" ]]
  expected_cumulative_payload_bytes=$((expected_cumulative_payload_bytes + added_payload_bytes))
  [[ "$(jq -r ".incrementals[$pass_index].pass" "$manifest_path")" == "$pass" ]]
  [[ "$(jq -r ".incrementals[$pass_index].total_file_count" "$manifest_path")" == "$((GUEST_BASE_FILE_COUNT + pass * GUEST_INCREMENTAL_FILE_COUNT))" ]]
  [[ "$(jq -r ".incrementals[$pass_index].total_payload_bytes" "$manifest_path")" == "$expected_cumulative_payload_bytes" ]]
  [[ "$(jq -r '.incremental_passes_completed' "$VM_INFO_PATH")" == "$pass" ]]
  if ((pass < GUEST_INCREMENTAL_PASSES)); then
    expected_next="$((pass + 1))"
    expected_status=incremental_ready
  else
    expected_next=""
    expected_status=verification_pending
  fi
  [[ "$(jq -r '.next_incremental_pass // empty' "$VM_INFO_PATH")" == "$expected_next" ]]
  [[ "$(jq -r '.status' "$VM_INFO_PATH")" == "$expected_status" ]]
done

workload_manifest_validate "$(workload_manifest_path)" true
[[ "$(jq -r '.combined.total_file_count' "$manifest_path")" == "$((GUEST_BASE_FILE_COUNT + GUEST_INCREMENTAL_PASSES * GUEST_INCREMENTAL_FILE_COUNT))" ]]
[[ "$(jq -r '.combined.total_payload_bytes' "$manifest_path")" == "$expected_cumulative_payload_bytes" ]]
[[ "$(jq -r '[.baseline.files[].path] + [.incrementals[].files[].path] | unique | length' "$manifest_path")" == "$((GUEST_BASE_FILE_COUNT + GUEST_INCREMENTAL_PASSES * GUEST_INCREMENTAL_FILE_COUNT))" ]]
[[ "$(vm_info_next_pass 2>/dev/null || true)" == "" ]]
[[ "$(incremental_backup_name_for_pass 1)" == "vm-incremental-${RUN_ID}-p01" ]]
[[ "$(incremental_backup_name_for_pass 3)" == "vm-incremental-${RUN_ID}-p03" ]]
[[ "$(incremental_backup_name_for_pass 99)" == "vm-incremental-${RUN_ID}-p99" ]]
[[ "$(incremental_backup_pvc_name_for_pass 1)" == "vm-incremental-pvc-${RUN_ID}-p01" ]]
[[ "$(incremental_backup_pvc_name_for_pass 99)" == "vm-incremental-pvc-${RUN_ID}-p99" ]]

manifest_before_extension="$(jq -c . "$manifest_path")"
if workload_manifest_extend_plan "$manifest_path" 3 5 >/dev/null 2>&1; then
  printf 'A multi-pass extension beyond one planned pass unexpectedly succeeded.\n' >&2
  exit 1
fi
[[ "$(jq -c . "$manifest_path")" == "$manifest_before_extension" ]]
workload_manifest_extend_plan "$manifest_path" 3 4
[[ "$(jq -r '.incremental_passes_total' "$manifest_path")" == 4 ]]
[[ "$(jq -r '.incrementals | length' "$manifest_path")" == 3 ]]
workload_manifest_validate "$manifest_path" false
manifest_after_extension="$(jq -c . "$manifest_path")"
workload_manifest_extend_plan "$manifest_path" 3 4
[[ "$(jq -c . "$manifest_path")" == "$manifest_after_extension" ]]
GUEST_INCREMENTAL_PASSES=4
pass_four_records="$(workload_records_from_output "$(records_for_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT" 4)")"
pass_four_modified_records="$(workload_records_from_output "$(records_for_modification 4)")"
modification_plan="$(workload_modified_file_plan 4)"
IFS='|' read -r modified_path modified_size <<< "$modification_plan"
expected_cumulative_records="$(workload_records_apply_modifications "$expected_cumulative_records" "$pass_four_modified_records")"
expected_cumulative_records="$(workload_records_concat "$expected_cumulative_records" "$pass_four_records")"
workload_manifest_append_incremental 4 "$pass_four_records" "$pass_four_modified_records" "2026-01-01T00:00:04Z"
manifest_state_records="$(workload_manifest_current_records "$manifest_path" 4)"
workload_manifest_verify_inventory "$manifest_state_records" "$expected_cumulative_records" "Pass 4 manifest"
workload_manifest_validate "$manifest_path" true
[[ "$(jq -r '.incrementals | length' "$manifest_path")" == 4 ]]
[[ "$(jq -r '.combined.total_file_count' "$manifest_path")" == 10 ]]
GUEST_INCREMENTAL_PASSES=3

stage_checkout="$TEST_TMP/stage-checkout"
stage_script="$stage_checkout/scripts/e2e-stage.sh"
mkdir -p "$stage_checkout/scripts"
cp "$ROOT_DIR/scripts/e2e-stage.sh" "$stage_script"
cp "$ROOT_DIR/scripts/run-id.sh" "$stage_checkout/scripts/run-id.sh"
fake_make="$TEST_TMP/fake-make"
cat > "$fake_make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
target="${2:-}"
if [[ -z "$target" ]]; then
  printf 'Fake Make received no target.\n' >&2
  exit 90
fi
printf '%s\n' "$target" >> "$MAKE_LOG"
case "$target" in
  preflight|monitor|vm-cbt-verify)
    ;;
  vm-setup)
    run_id_arg=""
    for arg in "$@"; do
      if [[ "$arg" == RUN_ID=* ]]; then run_id_arg="${arg#RUN_ID=}"; fi
    done
    if [[ -z "$run_id_arg" || -z "${TEST_STAGE_ROOT:-}" ]]; then
      printf 'Fake Make received an incomplete VM setup request.\n' >&2
      exit 90
    fi
    ;;
  vm-backup)
    ;;
  vm-cbt-extend)
    target_pass="${EXTEND_TO_PASS:-}"
    total="$(jq -r '.incremental_passes_total' "$TEST_VM_INFO")"
    completed="$(jq -r '.incremental_passes_completed' "$TEST_VM_INFO")"
    status="$(jq -r '.status' "$TEST_VM_INFO")"
    if [[ "$status" != complete || "$completed" != "$total" || "$target_pass" != "$((total + 1))" ]]; then
      printf 'Extension target does not match a completed lifecycle.\n' >&2
      exit 43
    fi
    jq --argjson from "$total" --argjson target "$target_pass" \
      '.incremental_passes_total = $target |
       .next_incremental_pass = $target |
       .status = "incremental_ready" |
       .extension_pending = {from_total: $from, target_total: $target,
                             pass: $target, status: "ready"}' \
      "$TEST_VM_INFO" > "$TEST_VM_INFO.tmp"
    mv "$TEST_VM_INFO.tmp" "$TEST_VM_INFO"
    ;;
  vm-cbt-backup)
    pass="$(jq -r '.next_incremental_pass' "$TEST_VM_INFO")"
    total="$(jq -r '.incremental_passes_total' "$TEST_VM_INFO")"
    if [[ "${FAKE_MAKE_FAIL_BACKUP:-false}" == true ]]; then
      jq --argjson pass "$pass" \
        '.status = "incremental_running" |
         .current_incremental_pass = {pass: $pass, status: "running"}' \
        "$TEST_VM_INFO" > "$TEST_VM_INFO.tmp"
      mv "$TEST_VM_INFO.tmp" "$TEST_VM_INFO"
      exit 42
    fi
    jq --argjson pass "$pass" --argjson total "$total" \
      '.backups.incrementals += [{pass: $pass,
                                  checkpoint_name: ("checkpoint-" + ($pass | tostring))}] |
       .incremental_passes_completed = $pass |
       .next_incremental_pass = (if $pass == $total then null else $pass + 1 end) |
       .status = (if $pass == $total then "verification_pending" else "incremental_ready" end) |
       del(.current_incremental_pass)' \
      "$TEST_VM_INFO" > "$TEST_VM_INFO.tmp"
    mv "$TEST_VM_INFO.tmp" "$TEST_VM_INFO"
    ;;
  *)
    printf 'Unexpected fake Make target: %s\n' "$target" >&2
    exit 90
    ;;
esac
FAKE_MAKE
chmod +x "$fake_make"

prepare_stage_state() {
  local run_id="$1" passes="$2" info_path
  info_path="$stage_checkout/runs/$run_id/run.json"
  mkdir -p "$(dirname "$info_path")"
  mkdir -p "$(dirname "$info_path")/logs"
  jq -n --arg run_id "$run_id" --argjson passes "$passes" '
    {schema_version: 1, run_id: $run_id, vm_name: ("vm-" + $run_id),
     vm_uid: ("uid-" + $run_id), namespace: "saved-namespace", os_profile: "rhel9",
     manifest_variant: "large-odf", status: "incremental_ready",
     incremental_passes_total: $passes, incremental_passes_completed: 0,
     next_incremental_pass: 1,
     guest: {baseline: {file_count: 7}, incremental_file_count_per_pass: 3,
             size_range_mib: {min_inclusive: 5, max_inclusive: 10}},
     backups: {full: {checkpoint_name: "checkpoint-full"}, incrementals: []},
     current_incremental_pass: null}' > "$info_path"
  printf '%s' "$info_path"
}

run_incremental_stage() {
  local run_id="$1" fail_backup="${2:-false}" info_path calls_path
  info_path="$stage_checkout/runs/$run_id/run.json"
  calls_path="$TEST_TMP/$run_id-make-calls.targets"
  : > "$calls_path"
  env \
    MAKE_COMMAND="$fake_make" \
    MAKE_LOG="$calls_path" \
    TEST_VM_INFO="$info_path" \
    FAKE_MAKE_FAIL_BACKUP="$fail_backup" \
    TYPE=incremental \
    VM="vm-$run_id" \
    bash "$stage_script" > "$TEST_TMP/$run_id-e2e-stage.log" 2>&1
}
run_extend_stage() {
  local run_id="$1" target_pass="$2" info_path calls_path
  info_path="$stage_checkout/runs/$run_id/run.json"
  calls_path="$TEST_TMP/$run_id-make-calls.targets"
  : > "$calls_path"
  env \
    MAKE_COMMAND="$fake_make" \
    MAKE_LOG="$calls_path" \
    TEST_VM_INFO="$info_path" \
    FAKE_MAKE_FAIL_BACKUP=false \
    EXTEND_TO_PASS="$target_pass" \
    TYPE=extend \
    VM="vm-$run_id" \
    bash "$stage_script" > "$TEST_TMP/$run_id-e2e-stage.log" 2>&1
}
run_full_stage() {
  local run_id="$1" info_path calls_path
  info_path="$stage_checkout/runs/$run_id/run.json"
  calls_path="$TEST_TMP/$run_id-make-calls.targets"
  : > "$calls_path"
  if env \
    MAKE_COMMAND="$fake_make" \
    MAKE_LOG="$calls_path" \
    TEST_VM_INFO="$info_path" \
    TEST_STAGE_ROOT="$stage_checkout" \
    TYPE=full \
    NAME="$run_id" \
    GUEST_INCREMENTAL_PASSES=1 \
    VM_OS=rhel9 \
    MANIFEST_VARIANT=large-odf \
    NAMESPACE=vm-cbt-demo \
    DEBUG=false \
    GUEST_BASE_FILE_COUNT=8 \
    GUEST_INCREMENTAL_FILE_COUNT=4 \
    GUEST_FILE_SIZE_MIN_MIB=4 \
    GUEST_FILE_SIZE_MAX_MIB=12 \
    RESTORE_HELPER_IMAGE=quay.io/example/restore-helper:test \
    bash "$stage_script" > "$TEST_TMP/$run_id-e2e-stage.log" 2>&1; then
    :
  else
    local status=$?
    cat "$TEST_TMP/$run_id-e2e-stage.log" >&2
    return "$status"
  fi
}

assert_stage_targets() {
  local run_id="$1" expected="$2" actual
  actual="$(jq -Rsc 'split("\n") | map(select(length > 0))' "$TEST_TMP/$run_id-make-calls.targets")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Unexpected targets for %s: expected %s, got %s.\n' \
      "$run_id" "$expected" "$actual" >&2
    return 1
  fi
}

prepare_completed_stage_state() {
  local run_id="$1" passes="$2" info_path
  info_path="$(prepare_stage_state "$run_id" "$passes")"
  jq --argjson passes "$passes" '
    .status = "complete" |
    .incremental_passes_completed = $passes |
    .next_incremental_pass = null |
    .backups.incrementals =
      [range(1; $passes + 1) as $pass |
       {pass: $pass, checkpoint_name: ("checkpoint-" + ($pass | tostring))}]
  ' "$info_path" > "$info_path.tmp"
  mv "$info_path.tmp" "$info_path"
  printf '%s' "$info_path"
}
assert_final_verdict() {
  local run_id="$1" expected="$2" output log_path log_output outcome terminal_message
  output="$(<"$TEST_TMP/$run_id-e2e-stage.log")"
  log_path="$stage_checkout/runs/$run_id/logs/workflow.log"
  case "$expected" in
    "Final verdict: FULL BACKUP PASS;"*) outcome=INCOMPLETE ;;
    "Final verdict: INCREMENTAL PASS "*INCOMPLETE*) outcome=INCOMPLETE ;;
    "Final verdict: PASS;"*) outcome=PASS ;;
    "Final verdict: FAIL:"*) outcome=FAIL ;;
    *) printf 'Unexpected final verdict expectation: %s\n' "$expected" >&2; return 1 ;;
  esac
  terminal_message="${expected#Final verdict: }"
  if [[ "$output" != *'E2E RESULT'* ||
        "$output" != *"Result:"*"$outcome"* ||
        "$output" != *'Total elapsed:'* ||
        "$output" != *"Details: $terminal_message"* ||
        ! -f "$log_path" ]]; then
    printf 'Expected final result box and detail in terminal output for %s:\n%s\n' \
      "$run_id" "$expected" >&2
    return 1
  fi
  log_output="$(<"$log_path")"
  if [[ "$log_output" != *"$expected"* ]]; then
    printf 'Expected timestamped verdict in workflow log for %s:\n%s\n' \
      "$run_id" "$expected" >&2
    return 1
  fi
  if [[ "$outcome" == INCOMPLETE &&
        ( "$output" != *'Next command:'* ||
          "$output" != *"make e2e TYPE=incremental VM=vm-$run_id"* ) ]]; then
    printf 'Incomplete stage did not print the next incremental command for %s.\n' \
      "$run_id" >&2
    return 1
  fi
}

full_run_id=full-stage-test
full_info_path="$(prepare_stage_state "$full_run_id" 1)"
run_full_stage "$full_run_id"
full_output="$(<"$TEST_TMP/$full_run_id-e2e-stage.log")"
if [[ "$full_output" != *'Pipeline configuration'* ||
      "$full_output" != *'TYPE=full'* ||
      "$full_output" != *'VM_OS=rhel9'* ||
      "$full_output" != *'MANIFEST_VARIANT=large-odf'* ||
      "$full_output" != *'NAMESPACE=vm-cbt-demo'* ||
      "$full_output" != *'DEBUG=false'* ||
      "$full_output" != *'GUEST_BASE_FILE_COUNT=8'* ||
      "$full_output" != *'GUEST_INCREMENTAL_FILE_COUNT=4'* ||
      "$full_output" != *'GUEST_INCREMENTAL_PASSES=1'* ||
      "$full_output" != *'GUEST_FILE_SIZE_MIN_MIB=4'* ||
      "$full_output" != *'GUEST_FILE_SIZE_MAX_MIB=12'* ||
      "$full_output" != *'RESTORE_HELPER_IMAGE=configured (reference omitted)'* ||
      "$full_output" != *'EXTEND_TO_PASS=none'* ||
      "$full_output" != *"RUN_ID=$full_run_id"* ||
      "$full_output" != *"VM_NAME=vm-$full_run_id"* ||
      "$full_output" != *"VirtualMachine: vm-$full_run_id"* ||
      "$full_output" != *"Root DataVolume/PVC: vm-disk-$full_run_id"* ||
      "$full_output" != *"Guest SSH service: vm-ssh-$full_run_id"* ||
      "$full_output" != *"Full backup PVC: vm-backup-pvc-$full_run_id"* ||
      "$full_output" != *'Incremental backup/PVC resources: deferred'* ]]; then
  printf 'Startup summary omitted effective settings or planned resources.\n%s\n' "$full_output" >&2
  exit 1
fi
assert_stage_targets "$full_run_id" '["preflight","vm-setup","vm-backup"]'
[[ "$(jq -r '.incremental_passes_completed' "$full_info_path")" == 0 ]]
assert_final_verdict "$full_run_id" \
  "Final verdict: FULL BACKUP PASS; lifecycle INCOMPLETE (0/1 planned incremental passes complete); report pending verification: $stage_checkout/runs/$full_run_id/report.json"

stage_run_id=stage-test
stage_info_path="$(prepare_stage_state "$stage_run_id" 3)"
for pass in 1 2 3; do
  run_incremental_stage "$stage_run_id"
  if ((pass < 3)); then
    assert_stage_targets "$stage_run_id" '["preflight","vm-cbt-backup"]'
    expected_stage_status=incremental_ready
    assert_final_verdict "$stage_run_id" \
      "Final verdict: INCREMENTAL PASS ($pass/3); lifecycle INCOMPLETE; final verification/report pending: $stage_checkout/runs/$stage_run_id/report.json"
  else
    assert_stage_targets "$stage_run_id" '["preflight","vm-cbt-backup","vm-cbt-verify","monitor"]'
    expected_stage_status=verification_pending
    assert_final_verdict "$stage_run_id" \
      "Final verdict: PASS; backup chain and restore verification passed; report: $stage_checkout/runs/$stage_run_id/report.json"
  fi
  [[ "$(jq -r '.incremental_passes_completed' "$stage_info_path")" == "$pass" ]]
  [[ "$(jq -r '.status' "$stage_info_path")" == "$expected_stage_status" ]]
done


failure_run_id=failed-stage-test
failure_info_path="$(prepare_stage_state "$failure_run_id" 3)"
if run_incremental_stage "$failure_run_id" true; then
  printf 'A failed incremental command unexpectedly passed.\n' >&2
  exit 1
else
  failed_stage_status=$?
fi
[[ "$failed_stage_status" == 42 ]]
assert_stage_targets "$failure_run_id" '["preflight","vm-cbt-backup"]'
assert_final_verdict "$failure_run_id" \
  "Final verdict: FAIL: E2E pipeline failed for TYPE=incremental; inspect the preceding error output."
jq -e '
  .status == "incremental_failed" and
  .current_incremental_pass.status == "failed" and
  .incremental_passes_completed == 0 and .next_incremental_pass == 1
' "$failure_info_path" >/dev/null

extension_run_id=extend-stage-test
extension_info_path="$(prepare_completed_stage_state "$extension_run_id" 3)"
run_extend_stage "$extension_run_id" 4
assert_stage_targets "$extension_run_id" '["preflight","vm-cbt-extend","vm-cbt-backup","vm-cbt-verify","monitor"]'
jq -e '
  .status == "verification_pending" and
  .incremental_passes_total == 4 and
  .incremental_passes_completed == 4 and
  .next_incremental_pass == null and
  .backups.incrementals[-1].pass == 4 and
  .extension_pending.target_total == 4
' "$extension_info_path" >/dev/null

invalid_extension_run_id=invalid-extension-test
invalid_extension_info_path="$(prepare_completed_stage_state "$invalid_extension_run_id" 3)"
if run_extend_stage "$invalid_extension_run_id" 5; then
  printf 'An extension that skips a pass unexpectedly succeeded.\n' >&2
  exit 1
else
  invalid_extension_status=$?
fi
[[ "$invalid_extension_status" == 43 ]]
assert_stage_targets "$invalid_extension_run_id" '["preflight","vm-cbt-extend"]'
jq -e '
  .status == "complete" and
  .incremental_passes_total == 3 and
  .incremental_passes_completed == 3 and
  .next_incremental_pass == null
' "$invalid_extension_info_path" >/dev/null


# Regression for high-cardinality inventories that exceeded jq's per-argument
# limit. Keep file sizing deterministic and cheap; the small scenario above
# covers the filename-derived size algorithm.
RUN_ID=large-manifest-test
VM_NAME="vm-$RUN_ID"
set_resource_names
REPORT_DIR="$RUN_DIR"
WORKLOAD_MANIFEST_NAME=workload-manifest.json
GUEST_WORKLOAD_DIR=/home/cbt-demo/cbt-workload
GUEST_BASE_FILE_COUNT=1000
GUEST_INCREMENTAL_FILE_COUNT=500
GUEST_INCREMENTAL_PASSES=3
GUEST_FILE_SIZE_MIN_MIB=10
GUEST_FILE_SIZE_MAX_MIB=15
mkdir -p "$REPORT_DIR"
workload_file_size_bytes() {
  printf '12582912'
}
large_records_for_plan() {
  local phase="$1" count="$2" pass="${3:-}" plan name size
  if [[ "$phase" == baseline ]]; then
    plan="$(workload_file_plan baseline "$count")"
  else
    plan="$(workload_file_plan incremental "$count" "$pass")"
  fi
  while IFS='|' read -r name size; do
    [[ -n "$name" ]] || continue
    printf 'FILE_RECORD=%s|%s|0000000000000000000000000000000000000000000000000000000000000000\n' \
      "$name" "$size"
  done <<< "$plan"
}
large_modified_records_for_pass() {
  local pass="$1" plan name size sha256
  plan="$(workload_modified_file_plan "$pass")"
  IFS='|' read -r name size <<< "$plan"
  sha256="$(workload_modified_file_sha256 "$name" "$pass" "$size")"
  printf 'FILE_RECORD=%s|%s|%s\n' "$name" "$size" "$sha256"
}
large_baseline_records="$(workload_records_from_output "$(large_records_for_plan baseline "$GUEST_BASE_FILE_COUNT")")"
[[ "$(workload_records_count "$large_baseline_records")" == 1000 ]]
workload_manifest_initialize "$large_baseline_records"
large_manifest="$(workload_manifest_path)"
large_combined_records="$large_baseline_records"
for pass in 1 2 3; do
  large_pass_records="$(workload_records_from_output "$(large_records_for_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT" "$pass")")"
  large_modified_records="$(workload_records_from_output "$(large_modified_records_for_pass "$pass")")"
  [[ "$(workload_records_count "$large_pass_records")" == 500 ]]
  large_combined_records="$(workload_records_apply_modifications "$large_combined_records" "$large_modified_records")"
  large_combined_records="$(workload_records_concat "$large_combined_records" "$large_pass_records")"
  workload_manifest_append_incremental "$pass" "$large_pass_records" "$large_modified_records" "2026-01-01T00:00:0${pass}Z"
  large_manifest_state="$(workload_manifest_current_records "$large_manifest" "$pass")"
  workload_manifest_verify_inventory "$large_manifest_state" "$large_combined_records" "Large pass $pass manifest"
done
workload_manifest_validate "$large_manifest" true
[[ "$(jq -r '.combined.total_file_count' "$large_manifest")" == 2500 ]]
[[ "$(workload_records_digest "$large_combined_records")" == "$(jq -r '.combined.manifest_sha256' "$large_manifest")" ]]
printf 'PASS: multi-pass lifecycle and 1,000/500x3 workload manifests scale beyond jq argv limits.\n'
