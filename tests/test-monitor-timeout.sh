#!/usr/bin/env bash
set -euo pipefail

# Bounded-wait contract for scripts/monitor.sh (plan §6 "No indefinite waits",
# §11 "Zero unbounded retries/planning loops"): a planned backup that never
# reaches Done=True must end the monitor with a distinguishable exit status and
# an actionable message instead of polling forever.

if ((BASH_VERSINFO[0] < 4)); then
  printf 'SKIP: monitor timeout test requires Bash 4 or newer.\n'
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
RUN_ID="monitor-timeout-test-$$"
VM_NAME="vm-$RUN_ID"
RUN_DIR="$ROOT_DIR/runs/$RUN_ID"
cleanup() {
  rm -rf "$TEST_TMP" "$RUN_DIR"
}
trap cleanup EXIT INT TERM
unset KUBECONFIG KUBECONFIG_PATH || true
mkdir -p "$TEST_TMP/bin" "$RUN_DIR/fragments"

jq -n --arg run_id "$RUN_ID" --arg vm_name "$VM_NAME" \
  '{schema_version:1, run_id:$run_id, vm_name:$vm_name, vm_uid:("uid-" + $run_id),
    namespace:"vm-cbt-demo", os_profile:"debian", manifest_variant:"default",
    status:"baseline_ready", incremental_passes_total:1,
    incremental_passes_completed:0, next_incremental_pass:1,
    guest:{baseline:{file_count:2}, incremental_file_count_per_pass:1,
           size_range_mib:{min_inclusive:1, max_inclusive:1}},
    backups:{full:null, incrementals:[]}}' > "$RUN_DIR/run.json"

# Every vmbackup stays pending: a started object with no Done condition.
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
printf '{"metadata":{"creationTimestamp":"2026-10-07T00:00:00Z"},"status":{"type":"%s","conditions":[{"type":"Progressing","status":"True","lastTransitionTime":"2026-10-07T00:00:01Z"}]}}\n' \
  "$type"
FAKE_OC
chmod +x "$TEST_TMP/bin/oc"

# 1. A pending backup ends the monitor at the deadline with exit 2.
started_at="$SECONDS"
set +e
output="$(PATH="$TEST_TMP/bin:$PATH" MONITOR_TIMEOUT_SECONDS=2 MONITOR_POLL_INTERVAL_SECONDS=1 \
  "$ROOT_DIR/scripts/monitor.sh" "$VM_NAME" 2>&1)"
status=$?
set -e
elapsed=$((SECONDS - started_at))
if ((status != 2)); then
  printf 'Monitor with MONITOR_TIMEOUT_SECONDS=2 exited %s, expected 2. Output:\n%s\n' "$status" "$output" >&2
  exit 1
fi
if ((elapsed > 15)); then
  printf 'Monitor waited %ss past a 2s deadline; the wait is not bounded.\n' "$elapsed" >&2
  exit 1
fi
if [[ "$output" != *"Monitor timed out after 2s with 2 backup(s) still without Done=True"* ]]; then
  printf 'Monitor timeout message is not actionable. Output:\n%s\n' "$output" >&2
  exit 1
fi
for backup_name in "vm-backup-$RUN_ID" "vm-incremental-$RUN_ID-p01"; do
  if [[ "$output" != *"$backup_name"* ]]; then
    printf 'Monitor timeout did not name the outstanding backup %s.\n' "$backup_name" >&2
    exit 1
  fi
done
if [[ "$output" != *"MONITOR_TIMEOUT_SECONDS=0"* ]]; then
  printf 'Monitor timeout did not document the opt-out. Output:\n%s\n' "$output" >&2
  exit 1
fi

# 2. A malformed bound is rejected before any polling.
set +e
output="$(PATH="$TEST_TMP/bin:$PATH" MONITOR_TIMEOUT_SECONDS=soon \
  "$ROOT_DIR/scripts/monitor.sh" "$VM_NAME" 2>&1)"
status=$?
set -e
if ((status != 1)) || [[ "$output" != *"Invalid MONITOR_TIMEOUT_SECONDS"* ]]; then
  printf 'Monitor accepted a malformed MONITOR_TIMEOUT_SECONDS (exit %s). Output:\n%s\n' "$status" "$output" >&2
  exit 1
fi

printf 'PASS: monitor bounds its wait, exits 2 with the outstanding backup names, and rejects a malformed bound.\n'
