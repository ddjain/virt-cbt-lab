#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN="$TEST_TMP/bin"
TEST_ROOT="$TEST_TMP/repo"
mkdir -p "$FAKE_BIN" "$TEST_ROOT/scripts"

cp "$ROOT_DIR/scripts/run-id.sh" "$TEST_ROOT/scripts/"
cp "$ROOT_DIR/scripts/e2e-stage.sh" "$TEST_ROOT/scripts/"

# Fake oc: `get vm <name> -o json` returns a pool VM with windows profile
# annotations and the density-pool labels.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "get vm" && "${*: -2:1}" == "-o" ]]; then
  name="$3"
  cat <<VMJSON
{"metadata":{"name":"$name","labels":{"app.kubernetes.io/managed-by":"virt-cbt-lab","virt-cbt-lab/run-id":"${name#vm-}","virt-cbt-lab/pool":"p1"},
 "annotations":{"virt-cbt-lab/os-profile":"windows","virt-cbt-lab/manifest-variant":"default","virt-cbt-lab/incremental-passes":"4"}},
 "status":{"ready":true}}
VMJSON
  exit 0
fi
printf 'unexpected oc invocation: %s\n' "$*" >&2
exit 1
FAKE_OC
chmod +x "$FAKE_BIN/oc"

# Fake make: prints each invocation's target and variable args to the log.
FAKE_MAKE="$TEST_TMP/fake-make"
cat > "$FAKE_MAKE" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MAKE_LOG"
FAKE_MAKE
chmod +x "$FAKE_MAKE"

run_stage() {
  (cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" ROOT_DIR="$TEST_ROOT" \
    RUNS_ROOT_DIR="$TEST_ROOT/runs" MAKE_COMMAND="$FAKE_MAKE" \
    MAKE_LOG="$MAKE_LOG" "$@" \
    bash "$TEST_ROOT/scripts/e2e-stage.sh" > "$STAGE_LOG" 2>&1)
}

# 1. TYPE=all adoption: pool annotations override the environment.
MAKE_LOG="$TEST_TMP/make-adopt.log"
STAGE_LOG="$TEST_TMP/stage-adopt.log"
: > "$MAKE_LOG"
if ! run_stage env TYPE=all EXISTING_VM=vm-p1-0001 \
  VM_OS=rhel9 GUEST_INCREMENTAL_PASSES=1 MANIFEST_VARIANT=large-odf; then
  printf 'TYPE=all EXISTING_VM adoption failed.\n%s\n' "$(cat "$STAGE_LOG")" >&2
  exit 1
fi
adopt_calls="$(cat "$MAKE_LOG")"
if [[ "$adopt_calls" != *'vm-cbt-demo RUN_ID=p1-0001'* ]]; then
  printf 'Adoption did not run vm-cbt-demo with RUN_ID=p1-0001.\n%s\n' "$adopt_calls" >&2
  exit 1
fi
for expected in 'VM_OS=windows' 'MANIFEST_VARIANT=default' 'GUEST_INCREMENTAL_PASSES=4' 'EXISTING_VM=vm-p1-0001'; do
  if [[ "$adopt_calls" != *"$expected"* ]]; then
    printf 'Adoption did not propagate %s (pool annotations must win).\n%s\n' "$expected" "$adopt_calls" >&2
    exit 1
  fi
done
if [[ -e "$TEST_ROOT/runs/p1-0001" ]]; then
  printf 'e2e-stage must not create runs/ directories itself.\n' >&2
  exit 1
fi

# 2. TYPE=incremental + EXISTING_VM must exit 2.
MAKE_LOG="$TEST_TMP/make-inc.log"
STAGE_LOG="$TEST_TMP/stage-inc.log"
: > "$MAKE_LOG"
stage_status=0
run_stage env TYPE=incremental EXISTING_VM=vm-p1-0002 || stage_status=$?
if ((stage_status != 2)); then
  printf 'TYPE=incremental with EXISTING_VM must exit 2 (got %s).\n' "$stage_status" >&2
  exit 1
fi

# 3. EXISTING_VM + VM must exit 2.
MAKE_LOG="$TEST_TMP/make-vm.log"
STAGE_LOG="$TEST_TMP/stage-vm.log"
: > "$MAKE_LOG"
stage_status=0
run_stage env TYPE=all EXISTING_VM=vm-p1-0001 VM=vm-other || stage_status=$?
if ((stage_status != 2)); then
  printf 'EXISTING_VM with VM must exit 2 (got %s).\n' "$stage_status" >&2
  exit 1
fi

# 4. VM missing the pool label must exit 2.
cat > "$FAKE_BIN/oc" <<'FAKE_OC2'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "get vm" && "${*: -2:1}" == "-o" ]]; then
  name="$3"
  cat <<VMJSON
{"metadata":{"name":"$name","labels":{"app.kubernetes.io/managed-by":"virt-cbt-lab","virt-cbt-lab/run-id":"${name#vm-}"}},
 "status":{"ready":true}}
VMJSON
  exit 0
fi
printf 'unexpected oc invocation: %s\n' "$*" >&2
exit 1
FAKE_OC2
chmod +x "$FAKE_BIN/oc"
MAKE_LOG="$TEST_TMP/make-nolabel.log"
STAGE_LOG="$TEST_TMP/stage-nolabel.log"
: > "$MAKE_LOG"
stage_status=0
run_stage env TYPE=all EXISTING_VM=vm-p1-0003 || stage_status=$?
if ((stage_status != 2)); then
  printf 'VM without the pool label must exit 2 (got %s).\n' "$stage_status" >&2
  exit 1
fi
if ! grep -q 'not a density-pool VM' "$STAGE_LOG"; then
  printf 'Missing-label failure must explain the density-pool requirement.\n%s\n' "$(cat "$STAGE_LOG")" >&2
  exit 1
fi

# 5. Pre-existing runs/<run-id> must exit 2.
mkdir -p "$TEST_ROOT/runs/p1-0001"
MAKE_LOG="$TEST_TMP/make-exists.log"
STAGE_LOG="$TEST_TMP/stage-exists.log"
: > "$MAKE_LOG"
stage_status=0
run_stage env TYPE=all EXISTING_VM=vm-p1-0001 || stage_status=$?
if ((stage_status != 2)); then
  printf 'Existing runs directory must exit 2 (got %s).\n' "$stage_status" >&2
  exit 1
fi
if ! grep -q 'already has artifacts' "$STAGE_LOG"; then
  printf 'Existing-artifacts failure must be explained.\n%s\n' "$(cat "$STAGE_LOG")" >&2
  exit 1
fi

printf 'PASS: EXISTING_VM adoption resolves pool annotations, propagates them to Make targets, and rejects invalid combinations.\n'
