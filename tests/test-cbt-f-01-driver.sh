#!/usr/bin/env bash
set -euo pipefail

# Offline behaviour test for the CBT-F-01 scenario driver. Exercises the
# coordination contract only: leg order, tolerated trigger failure, timing
# artifacts, verdict plumbing, and the argument/collision guards. No cluster,
# no make, no kubeconfig: the trigger, `make`, and the verdict evaluator are
# stubbed in a throwaway root.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

SCEN_DIR="$WORK/cbt-chaos/scenarios_v2/CBT-F-01"
mkdir -p "$SCEN_DIR" "$WORK/cbt-chaos" "$WORK/bin"
cp "$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-01/run-cbt-f-01.sh" "$SCEN_DIR/run-cbt-f-01.sh"

cat >"$SCEN_DIR/stub-trigger.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'stub-trigger run_id=%s\n' "${RUN_ID:-unset}"
exit 1  # the interrupted full backup is expected to fail
SH

cat >"$WORK/cbt-chaos/scenario-verdict.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
json=""
while (($#)); do
  case "$1" in
    --json) json="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"schema_version":1,"verdict":"PASS","checks":[]}\n' >"$json"
printf 'stub-verdict PASS\n'
SH

cat >"$WORK/bin/make" <<'SH'
#!/usr/bin/env bash
printf 'stub-make %s\n' "$*"
if [[ "${FAIL_RECOVER:-}" == "1" && "$*" == *TYPE=recover* ]]; then
  exit 1
fi
exit 0
SH
chmod +x "$WORK/bin/make" "$SCEN_DIR/stub-trigger.sh" "$WORK/cbt-chaos/scenario-verdict.sh"

export PATH="$WORK/bin:$PATH"

# 1. Missing RUN_ID is a usage error.
if RUN_ID= KUBECONFIG_PATH=/dev/null bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out1" 2>&1; then
  fail "driver accepted an empty RUN_ID"
fi
grep -q 'Set RUN_ID' "$WORK/out1" || fail "empty RUN_ID did not produce an actionable message"

# 2. CLEAN_RUN_ID equal to RUN_ID is a usage error.
if RUN_ID=test-run-1 CLEAN_RUN_ID=test-run-1 KUBECONFIG_PATH=/dev/null \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out2" 2>&1; then
  fail "driver accepted identical RUN_ID and CLEAN_RUN_ID"
fi
grep -q 'must differ' "$WORK/out2" || fail "identical ids did not produce an actionable message"

# 3. A colliding lifecycle directory is refused before any leg runs.
mkdir -p "$WORK/runs/test-run-1"
if RUN_ID=test-run-1 KUBECONFIG_PATH=/dev/null TRIGGER_SCRIPT="$SCEN_DIR/stub-trigger.sh" \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out3" 2>&1; then
  fail "driver accepted a colliding RUN_ID"
fi
grep -q 'already exist' "$WORK/out3" || fail "collision did not produce an actionable message"
rmdir "$WORK/runs/test-run-1"

# 4. Happy path: four legs in order, trigger failure tolerated, timings recorded.
RUN_ID=test-run-2 KUBECONFIG_PATH=/dev/null TRIGGER_SCRIPT="$SCEN_DIR/stub-trigger.sh" \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out4" 2>&1 || fail "driver returned non-zero for a PASS verdict"

RUN_DIR="$SCEN_DIR/runs/test-run-2"
[[ -f "$RUN_DIR/driver-timings.json" ]] || fail "driver-timings.json was not written"
[[ -f "$RUN_DIR/verdict.json" ]] || fail "verdict.json was not written"
[[ -f "$RUN_DIR/trigger/.keep" || -d "$RUN_DIR/trigger" ]] || fail "trigger directory was not prepared"
[[ -f "$RUN_DIR/observer/.keep" || -d "$RUN_DIR/observer" ]] || fail "observer directory was not prepared"

jq -e '.schema_version == 1 and (.legs | length == 4)' "$RUN_DIR/driver-timings.json" >/dev/null ||
  fail "timings json does not describe four legs"
jq -r '[.legs[].leg] | join(",")' "$RUN_DIR/driver-timings.json" |
  grep -qx 'interrupted_full,same_vm_recovery,clean_lifecycle,verdict' ||
  fail "legs were not recorded in the contractual order"
jq -r '.legs[0].status' "$RUN_DIR/driver-timings.json" | grep -qx '1' ||
  fail "a failing trigger leg was not recorded as status 1"
jq -r '.legs[1].status' "$RUN_DIR/driver-timings.json" | grep -qx '0' ||
  fail "the recovery leg status was not recorded"
jq -r '.legs[] | select(.leg=="same_vm_recovery") | .seconds | type' "$RUN_DIR/driver-timings.json" |
  grep -qx 'number' || fail "leg durations are not numbers"

grep -q 'stub-trigger run_id=test-run-2' "$RUN_DIR/driver.log" ||
  fail "the trigger leg was not executed with the resolved run id"
grep -q 'stub-make e2e TYPE=recover VM=vm-test-run-2' "$RUN_DIR/driver.log" ||
  fail "the same-VM recovery leg did not use the expected make invocation"
grep -q 'stub-make e2e TYPE=all NAME=test-run-2-clean' "$RUN_DIR/driver.log" ||
  fail "the clean lifecycle leg did not use the expected make invocation and clean id"
grep -q 'verdict: PASS' "$WORK/out4" || fail "the driver did not report the verdict it read"

# 4b. A pre-armed observer directory is expected and must not be refused, while
#     prior trigger evidence for the same run id must be.
mkdir -p "$SCEN_DIR/runs/test-run-4/observer/watches"
printf 'armed\n' >"$SCEN_DIR/runs/test-run-4/observer/watches/pods.ready"
RUN_ID=test-run-4 KUBECONFIG_PATH=/dev/null TRIGGER_SCRIPT="$SCEN_DIR/stub-trigger.sh" \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out4b" 2>&1 ||
  fail "the driver refused a pre-armed observer directory"
[[ -f "$SCEN_DIR/runs/test-run-4/observer/watches/pods.ready" ]] ||
  fail "the driver removed the observer's armed marker"
mkdir -p "$SCEN_DIR/runs/test-run-5/trigger"
printf '{}\n' >"$SCEN_DIR/runs/test-run-5/trigger/action-request.json"
if RUN_ID=test-run-5 KUBECONFIG_PATH=/dev/null TRIGGER_SCRIPT="$SCEN_DIR/stub-trigger.sh" \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out4c" 2>&1; then
  fail "the driver accepted a run id with existing trigger evidence"
fi
grep -q 'Trigger evidence already exists' "$WORK/out4c" ||
  fail "existing trigger evidence did not produce an actionable message"

# 5. A verdict that is not PASS must make the driver exit non-zero.
cat >"$WORK/cbt-chaos/scenario-verdict.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
json=""
while (($#)); do
  case "$1" in
    --json) json="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"schema_version":1,"verdict":"INCONCLUSIVE","checks":[]}\n' >"$json"
exit 1
SH
chmod +x "$WORK/cbt-chaos/scenario-verdict.sh"
if RUN_ID=test-run-3 KUBECONFIG_PATH=/dev/null TRIGGER_SCRIPT="$SCEN_DIR/stub-trigger.sh" \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out5" 2>&1; then
  fail "driver returned zero for a non-PASS verdict"
fi
grep -q 'verdict: INCONCLUSIVE' "$WORK/out5" || fail "the driver did not report the non-PASS verdict"

# 6. A failing middle leg must not abort the driver: every leg is attempted and
#    the deterministic verdict is still produced and decides the exit status.
RUN_ID=test-run-6 KUBECONFIG_PATH=/dev/null TRIGGER_SCRIPT="$SCEN_DIR/stub-trigger.sh" FAIL_RECOVER=1 \
  bash "$SCEN_DIR/run-cbt-f-01.sh" >"$WORK/out6" 2>&1 && fail "a non-PASS verdict must exit non-zero"
jq -r '[.legs[].leg] | join(",")' "$SCEN_DIR/runs/test-run-6/driver-timings.json" |
  grep -qx 'interrupted_full,same_vm_recovery,clean_lifecycle,verdict' ||
  fail "a failing leg must not stop the remaining legs or the verdict"
jq -r '.legs[] | select(.leg == "same_vm_recovery") | .status' "$SCEN_DIR/runs/test-run-6/driver-timings.json" |
  grep -qx '1' || fail "the failing recovery leg status was not recorded"
jq -r '.legs[] | select(.leg == "clean_lifecycle") | .status' "$SCEN_DIR/runs/test-run-6/driver-timings.json" |
  grep -qx '0' || fail "the clean lifecycle leg did not run after the recovery leg failed"

printf 'PASS: CBT-F-01 driver runs its legs in order, tolerates the expected trigger failure, records timings, and propagates the deterministic verdict.\n'
