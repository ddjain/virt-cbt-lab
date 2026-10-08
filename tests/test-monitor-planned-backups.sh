#!/usr/bin/env bash
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  printf 'SKIP: monitor planned-backup test requires Bash 4 or newer.\n'
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
RUN_ID="monitor-pending-test-$$"
VM_NAME="vm-$RUN_ID"
RUN_DIR="$ROOT_DIR/runs/$RUN_ID"
REPORT_DIR="$RUN_DIR"
cleanup() {
  rm -rf "$TEST_TMP" "$RUN_DIR"
}
trap cleanup EXIT INT TERM
unset KUBECONFIG KUBECONFIG_PATH || true
mkdir -p "$TEST_TMP/bin" "$RUN_DIR/fragments"

jq -n --arg run_id "$RUN_ID" --arg vm_name "$VM_NAME" \
  '{schema_version:1, run_id:$run_id, vm_name:$vm_name, vm_uid:("uid-" + $run_id),
    namespace:"vm-cbt-demo", os_profile:"debian", manifest_variant:"default",
    status:"baseline_ready", incremental_passes_total:2,
    incremental_passes_completed:0, next_incremental_pass:1,
    guest:{baseline:{file_count:2}, incremental_file_count_per_pass:1,
           size_range_mib:{min_inclusive:1, max_inclusive:1}},
    backups:{full:null, incrementals:[]}}' > "$RUN_DIR/run.json"
jq -n --arg run_id "$RUN_ID" \
  '{run_id:$run_id, verification:{overall_passed:true}}' > "$RUN_DIR/report.json"

cat > "$TEST_TMP/bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != get ]]; then
  printf 'Unexpected fake oc command: %s\n' "$*" >&2
  exit 2
fi
if [[ "${2:-}" == vm ]]; then
  vm_name="${3:?VM name required}"
  printf '{"metadata":{"uid":"uid-%s"}}\n' "${vm_name#vm-}"
  exit 0
fi
if [[ "${2:-}" != vmbackup ]]; then
  printf 'Unexpected fake oc command: %s\n' "$*" >&2
  exit 2
fi
backup_name="${3:?backup name required}"
if [[ "$backup_name" == vm-backup-* ]]; then type=Full; else type=Incremental; fi
printf '{"metadata":{"creationTimestamp":"2026-10-07T00:00:00Z"},"status":{"type":"%s","checkpointName":"%s-checkpoint","conditions":[{"type":"Done","status":"True","reason":"Successfully completed VirtualMachineBackup","lastTransitionTime":"2026-10-07T00:00:05Z"}]}}\n' \
  "$type" "$backup_name"
FAKE_OC
chmod +x "$TEST_TMP/bin/oc"

output="$(PATH="$TEST_TMP/bin:$PATH" "$ROOT_DIR/scripts/monitor.sh" "$VM_NAME" 2>&1)"
expected="Tracking 3 backup object(s): vm-backup-$RUN_ID vm-incremental-$RUN_ID-p01 vm-incremental-$RUN_ID-p02"
if [[ "$output" != *"$expected"* ]]; then
  printf 'Monitor did not include unrecorded planned backup names. Output:\n%s\n' "$output" >&2
  exit 1
fi
for backup_name in "vm-backup-$RUN_ID" "vm-incremental-$RUN_ID-p01" "vm-incremental-$RUN_ID-p02"; do
  if [[ "$output" != *"($backup_name) done in 5s"* ]]; then
    printf 'Monitor did not report completion for planned backup %s.\n' "$backup_name" >&2
    exit 1
  fi
done
jq -e --arg full_name "vm-backup-$RUN_ID" '
  .verification.overall_passed == true and
  .backup_timings.full.backup_name == $full_name and
  .backup_timings.full.created_at == "2026-10-07T00:00:00Z" and
  .backup_timings.full.done_at == "2026-10-07T00:00:05Z" and
  .backup_timings.full.duration_seconds == 5 and
  [.backup_timings.incrementals[].pass] == [1, 2] and
  all(.backup_timings.incrementals[]; .duration_seconds == 5)
' "$REPORT_DIR/report.json" >/dev/null
jq -e '
  .backup_timings.full.duration_seconds == 5 and
  (.backup_timings.incrementals | length) == 2
' "$RUN_DIR/run.json" >/dev/null
jq -e '
  .backup_timings.full.duration_seconds == 5 and
  (.backup_timings.incrementals | length) == 2
' "$REPORT_DIR/fragments/backup-timings.json" >/dev/null
printf 'PASS: monitor persists API start, completion, and duration data for every planned backup.\n'
