#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
TEST_ROOT="$TEST_TMP/repo"
RUN_ID=full-failure-test
VM="vm-$RUN_ID"
RUN_DIR="$TEST_ROOT/runs/$RUN_ID"
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/manifests" "$RUN_DIR/logs" \
  "$RUN_DIR/fragments" "$RUN_DIR/evidence" "$TEST_TMP/bin"
cp "$ROOT_DIR/scripts/common.sh" "$ROOT_DIR/scripts/run-id.sh" \
  "$ROOT_DIR/scripts/workload-manifest.sh" "$ROOT_DIR/scripts/vm-backup.sh" \
  "$TEST_ROOT/scripts/"
cp "$ROOT_DIR/manifests/full-backup.yaml" "$TEST_ROOT/manifests/"
jq -n --arg run_id "$RUN_ID" --arg vm "$VM" '
  {schema_version:1, run_id:$run_id, vm_name:$vm, vm_uid:"full-failure-test-uid",
   namespace:"vm-cbt-demo", os_profile:"debian", manifest_variant:"default",
   status:"baseline_ready", incremental_passes_total:1, incremental_passes_completed:0,
   guest:{baseline:{file_count:1}, incremental_file_count_per_pass:1,
          size_range_mib:{min_inclusive:4,max_inclusive:12}},
   backups:{full:null,incrementals:[]}}
' > "$RUN_DIR/run.json"
printf '%s\n' '{"baseline":{"file_count":1,"total_payload_bytes":1024}}' \
  > "$RUN_DIR/workload-manifest.json"

cat > "$TEST_TMP/bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$OC_LOG"
if [[ "${1:-}" == apply ]]; then
  cat >/dev/null
  exit 0
fi
if [[ "${1:-}" == wait ]]; then exit 0; fi
[[ "${1:-}" == get ]] || { printf 'Unexpected fake oc command: %s\n' "$*" >&2; exit 90; }
kind="${2:-}"
name="${3:-}"
args="$*"
case "$kind:$name" in
  vm:vm-full-failure-test)
    printf '%s\n' '{"metadata":{"uid":"full-failure-test-uid"},"status":{"changedBlockTracking":{"backupStatus":{"backupName":"vm-backup-full-failure-test","failed":true,"checkpointName":"failed-checkpoint"}}}}'
    ;;
  vmbackup:vm-backup-full-failure-test)
    case "$args" in
      *'.status.type'*) printf 'Full\n' ;;
      *'.status.checkpointName'*) printf 'failed-checkpoint\n' ;;
      *'.status.conditions[?(@.type=="Done")].status'*) printf 'True\n' ;;
      *'.status.conditions[?(@.type=="Done")].reason'*) printf 'Backup has failed: VMI backup status was lost\n' ;;
      *) printf 'Unexpected backup query: %s\n' "$*" >&2; exit 91 ;;
    esac
    ;;
  pvc:vm-backup-pvc-full-failure-test)
    case "$args" in
      *'.spec.resources.requests.storage'*) printf '5Gi\n' ;;
      *'.status.capacity.storage'*) printf '5Gi\n' ;;
      *'.status.phase'*) printf 'Bound\n' ;;
      *) printf 'Unexpected PVC query: %s\n' "$*" >&2; exit 92 ;;
    esac
    ;;
  vmbackuptracker:vm-tracker-full-failure-test)
    printf '\n'
    ;;
  *)
    printf 'Unexpected fake oc query: %s\n' "$*" >&2
    exit 93
    ;;
esac
FAKE_OC
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" OC_LOG="$TEST_TMP/oc.log"
if (cd "$TEST_ROOT" && RUN_ID="$RUN_ID" VM="$VM" KUBECONFIG_PATH= KUBECONFIG= \
    bash scripts/vm-backup.sh) > "$TEST_TMP/backup.log" 2>&1; then
  printf 'A terminally failed full backup unexpectedly succeeded.\n' >&2
  exit 1
else
  backup_status=$?
fi
[[ "$backup_status" == 1 ]]
jq -e '
  .status == "full_failed" and
  .backups.full == null and
  .backups.full_failure.name == "vm-backup-full-failure-test" and
  .backups.full_failure.type == "Full" and
  .backups.full_failure.done_status == "True" and
  .backups.full_failure.done_reason == "Backup has failed: VMI backup status was lost" and
  .backups.full_failure.checkpoint_name == "failed-checkpoint" and
  .backups.full_failure.pvc_name == "vm-backup-pvc-full-failure-test" and
  .backups.full_failure.pvc_phase == "Bound" and
  .backups.full_failure.tracker_checkpoint_at_failure == ""
' "$RUN_DIR/run.json" >/dev/null
jq -e '
  .backups.full.checkpoint_name == "failed-checkpoint" and
  .backups.full.tracker_checkpoint == "" and
  .backups.full.pvc_phase == "Bound" and
  .evidence.vm_backup_status.full == "evidence/vm-backup-full-failure-test-vm-backup-status.json"
' "$RUN_DIR/fragments/full-backup.json" >/dev/null
[[ -f "$RUN_DIR/evidence/vm-backup-full-failure-test-vm-backup-status.json" ]]

printf 'PASS: terminal full-backup failure is retained separately with failed checkpoint, PVC state, and tracker checkpoint.\n'
