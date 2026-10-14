#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
unset KUBECONFIG KUBECONFIG_PATH || true
FAKE_BIN="$TEST_TMP/bin"
TEST_ROOT="$TEST_TMP/repo"
mkdir -p "$FAKE_BIN" "$TEST_ROOT/scripts"

cp "$ROOT_DIR/scripts/common.sh" "$ROOT_DIR/scripts/run-id.sh" \
  "$ROOT_DIR/scripts/density-lib.sh" "$ROOT_DIR/scripts/density-status.sh" \
  "$TEST_ROOT/scripts/"

# Fake oc. Cluster state: pool "dpool" with VM1 ready, VM2 not ready, VM3
# absent (partial creation); pool "dother" with one ready VM; one managed
# VM without a pool label (created by make e2e directly); VMs of other
# namespaces/owners ignored. vmbackup list as in the old fixture.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
ns=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-n" ]]; then ns="$arg"; fi
  prev="$arg"
done
if [[ "$ns" != "vm-cbt-demo" ]]; then
  printf '{"items":[]}\n'
  exit 0
fi
if [[ "$1 $2 $3" == "get vm -n" ]]; then
  if [[ "$*" == *"virt-cbt-lab/pool=dpool"* ]]; then
    cat <<'VMJSON'
{"items":[
 {"metadata":{"name":"vm-dpool-0001","labels":{"virt-cbt-lab/run-id":"dpool-0001","virt-cbt-lab/pool":"dpool"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-dpool-0002","labels":{"virt-cbt-lab/run-id":"dpool-0002","virt-cbt-lab/pool":"dpool"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{}}
]}
VMJSON
    exit 0
  fi
  if [[ "$*" == *"app.kubernetes.io/managed-by=virt-cbt-lab"* ]]; then
    # Selector without pool: everything managed (for the namespace overview).
    cat <<'VMALL'
{"items":[
 {"metadata":{"name":"vm-dpool-0001","labels":{"virt-cbt-lab/run-id":"dpool-0001","virt-cbt-lab/pool":"dpool"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-dpool-0002","labels":{"virt-cbt-lab/run-id":"dpool-0002","virt-cbt-lab/pool":"dpool"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{}},
 {"metadata":{"name":"vm-dother-0001","labels":{"virt-cbt-lab/run-id":"dother-0001","virt-cbt-lab/pool":"dother"},
   "annotations":{"virt-cbt-lab/os-profile":"windows","virt-cbt-lab/incremental-passes":"1"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-e2e-run-1","labels":{"virt-cbt-lab/run-id":"e2e-run-1"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9"}},
  "status":{"ready":true}}
]}
VMALL
    exit 0
  fi
fi
if [[ "$1 $2 $3" == "get vmbackup -n" ]]; then
  if [[ "$*" == *"app.kubernetes.io/managed-by=virt-cbt-lab"* ]]; then
    cat <<'BACKUPJSON'
{"items":[
 {"metadata":{"name":"vm-backup-dpool-0001"},
  "status":{"conditions":[{"type":"Done","status":"True","reason":"Completed VirtualMachineBackup"}]}},
 {"metadata":{"name":"vm-incremental-dpool-0001-p01"},
  "status":{"conditions":[{"type":"Done","status":"True","reason":"Completed VirtualMachineBackup, warning: Failed freezing guest filesystem"}]}},
 {"metadata":{"name":"vm-incremental-dpool-0001-p02"},
  "status":{"conditions":[{"type":"Done","status":"False","reason":"Backup is progressing"}]}},
 {"metadata":{"name":"vm-incremental-dpool-0002-p01"},
  "status":{"conditions":[{"type":"Done","status":"True","reason":"Backup has failed: VMI backup status was lost"}]}}
]}
BACKUPJSON
    exit 0
  fi
fi
printf 'unexpected oc invocation: %s\n' "$*" >&2
exit 1
FAKE_OC
chmod +x "$FAKE_BIN/oc"

# Pool funnel (POOL=dpool): VMs present on the cluster drive the funnel;
# TOTAL is the live count (2, not 3 — no local expected list).
status_output="$(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  POOL=dpool NAMESPACE=vm-cbt-demo bash "$TEST_ROOT/scripts/density-status.sh")"

expected_header='TOTAL=2 CREATING=1 CREATED=1 FULL=1 INC1=1 INC2=0'
if ! grep -qF "$expected_header" <<<"$status_output"; then
  printf 'Header mismatch.\nExpected: %s\nGot:\n%s\n' "$expected_header" "$status_output" >&2
  exit 1
fi
expected_row_1='dpool-0001                 ready     done     done     running'
if ! grep -qF "$expected_row_1" <<<"$status_output"; then
  printf 'Row 1 mismatch (run_id/state/full/inc columns).\nGot:\n%s\n' "$status_output" >&2
  exit 1
fi
if ! grep -qF 'dpool-0002                 creating  -        failed' <<<"$status_output"; then
  printf 'Row 2 mismatch (creating, no full, failed inc1).\nGot:\n%s\n' "$status_output" >&2
  exit 1
fi
# No missing rows: only existing VMs are listed.
if grep -qF 'dpool-0003' <<<"$status_output"; then
  printf 'Absent VM dpool-0003 must not appear (no local expected list).\nGot:\n%s\n' "$status_output" >&2
  exit 1
fi

# Unknown pool must fail (no VMs on the cluster).
unknown_status=0
(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  POOL=nosuchpool bash "$TEST_ROOT/scripts/density-status.sh" >/dev/null 2>&1) || unknown_status=$?
if ((unknown_status == 0)); then
  printf 'Unknown pool must exit non-zero.\n' >&2
  exit 1
fi

# Namespace overview (no POOL): one line per pool + un-pooled managed VMs.
overview_output="$(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  NAMESPACE=vm-cbt-demo bash "$TEST_ROOT/scripts/density-status.sh")"
grep -qF 'dpool                           2        1' <<<"$overview_output" || {
  printf 'Overview missing dpool row.\nGot:\n%s\n' "$overview_output" >&2
  exit 1
}
grep -qF 'dother                          1        1' <<<"$overview_output" || {
  printf 'Overview missing dother row.\nGot:\n%s\n' "$overview_output" >&2
  exit 1
}
grep -qF '(none)                          1        1' <<<"$overview_output" || {
  printf 'Overview missing (none) row for un-pooled managed VMs.\nGot:\n%s\n' "$overview_output" >&2
  exit 1
}

# Empty namespace must fail with a clear message.
empty_status=0
(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  NAMESPACE=empty-ns bash "$TEST_ROOT/scripts/density-status.sh" >/dev/null 2>&1) || empty_status=$?
if ((empty_status == 0)); then
  printf 'Empty namespace must exit non-zero.\n' >&2
  exit 1
fi

printf 'PASS: density-status renders pool funnels from live cluster state and a namespace-wide overview.\n'
