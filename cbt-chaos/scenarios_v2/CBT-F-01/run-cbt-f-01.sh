#!/usr/bin/env bash
set -euo pipefail

# Deterministic driver for the CBT-F-01 scenario (coordination only, no
# judgement). It runs the three legs the scenario contract requires, in order,
# records one timing line per leg, and finally invokes the deterministic verdict
# evaluator. See scenario-spec.md for the contract this implements and
# ../../../docs/agent-workflow-audit.md for the stage semantics it relies on.
#
# Usage:
#   RUN_ID=<fresh-id> KUBECONFIG_PATH=<host-local kubeconfig> \
#     bash run-cbt-f-01.sh [CLEAN_RUN_ID=<fresh-id>]
#
# Exit status: the verdict evaluator's status (0 only for a PASS verdict).
# It never runs `make clean-all` and never deletes scenario evidence.

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCENARIO_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

: "${RUN_ID:?Set RUN_ID to a fresh, unused chaos run id}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
export KUBECONFIG_PATH

CLEAN_RUN_ID="${CLEAN_RUN_ID:-${RUN_ID}-clean}"
export RUN_ID CLEAN_RUN_ID
VM_NAME="vm-${RUN_ID}"
CLEAN_VM="vm-${CLEAN_RUN_ID}"
SCENARIO_RUN_DIR="$SCENARIO_DIR/runs/$RUN_ID"
TIMINGS_FILE="$SCENARIO_RUN_DIR/driver-timings.json"
# Overridable so the driver can be exercised offline against a stub trigger.
TRIGGER_SCRIPT="${TRIGGER_SCRIPT:-$SCENARIO_DIR/chaos-trigger.sh}"

for command in jq make; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 2
  }
done

for id in "$RUN_ID" "$CLEAN_RUN_ID"; do
  [[ "$id" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
    printf 'Run id %s is not lowercase alphanumeric with . or -\n' "$id" >&2
    exit 2
  }
done

if [[ "$RUN_ID" == "$CLEAN_RUN_ID" ]]; then
  printf 'CLEAN_RUN_ID must differ from RUN_ID (%s)\n' "$RUN_ID" >&2
  exit 2
fi
for path in "$ROOT_DIR/runs/$RUN_ID" "$ROOT_DIR/runs/$CLEAN_RUN_ID"; do
  if [[ -e "$path" ]]; then
    printf 'Lifecycle artifacts already exist at %s; pick a fresh RUN_ID.\n' "$path" >&2
    exit 2
  fi
done
if [[ -e "$SCENARIO_RUN_DIR" ]]; then
  # The observer arms before the run and writes under runs/<RUN_ID>/observer/,
  # so a pre-created directory is expected. Only prior run output is refused.
  if [[ -d "$SCENARIO_RUN_DIR/trigger" ]] && [[ -n "$(ls -A "$SCENARIO_RUN_DIR/trigger" 2>/dev/null || true)" ]]; then
    printf 'Trigger evidence already exists under %s; pick a fresh RUN_ID.\n' "$SCENARIO_RUN_DIR" >&2
    exit 2
  fi
  for prior in driver-timings.json verdict.json driver.log; do
    if [[ -e "$SCENARIO_RUN_DIR/$prior" ]]; then
      printf 'Prior driver output %s exists; pick a fresh RUN_ID.\n' "$SCENARIO_RUN_DIR/$prior" >&2
      exit 2
    fi
  done
fi

mkdir -p "$SCENARIO_RUN_DIR/trigger" "$SCENARIO_RUN_DIR/observer"
printf '[%s] [driver] [action] Scenario run directory %s created\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO_RUN_DIR"
printf 'manifest: none; run_id=%s clean_run_id=%s vm=%s clean_vm=%s\n' \
  "$RUN_ID" "$CLEAN_RUN_ID" "$VM_NAME" "$CLEAN_VM" >"$SCENARIO_RUN_DIR/driver-inputs.txt"

legs_json='[]'
record_leg() { # <name> <status> <seconds>
  legs_json="$(jq -cn --argjson legs "$legs_json" --arg name "$1" --arg status "$2" \
    --argjson seconds "$3" '$legs + [{leg: $name, status: $status, seconds: $seconds}]')"
  jq -cn --argjson legs "$legs_json" --arg run_id "$RUN_ID" \
    '{schema_version: 1, run_id: $run_id, legs: $legs}' \
    >"$TIMINGS_FILE.tmp" && mv "$TIMINGS_FILE.tmp" "$TIMINGS_FILE"
  printf '[%s] [driver] [status] leg=%s status=%s elapsed_seconds=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3"
}

run_leg() { # <name> <expected-exit> <command...>
  local name="$1" expected="$2" status=0 start end
  shift 2
  start=$SECONDS
  printf '[%s] [driver] [action] leg=%s command=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*"
  set +e
  "$@" >>"$SCENARIO_RUN_DIR/driver.log" 2>&1
  status=$?
  set -e
  end=$SECONDS
  record_leg "$name" "$status" "$((end - start))"
  if [[ "$expected" == "any" ]]; then
    return 0
  fi
  if [[ "$status" != "$expected" ]]; then
    printf 'leg %s exited %s, expected %s; see %s\n' \
      "$name" "$status" "$expected" "$SCENARIO_RUN_DIR/driver.log" >&2
    return 1
  fi
}

# 1. Interrupted leg: the trigger launches `make e2e TYPE=full` and deletes the
#    launcher pod on the active-copy signal. It exits non-zero by design (the
#    interrupted full backup must fail). Its own exit arbitration stays the
#    injection contract; the verdict comes from the evaluator below.
printf '[%s] [driver] [step] 1/4 Interrupted full backup with launcher disruption\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_leg interrupted_full any bash "$TRIGGER_SCRIPT"

# 2. Same-VM recovery: the deterministic script asserts the failed-full state
#    and runs a new full backup plus baseline restore on the same VM.
printf '[%s] [driver] [step] 2/4 Same-VM recovery verification\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Legs 2-4 record their own status but never abort the driver: the deterministic
# verdict must always be produced, including when a leg fails, so the evaluator
# classifies the run instead of the shell exiting on the first error.
run_leg same_vm_recovery any make e2e TYPE=recover VM="$VM_NAME"

# 3. Independent clean lifecycle: required by criterion 6 for the restore claim.
printf '[%s] [driver] [step] 3/4 Clean full plus incremental lifecycle\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_leg clean_lifecycle any make e2e TYPE=all NAME="$CLEAN_RUN_ID"

# 4. Deterministic verdict from the recorded artifacts.
printf '[%s] [driver] [step] 4/4 Deterministic verdict\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERDICT_JSON="$SCENARIO_RUN_DIR/verdict.json"
run_leg verdict any bash "$ROOT_DIR/cbt-chaos/scenario-verdict.sh" \
  --scenario-dir "$SCENARIO_DIR" \
  --run-id "$RUN_ID" \
  --lifecycle-run "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN_ID" \
  --json "$VERDICT_JSON"

printf '[%s] [driver] [status] Timings %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TIMINGS_FILE"
printf 'verdict: %s\n' "$(jq -r '.verdict // "UNKNOWN"' "$VERDICT_JSON" 2>/dev/null || printf 'UNKNOWN')"
exit "$(jq -r 'if .verdict == "PASS" then 0 else 1 end' "$VERDICT_JSON" 2>/dev/null || printf '1')"
