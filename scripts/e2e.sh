#!/usr/bin/env bash
set -uo pipefail
# Orchestrates N concurrent, isolated CBT E2E pipelines. Each run gets its
# own RUN_ID (propagated as an env var to vm-setup/vm-backup/vm-cbt-backup/
# vm-cbt-verify, which derive every Kubernetes resource name and local
# state/report path from it — see scripts/common.sh), so runs never share
# cluster resources, state files, or report directories. Preflight already
# ran once via the `make e2e` target before this script starts.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

N="${N:-1}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
  printf '[e2e] N must be a positive integer (got: %s).\n' "$N" >&2
  exit 1
fi

# NAME gives every run a deterministic, caller-chosen base instead of the
# random tag below, e.g. for a repeatable local/CI test run. It must be
# DNS-1123-safe since it flows straight into Kubernetes resource names.
NAME="${NAME:-}"
if [[ -n "$NAME" ]] && ! [[ "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  printf '[e2e] NAME must be lowercase alphanumeric with internal hyphens (got: %s).\n' "$NAME" >&2
  exit 1
fi

state_root_dir="$ROOT_DIR/state"
mkdir -p "$state_root_dir"
# Shared per-invocation tag keeps run IDs short (cbt-<i>-<tag>) while staying
# collision-safe across separate `make e2e` invocations. Only used when NAME
# is not given.
run_base_tag="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"

run_ids=()
log_files=()
pids=()

stop_runs() {
  printf '\n[e2e] Interrupted; stopping in-flight runs (any partial cluster resources are left for `make clean-all`).\n' >&2
  for pid in "${pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  exit 130
}
trap stop_runs INT TERM

for ((i = 1; i <= N; i++)); do
  if [[ -n "$NAME" ]]; then
    if (( N == 1 )); then
      run_id="$NAME"
    else
      run_id="${NAME}-${i}"
    fi
  else
    run_id="cbt-${i}-${run_base_tag}"
  fi
  log_file="$state_root_dir/${run_id}.e2e.log"
  run_ids+=("$run_id")
  log_files+=("$log_file")
  printf '[e2e] Run %d/%d (%s): START (log: %s)\n' "$i" "$N" "$run_id" "$log_file" >&2
  (
    export RUN_ID="$run_id"
    "$ROOT_DIR/scripts/vm-setup.sh" &&
      "$ROOT_DIR/scripts/vm-backup.sh" &&
      "$ROOT_DIR/scripts/vm-cbt-backup.sh" &&
      "$ROOT_DIR/scripts/vm-cbt-verify.sh"
  ) >"$log_file" 2>&1 &
  pids+=("$!")
done

overall_status=0
pass_count=0
fail_count=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    pass_count=$((pass_count + 1))
    printf '[e2e] Run %d/%d (%s): PASS\n' "$((i + 1))" "$N" "${run_ids[$i]}" >&2
  else
    fail_count=$((fail_count + 1))
    overall_status=1
    printf '[e2e] Run %d/%d (%s): FAIL (see %s)\n' "$((i + 1))" "$N" "${run_ids[$i]}" "${log_files[$i]}" >&2
  fi
done

printf '\n[e2e] Summary:\n  PASS: %d\n  FAIL: %d\n' "$pass_count" "$fail_count" >&2
exit "$overall_status"
