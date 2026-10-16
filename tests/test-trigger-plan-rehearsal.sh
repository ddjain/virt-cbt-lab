#!/usr/bin/env bash
set -euo pipefail

# Every scenario trigger a run may be launched from must support the rehearsal
# mode the run protocol requires (plan §12): `--plan` resolves the run identity,
# the target and the exact stage commands, contacts no cluster, mutates nothing,
# creates nothing, and exits 0 — while still refusing a run id that has already
# produced output. The pre-armed run directory (observer armed first, Lead
# scaffolding present) must be accepted, otherwise the mandated rehearsal is
# unsatisfiable for any run that follows the protocol order.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_TMP" "${created_dirs[@]:-}"
}
created_dirs=()
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

check_trigger() { # <scenario-id> <fresh-run-id>
  local scenario="$1" run_id="$2"
  local trigger="$ROOT_DIR/cbt-chaos/scenarios_v2/$scenario/chaos-trigger.sh"
  local run_dir="$ROOT_DIR/cbt-chaos/scenarios_v2/$scenario/runs/$run_id"
  local lifecycle_dir="$ROOT_DIR/runs/$run_id"
  [[ -x "$trigger" || -f "$trigger" ]] || fail "$scenario: trigger not found at $trigger"
  grep -q -- '--plan' "$trigger" || fail "$scenario: trigger does not implement --plan"

  # (1) pre-armed run directory: accepted, and --plan creates nothing.
  mkdir -p "$run_dir"/{contracts,observer,trigger,recovery,checkers,reports}
  printf '{"phase":"resolved"}\n' > "$run_dir/state.json"
  printf '{"marker":"ARMED"}\n' > "$run_dir/observer/ARMED"
  created_dirs+=("$run_dir")
  local before after
  before="$(cd "$ROOT_DIR" && find "cbt-chaos/scenarios_v2/$scenario/runs" "$ROOT_DIR/runs" -maxdepth 1 2>/dev/null | sort)"
  if ! RUN_ID="$run_id" KUBECONFIG_PATH=/nonexistent/kubeconfig \
       bash "$trigger" --plan > "$TEST_TMP/$scenario.plan" 2>&1; then
    fail "$scenario: --plan refused a pre-armed run directory (see $TEST_TMP/$scenario.plan)"
  fi
  after="$(cd "$ROOT_DIR" && find "cbt-chaos/scenarios_v2/$scenario/runs" "$ROOT_DIR/runs" -maxdepth 1 2>/dev/null | sort)"
  [[ "$before" == "$after" ]] || fail "$scenario: --plan created or removed a directory"
  [[ ! -e "$lifecycle_dir" ]] || fail "$scenario: --plan created the lifecycle run directory"
  grep -q "RUN_ID:.*$run_id" "$TEST_TMP/$scenario.plan" || fail "$scenario: --plan did not name the run id"
  grep -q 'local precondition check: clear' "$TEST_TMP/$scenario.plan" ||
    fail "$scenario: --plan did not report a clear precondition for a pre-armed directory"
  grep -q 'make e2e' "$TEST_TMP/$scenario.plan" || fail "$scenario: --plan did not print the planned stage command"

  # (2) real run output in the run directory: refused.
  printf '{}\n' > "$run_dir/driver-timings.json"
  if RUN_ID="$run_id" KUBECONFIG_PATH=/nonexistent/kubeconfig \
       bash "$trigger" --plan > "$TEST_TMP/$scenario.collision" 2>&1; then
    fail "$scenario: --plan accepted a run directory that already holds run output"
  fi
  grep -q 'refusing to reuse it' "$TEST_TMP/$scenario.collision" ||
    fail "$scenario: the refusal did not explain itself"

  # (3) a run directory without the pre-armed observer: refused.
  rm -f "$run_dir/driver-timings.json"
  rm -rf "$run_dir/observer"
  if RUN_ID="$run_id" KUBECONFIG_PATH=/nonexistent/kubeconfig \
       bash "$trigger" --plan > "$TEST_TMP/$scenario.noobserver" 2>&1; then
    fail "$scenario: --plan accepted a run directory with no armed observer"
  fi
}

check_trigger CBT-F-01 "plan-rehearsal-$$-f01"
check_trigger CBT-I-01 "plan-rehearsal-$$-i01"

printf 'PASS: trigger --plan rehearsals accept the pre-armed run directory, create nothing, and refuse run output or a missing observer.\n'
