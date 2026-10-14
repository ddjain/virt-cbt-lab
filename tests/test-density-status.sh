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

# Fake oc. Cluster state: pool "rhel-1" with VM1 ready (backups done) and
# VM2 not ready (failed inc1); pool "win-1" with one ready VM; one managed
# un-pooled VM (make e2e). VMs of other namespaces ignored.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
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
  if [[ "$*" == *"virt-cbt-lab/pool=rhel-1"* ]]; then
    cat <<'VMJSON'
{"items":[
 {"metadata":{"name":"vm-rhel-1-0001","labels":{"virt-cbt-lab/run-id":"rhel-1-0001","virt-cbt-lab/pool":"rhel-1"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-rhel-1-0002","labels":{"virt-cbt-lab/run-id":"rhel-1-0002","virt-cbt-lab/pool":"rhel-1"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{}}
]}
VMJSON
    exit 0
  fi
  if [[ "$*" == *"virt-cbt-lab/pool=win-1"* ]]; then
    cat <<'VMWIN'
{"items":[
 {"metadata":{"name":"vm-win-1-0001","labels":{"virt-cbt-lab/run-id":"win-1-0001","virt-cbt-lab/pool":"win-1"},
   "annotations":{"virt-cbt-lab/os-profile":"windows","virt-cbt-lab/incremental-passes":"1"}},
  "status":{"ready":true}}
]}
VMWIN
    exit 0
  fi
  if [[ "$*" == *"app.kubernetes.io/managed-by=virt-cbt-lab"* ]]; then
    # Fleet query (no pool selector): everything managed.
    cat <<'VMALL'
{"items":[
 {"metadata":{"name":"vm-rhel-1-0001","labels":{"virt-cbt-lab/run-id":"rhel-1-0001","virt-cbt-lab/pool":"rhel-1"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-rhel-1-0002","labels":{"virt-cbt-lab/run-id":"rhel-1-0002","virt-cbt-lab/pool":"rhel-1"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9","virt-cbt-lab/incremental-passes":"2"}},
  "status":{}},
 {"metadata":{"name":"vm-win-1-0001","labels":{"virt-cbt-lab/run-id":"win-1-0001","virt-cbt-lab/pool":"win-1"},
   "annotations":{"virt-cbt-lab/os-profile":"windows","virt-cbt-lab/incremental-passes":"1"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-e2e-run-1","labels":{"virt-cbt-lab/run-id":"e2e-run-1"},
   "annotations":{"virt-cbt-lab/os-profile":"rhel9"}},
  "status":{"ready":true}}
]}
VMALL
    exit 0
  fi
  printf '{"items":[]}\n'
  exit 0
fi
if [[ "$1 $2 $3" == "get vmbackup -n" ]]; then
  if [[ "$*" == *"app.kubernetes.io/managed-by=virt-cbt-lab"* ]]; then
    cat <<'BACKUPJSON'
{"items":[
 {"metadata":{"name":"vm-backup-rhel-1-0001"},
  "status":{"conditions":[{"type":"Done","status":"True","reason":"Completed VirtualMachineBackup"}]}},
 {"metadata":{"name":"vm-incremental-rhel-1-0001-p01"},
  "status":{"conditions":[{"type":"Done","status":"True","reason":"Completed VirtualMachineBackup, warning: Failed freezing guest filesystem"}]}},
 {"metadata":{"name":"vm-incremental-rhel-1-0001-p02"},
  "status":{"conditions":[{"type":"Done","status":"False","reason":"Backup is progressing"}]}},
 {"metadata":{"name":"vm-incremental-rhel-1-0002-p01"},
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

# Fleet view (default, no POOL): every managed VM in one output, grouped
# by pool; un-pooled e2e VMs in their own group.
fleet_output="$(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  NAMESPACE=vm-cbt-demo bash "$TEST_ROOT/scripts/density-status.sh")"
grep -qF 'Namespace: vm-cbt-demo  (4 managed VMs total)' <<<"$fleet_output" || {
  printf 'Fleet header mismatch.\nGot:\n%s\n' "$fleet_output" >&2
  exit 1
}
expected_rhel='TOTAL=2 CREATING=1 CREATED=1 FULL=1 INC1=1 INC2=0'
grep -qF "$expected_rhel" <<<"$fleet_output" || {
  printf 'rhel-1 funnel missing.\nExpected: %s\nGot:\n%s\n' "$expected_rhel" "$fleet_output" >&2
  exit 1
}
grep -qF 'Pool: win-1  OS: windows' <<<"$fleet_output" || {
  printf 'win-1 funnel missing.\nGot:\n%s\n' "$fleet_output" >&2
  exit 1
}
grep -qF 'Pool: no pool (make e2e)' <<<"$fleet_output" || {
  printf 'Un-pooled group missing.\nGot:\n%s\n' "$fleet_output" >&2
  exit 1
}
expected_row_1='rhel-1-0001                        ready     done     done     running'
grep -qF "$expected_row_1" <<<"$fleet_output" || {
  printf 'Row 1 mismatch (run_id/state/full/inc columns).\nGot:\n%s\n' "$fleet_output" >&2
  exit 1
}
if grep -qF 'rhel-1-0003' <<<"$fleet_output"; then
  printf 'Absent VM must not appear.\nGot:\n%s\n' "$fleet_output" >&2
  exit 1
fi

# Single-pool restriction (POOL=win-1): only that pool's funnel.
pool_output="$(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  POOL=win-1 NAMESPACE=vm-cbt-demo bash "$TEST_ROOT/scripts/density-status.sh")"
grep -qF 'Pool: win-1' <<<"$pool_output" || {
  printf 'POOL=win-1 output missing its funnel.\nGot:\n%s\n' "$pool_output" >&2
  exit 1
}
if grep -qF 'rhel-1-0001' <<<"$pool_output"; then
  printf 'POOL=win-1 must not include other pools.\nGot:\n%s\n' "$pool_output" >&2
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

# Empty namespace: informative message, exit 0.
empty_status=0
empty_output="$(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  NAMESPACE=empty-ns bash "$TEST_ROOT/scripts/density-status.sh" 2>&1)" || empty_status=$?
if ((empty_status != 0)); then
  printf 'Empty namespace must exit 0.\nGot: %s\n' "$empty_output" >&2
  exit 1
fi
grep -qF 'No virt-cbt-lab managed VMs in namespace empty-ns' <<<"$empty_output" || {
  printf 'Empty-namespace message mismatch.\nGot: %s\n' "$empty_output" >&2
  exit 1
}

printf 'PASS: density-status default fleet view groups all managed VMs by pool; POOL= restricts to one pool.\n'
