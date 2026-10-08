#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN="$TEST_TMP/bin"
TEST_REPO_DIR="$TEST_TMP/repo"
mkdir -p "$FAKE_BIN" "$TEST_REPO_DIR/scripts"
cp "$SOURCE_ROOT_DIR/scripts/common.sh" "$TEST_REPO_DIR/scripts/common.sh"
cp "$SOURCE_ROOT_DIR/scripts/workload-manifest.sh" "$TEST_REPO_DIR/scripts/workload-manifest.sh"
cp "$SOURCE_ROOT_DIR/scripts/run-id.sh" "$TEST_REPO_DIR/scripts/run-id.sh"
cp "$SOURCE_ROOT_DIR/scripts/vm-cbt-extend.sh" "$TEST_REPO_DIR/scripts/vm-cbt-extend.sh"

cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != get ]]; then
  printf 'Unexpected fake oc command: %s\n' "$*" >&2
  exit 90
fi
resource="${2:-}"
name="${3:-}"
output=""
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[index]}" == -o ]] && ((index + 1 < ${#args[@]})); then
    output="${args[index + 1]}"
  fi
done
if [[ "$*" == *--ignore-not-found* ]]; then
  exit 0
fi
case "$resource" in
  vm)
    [[ "$output" == json ]] || exit 91
    printf '{"metadata":{"uid":"%s"},"status":{"ready":%s,"changedBlockTracking":{"state":"Enabled"}}}\n' "${TEST_VM_UID:-test-vm-uid}" "${TEST_VM_READY:-true}"
    ;;
  vmbackup)
    if [[ "$name" == "${TEST_FULL_BACKUP_NAME:-}" ]]; then
      backup_type=Full
      checkpoint="$TEST_FULL_CHECKPOINT"
    elif [[ "$name" == "${TEST_INCREMENTAL_BACKUP_NAME:-}" ]]; then
      backup_type=Incremental
      checkpoint="$TEST_INCREMENTAL_CHECKPOINT"
    else
      printf 'Unexpected fake vmbackup query: %s\n' "$name" >&2
      exit 92
    fi
    if [[ "$output" == *'.status.type'* ]]; then
      printf '%s' "$backup_type"
    elif [[ "$output" == *'.status.checkpointName'* ]]; then
      printf '%s' "$checkpoint"
    elif [[ "$output" == *'.status.conditions'*'.reason}'* ]]; then
      printf 'Successfully completed VirtualMachineBackup'
    elif [[ "$output" == *'.status.conditions'*'.status}'* ]]; then
      printf 'True'
    else
      printf 'Unexpected fake vmbackup output selector: %s\n' "$output" >&2
      exit 93
    fi
    ;;
  vmbackuptracker)
    printf '%s' "$TEST_INCREMENTAL_CHECKPOINT"
    ;;
  pvc)
    exit 0
    ;;
  *)
    printf 'Unexpected fake oc resource: %s\n' "$resource" >&2
    exit 94
    ;;
esac
FAKE_OC
chmod +x "$FAKE_BIN/oc"
PATH="$FAKE_BIN:$PATH"
export PATH
unset KUBECONFIG KUBECONFIG_PATH || true

export VM_OS=debian
export NAMESPACE=vm-cbt-demo
export GUEST_BASE_FILE_COUNT=2
export GUEST_INCREMENTAL_FILE_COUNT=2
export GUEST_INCREMENTAL_PASSES=1
export GUEST_FILE_SIZE_MIN_MIB=1
export GUEST_FILE_SIZE_MAX_MIB=2
export MANIFEST_VARIANT=default

source "$TEST_REPO_DIR/scripts/common.sh"
source "$TEST_REPO_DIR/scripts/workload-manifest.sh"

RUN_ID=extension-state-transition-test
VM_NAME="vm-$RUN_ID"
RUNS_ROOT_DIR="$TEST_REPO_DIR/runs"
REPORT_DIR="$RUNS_ROOT_DIR/$RUN_ID"
set_resource_names
mkdir -p "$REPORT_DIR/fragments"

records_from_plan() {
  local phase="$1" count="$2" pass="${3:-}" plan name size_bytes sha256
  plan="$(workload_file_plan "$phase" "$count" "$pass")"
  while IFS='|' read -r name size_bytes; do
    [[ -n "$name" ]] || continue
    sha256="$(printf 'CBT-WORKLOAD-V1:%s\n' "$name" | workload_sha256_stdin)"
    printf 'FILE_RECORD=%s|%s|%s\n' "$name" "$size_bytes" "$sha256"
  done <<< "$plan"
}

baseline_records="$(workload_records_from_output "$(records_from_plan baseline "$GUEST_BASE_FILE_COUNT")")"
workload_manifest_initialize "$baseline_records"
pass_one_records="$(workload_records_from_output "$(records_from_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT" 1)")"
pass_one_modification_plan="$(workload_modified_file_plan 1)"
IFS='|' read -r pass_one_modified_name pass_one_modified_size <<< "$pass_one_modification_plan"
pass_one_modified_hash="$(workload_modified_file_sha256 "$pass_one_modified_name" 1 "$pass_one_modified_size")"
pass_one_modified_records="$(jq -cn \
  --arg path "$pass_one_modified_name" \
  --argjson size "$pass_one_modified_size" \
  --arg hash "$pass_one_modified_hash" \
  '[{path:$path,phase:"baseline",pass:0,size_bytes:$size,sha256:$hash}]')"
workload_manifest_append_incremental 1 "$pass_one_records" "$pass_one_modified_records" "2026-01-01T00:00:01Z"
vm_info_initialize "test-vm-uid"

TEST_FULL_BACKUP_NAME="$FULL_BACKUP_NAME"
TEST_INCREMENTAL_BACKUP_NAME="$(incremental_backup_name_for_pass 1)"
TEST_FULL_CHECKPOINT=full-checkpoint
TEST_INCREMENTAL_CHECKPOINT=pass-one-checkpoint
export TEST_FULL_BACKUP_NAME TEST_INCREMENTAL_BACKUP_NAME TEST_FULL_CHECKPOINT TEST_INCREMENTAL_CHECKPOINT

vm_info_update \
  '.status = "complete" |
   .incremental_passes_completed = 1 |
   .next_incremental_pass = null |
   .backups.full = {name: $full_name, type: "Full", checkpoint_name: $full_checkpoint, pvc_name: $full_pvc} |
   .backups.incrementals = [{pass: 1, name: $incremental_name, type: "Incremental",
                             checkpoint_name: $incremental_checkpoint, pvc_name: $incremental_pvc}]' \
  --arg full_name "$TEST_FULL_BACKUP_NAME" \
  --arg full_checkpoint "$TEST_FULL_CHECKPOINT" \
  --arg full_pvc "$FULL_BACKUP_PVC_NAME" \
  --arg incremental_name "$TEST_INCREMENTAL_BACKUP_NAME" \
  --arg incremental_checkpoint "$TEST_INCREMENTAL_CHECKPOINT" \
  --arg incremental_pvc "$(incremental_backup_pvc_name_for_pass 1)"
printf '{"verification":{"overall_passed":true}}\n' > "$REPORT_DIR/report.json"

VM_INFO_PATH="$(vm_info_path "$RUN_ID")"
manifest_path="$(workload_manifest_path)"
run_real_extension() {
  local log_path="$1"
  env \
    PATH="$FAKE_BIN:$PATH" \
    RUN_ID="$RUN_ID" VM="$VM_NAME" EXTEND_TO_PASS=2 \
    VM_OS=rhel9 NAMESPACE=wrong-namespace MANIFEST_VARIANT=large-odf \
    GUEST_BASE_FILE_COUNT=2 GUEST_INCREMENTAL_FILE_COUNT=2 GUEST_INCREMENTAL_PASSES=1 \
    GUEST_FILE_SIZE_MIN_MIB=1 GUEST_FILE_SIZE_MAX_MIB=2 \
    TEST_VM_UID="${TEST_VM_UID:-test-vm-uid}" \
    TEST_VM_READY="${TEST_VM_READY:-true}" \
    TEST_FULL_BACKUP_NAME="$TEST_FULL_BACKUP_NAME" \
    TEST_INCREMENTAL_BACKUP_NAME="$TEST_INCREMENTAL_BACKUP_NAME" \
    TEST_FULL_CHECKPOINT="$TEST_FULL_CHECKPOINT" \
    TEST_INCREMENTAL_CHECKPOINT="$TEST_INCREMENTAL_CHECKPOINT" \
    bash "$ROOT_DIR/scripts/vm-cbt-extend.sh" > "$log_path" 2>&1
}

TEST_VM_UID=wrong-vm-uid
state_before_uid_mismatch="$(jq -c . "$VM_INFO_PATH")"
if run_real_extension "$TEST_TMP/vm-identity-mismatch.log"; then
  printf 'Extension unexpectedly accepted a VM whose UID differs from run.json.\n' >&2
  exit 1
else
  identity_mismatch_status=$?
fi
[[ "$identity_mismatch_status" == 1 ]]
identity_mismatch_output="$(cat "$TEST_TMP/vm-identity-mismatch.log")"
if [[ "$identity_mismatch_output" != *'VM identity mismatch for run extension-state-transition-test'* ]]; then
  printf 'VM UID mismatch was not reported clearly.\n%s\n' "$identity_mismatch_output" >&2
  exit 1
fi
[[ "$(jq -c . "$VM_INFO_PATH")" == "$state_before_uid_mismatch" ]]
TEST_VM_UID=test-vm-uid

run_real_extension "$TEST_TMP/extension.log"
jq -e '
  .status == "incremental_ready" and
  .incremental_passes_total == 2 and
  .incremental_passes_completed == 1 and
  .next_incremental_pass == 2 and
  .extension_pending.from_total == 1 and
  .extension_pending.target_total == 2 and
  .extension_pending.status == "ready"
' "$VM_INFO_PATH" >/dev/null
jq -e '.incremental_passes_total == 2 and (.incrementals | length) == 1' "$manifest_path" >/dev/null
workload_manifest_validate "$manifest_path" false
jq -e '
  .extensions[0].from_total == 1 and
  .extensions[0].to_total == 2 and
  .extensions[0].pass == 2
' "$REPORT_DIR/fragments/extension-pass-02.json" >/dev/null

vm_info_update \
  '.status = "extension_pending" |
   .incremental_passes_total = 1 |
   .next_incremental_pass = null |
   .extension_pending.status = "preparing" |
   del(.extension_pending.manifest_updated_at)'
run_real_extension "$TEST_TMP/interrupted-finalize-retry.log"
jq -e '
  .status == "incremental_ready" and
  .incremental_passes_total == 2 and
  .incremental_passes_completed == 1 and
  .next_incremental_pass == 2 and
  .extension_pending.status == "ready"
' "$VM_INFO_PATH" >/dev/null

manifest_before_unready_retry="$(jq -c . "$manifest_path")"
TEST_VM_READY=false
if run_real_extension "$TEST_TMP/unready-retry.log"; then
  printf 'A pending extension unexpectedly proceeded while the VM was not Ready.\n' >&2
  exit 1
fi
unready_output="$(cat "$TEST_TMP/unready-retry.log")"
if [[ "$unready_output" != *'must be Ready with CBT Enabled (ready=false, CBT=Enabled)'* ]]; then
  printf 'Pending extension did not report the VM readiness failure clearly.\n%s\n' "$unready_output" >&2
  exit 1
fi
[[ "$(jq -c . "$manifest_path")" == "$manifest_before_unready_retry" ]]
jq -e '.status == "incremental_ready" and .incremental_passes_completed == 1 and .next_incremental_pass == 2' \
  "$VM_INFO_PATH" >/dev/null

TEST_VM_READY=true
run_real_extension "$TEST_TMP/resume.log"
jq -e '.status == "incremental_ready" and .incremental_passes_total == 2 and .next_incremental_pass == 2' \
  "$VM_INFO_PATH" >/dev/null
printf 'PASS: real extension script synchronizes manifest/lifecycle state and rejects an unready resume.\n'
