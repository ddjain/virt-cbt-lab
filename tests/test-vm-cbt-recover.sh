#!/usr/bin/env bash
set -euo pipefail
test_failure() {
  local status="$1" line="$2" command="$3"
  printf 'test-vm-cbt-recover.sh failed at line %s: %s\n' "$line" "$command" >&2
  exit "$status"
}
trap 'test_failure "$?" "$LINENO" "$BASH_COMMAND"' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
TEST_ROOT="$TEST_TMP/repo"
RUN_ID=recover-test
VM="vm-$RUN_ID"
RUN_DIR="$TEST_ROOT/runs/$RUN_ID"
mkdir -p "$TEST_ROOT/scripts" "$RUN_DIR/logs" "$RUN_DIR/fragments" "$RUN_DIR/evidence" "$TEST_TMP/bin"
cp "$ROOT_DIR/scripts/common.sh" "$ROOT_DIR/scripts/run-id.sh" \
  "$ROOT_DIR/scripts/vm-cbt-recover.sh" "$ROOT_DIR/scripts/write-run-summary.sh" \
  "$TEST_ROOT/scripts/"
cp "$ROOT_DIR/scripts/e2e-stage.sh" "$TEST_ROOT/scripts/"

jq -n --arg run_id "$RUN_ID" --arg vm "$VM" '
  {schema_version:1, run_id:$run_id, vm_name:$vm, vm_uid:"recover-test-uid",
   namespace:"vm-cbt-demo", os_profile:"rhel9", manifest_variant:"large-odf",
   status:"full_failed", incremental_passes_total:1, incremental_passes_completed:0,
   guest:{baseline:{file_count:1}, incremental_file_count_per_pass:1,
          size_range_mib:{min_inclusive:4,max_inclusive:12}},
   backups:{full:null,
     full_failure:{name:("vm-backup-" + $run_id),type:"Full",done_status:"True",
       done_reason:"Backup has failed: VMI backup status was lost",
       checkpoint_name:"failed-checkpoint",pvc_name:("vm-backup-pvc-" + $run_id),
       pvc_phase:"Bound",tracker_checkpoint_at_failure:"previous-good-checkpoint"},
     incrementals:[]}}
' > "$RUN_DIR/run.json"

cat > "$TEST_TMP/bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$OC_LOG"
[[ "${1:-}" == get ]] || { printf 'Unexpected mutating oc command: %s\n' "$*" >&2; exit 90; }
kind="${2:-}"
name="${3:-}"
case "$kind:$name" in
  vm:vm-recover-test)
    printf '{"metadata":{"name":"vm-recover-test","uid":"recover-test-uid"},"status":{"conditions":[{"type":"Ready","status":"%s"}],"changedBlockTracking":{"state":"Enabled"}}}\n' "${FAKE_VM_READY:-True}"
    ;;
  vmi:vm-recover-test)
    printf '{"status":{"phase":"%s"}}\n' "${FAKE_VMI_PHASE:-Running}"
    ;;
  vmbackup:vm-backup-recover-test)
    printf '%s\n' '{"metadata":{"name":"vm-backup-recover-test"},"spec":{"pvcName":"vm-backup-pvc-recover-test"},"status":{"type":"Full","checkpointName":"failed-checkpoint","includedVolumes":[{"diskTarget":"vda","volumeName":"rootdisk"}],"conditions":[{"type":"Done","status":"True","reason":"Backup has failed: VMI backup status was lost"}]}}'
    ;;
  pvc:vm-backup-pvc-recover-test)
    printf '%s\n' '{"metadata":{"name":"vm-backup-pvc-recover-test"},"status":{"phase":"Bound"}}'
    ;;
  vmbackuptracker:vm-tracker-recover-test)
    printf '%s\n' '{"metadata":{"name":"vm-tracker-recover-test"},"status":{"latestCheckpoint":{"name":"previous-good-checkpoint"}}}'
    ;;
  crd:virtualmachinebackups.backup.kubevirt.io)
    printf '%s\n' '{"spec":{"versions":[{"name":"v1alpha1","served":true,"schema":{"openAPIV3Schema":{"properties":{"spec":{"properties":{"source":{"properties":{"apiGroup":{"type":"string"},"kind":{"type":"string"},"name":{"type":"string"}}}}}}}}}]}}'
    ;;
  vmbackup:vm-recovery-full-*|pvc:vm-recovery-pvc-*)
    if [[ "${FAKE_RECOVERY_COLLISION:-}" == "$name" ]]; then
      printf '%s/%s\n' "$kind" "$name"
    else
      printf 'Error from server (NotFound): requested recovery candidate does not exist\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'Unexpected fake oc query: %s\n' "$*" >&2
    exit 91
    ;;
esac
FAKE_OC
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" OC_LOG="$TEST_TMP/oc.log"

run_recovery() {
  RUN_ID="$RUN_ID" VM="$VM" KUBECONFIG_PATH= KUBECONFIG= \
    bash "$TEST_ROOT/scripts/vm-cbt-recover.sh"
}

run_recovery > "$TEST_TMP/recovery-1.log" 2>&1
[[ "$(jq -r '.recovery.attempts | length' "$RUN_DIR/run.json")" == 1 ]]
jq -e '
  .vm_name == "vm-recover-test" and .vm_uid == "recover-test-uid" and
  .backups.full_failure.checkpoint_name == "failed-checkpoint" and
  .backups.full_failure.tracker_checkpoint_at_failure == "previous-good-checkpoint" and
  .recovery.status == "blocked" and
  .recovery.attempts[0].id == "r001" and
  .recovery.attempts[0].status == "blocked" and
  .recovery.attempts[0].resources_applied.pvc == false and
  .recovery.attempts[0].resources_applied.backup == false and
  .recovery.attempts[0].vm.ready == "True" and
  .recovery.attempts[0].vm.vmi_phase == "Running" and
  .recovery.attempts[0].vm.cbt_state == "Enabled" and
  .recovery.attempts[0].failed_full.checkpoint_name == "failed-checkpoint" and
  .recovery.attempts[0].tracker.checkpoint_before == "previous-good-checkpoint" and
  .recovery.attempts[0].proposed_resources.backup_name != .recovery.attempts[0].failed_full.name and
  .recovery.attempts[0].proposed_resources.pvc_name != .recovery.attempts[0].failed_full.pvc_name and
  .recovery.attempts[0].api_contract.status == "unavailable" and
  any(.recovery.attempts[0].blocked_reasons[]; contains("precondition failed: force_full_backup_schema_supported"))
' "$RUN_DIR/run.json" >/dev/null
jq -e '
  .backups.full_failure.checkpoint_name == "failed-checkpoint" and
  .recovery.attempts[0].resources_applied.pvc == false and
  .recovery.attempts[0].tracker.checkpoint_before == "previous-good-checkpoint"
' "$RUN_DIR/report.json" >/dev/null
if grep -E '(^| )(apply|create|delete|patch)( |$)' "$OC_LOG" >/dev/null; then
  printf 'Recovery gate issued a mutating oc command.\n' >&2
  exit 1
fi
FAKE_VM_READY=False run_recovery > "$TEST_TMP/recovery-not-ready.log" 2>&1
jq -e '
  .recovery.attempts[1].vm.ready == "False" and
  any(.recovery.attempts[1].preconditions[]; .name == "vm_ready" and .passed == false) and
  any(.recovery.attempts[1].blocked_reasons[]; contains("precondition failed: vm_ready")) and
  .recovery.attempts[1].resources_applied.pvc == false
' "$RUN_DIR/run.json" >/dev/null
FAKE_RECOVERY_COLLISION=vm-recovery-full-recover-test-r003 run_recovery \
  > "$TEST_TMP/recovery-collision.log" 2>&1
jq -e '
  .recovery.attempts[2].id == "r003" and
  .recovery.attempts[2].status == "blocked" and
  .recovery.attempts[2].proposed_resources.backup_name_state == "present" and
  any(.recovery.attempts[2].blocked_reasons[]; contains("precondition failed: recovery_backup_name_available")) and
  .recovery.attempts[2].resources_applied.pvc == false and
  .backups.full_failure.checkpoint_name == "failed-checkpoint"
' "$RUN_DIR/run.json" >/dev/null


summary_path="$(bash "$TEST_ROOT/scripts/write-run-summary.sh" "$RUN_ID" recover BLOCKED)"
jq -e '.verdict == "BLOCKED" and .last_invocation.result == "BLOCKED" and
       .backups.full_failure.checkpoint_name == "failed-checkpoint" and
       .recovery_attempts[0].tracker_checkpoint_before == "previous-good-checkpoint"' \
  "$TEST_ROOT/$summary_path" >/dev/null

cat > "$TEST_TMP/fake-make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  case "$1" in
    --*) shift ;;
    *) target="$1"; shift; break ;;
  esac
done
printf '%s\n' "$target" >> "$MAKE_LOG"
case "$target" in
  preflight) exit 0 ;;
  vm-cbt-recover) exec bash "$TEST_ROOT/scripts/vm-cbt-recover.sh" ;;
  *) printf 'Unexpected fake make target: %s\n' "$target" >&2; exit 92 ;;
esac
FAKE_MAKE
chmod +x "$TEST_TMP/fake-make"
: > "$TEST_TMP/make.log"
if (cd "$TEST_ROOT" && env ROOT_DIR="$TEST_ROOT" RUNS_ROOT_DIR="$TEST_ROOT/runs" \
    TEST_ROOT="$TEST_ROOT" MAKE_COMMAND="$TEST_TMP/fake-make" MAKE_LOG="$TEST_TMP/make.log" \
    OC_LOG="$OC_LOG" PATH="$PATH" TYPE=recover VM="$VM" KUBECONFIG_PATH= KUBECONFIG= \
    bash scripts/e2e-stage.sh) > "$TEST_TMP/stage.log" 2>&1; then
  printf 'The recovery stage unexpectedly returned success instead of BLOCKED.\n' >&2
  exit 1
else
  stage_status=$?
fi
if [[ "$stage_status" != 3 ]]; then
  printf 'Expected BLOCKED exit 3; got %s.\n' "$stage_status" >&2
  cat "$TEST_TMP/stage.log" >&2
  exit 1
fi
[[ "$(cat "$TEST_TMP/make.log")" == $'preflight\nvm-cbt-recover' ]]
[[ ! -e "$TEST_ROOT/state/e2e.lock" ]]
[[ "$(jq -r '.recovery.attempts | length' "$RUN_DIR/run.json")" == 4 ]]
[[ "$(jq -r '.recovery.attempts[3].id' "$RUN_DIR/run.json")" == r004 ]]
[[ "$(jq -r '.verdict' "$TEST_ROOT/runs/$RUN_ID/summary.json")" == BLOCKED ]]
if [[ "$(<"$TEST_TMP/stage.log")" != *'BLOCKED: recovery preconditions failed; no backup or PVC was created'* ||
      "$(<"$TEST_TMP/stage.log")" != *'Result: ▣ BLOCKED'* ]]; then
  printf 'The staged command omitted its explicit BLOCKED result.\n' >&2
  cat "$TEST_TMP/stage.log" >&2
  exit 1
fi

printf 'PASS: recovery preserves failed state, records distinct attempts, applies no cluster resources, and returns a staged BLOCKED verdict.\n'
