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
VM_INFO_DIR="$ROOT_DIR/report/vms/$RUN_ID"
cleanup() {
  rm -rf "$TEST_TMP" "$VM_INFO_DIR"
}
trap cleanup EXIT INT TERM
unset KUBECONFIG KUBECONFIG_PATH || true
mkdir -p "$TEST_TMP/bin" "$VM_INFO_DIR"

jq -n --arg run_id "$RUN_ID" --arg vm_name "$VM_NAME" \
  '{schema_version:1, run_id:$run_id, vm_name:$vm_name,
    namespace:"vm-cbt-demo", report_id:"run_monitor_test",
    status:"baseline_ready", incremental_passes_total:2,
    incremental_passes_completed:0, next_incremental_pass:1,
    backups:{full:null, incrementals:[]}}' > "$VM_INFO_DIR/vm-info.json"

cat > "$TEST_TMP/bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != get || "${2:-}" != vmbackup ]]; then
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
printf 'PASS: monitor watches the full backup and all planned passes before vm-info records them.\n'
