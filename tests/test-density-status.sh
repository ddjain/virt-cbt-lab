#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
unset KUBECONFIG KUBECONFIG_PATH || true
FAKE_BIN="$TEST_TMP/bin"
TEST_ROOT="$TEST_TMP/repo"
mkdir -p "$FAKE_BIN" "$TEST_ROOT/scripts" "$TEST_ROOT/density/dpool"

cp "$ROOT_DIR/scripts/common.sh" "$ROOT_DIR/scripts/run-id.sh" \
  "$ROOT_DIR/scripts/density-lib.sh" "$ROOT_DIR/scripts/density-status.sh" \
  "$TEST_ROOT/scripts/"

# Fixture pool: 3 run IDs, 2 incremental passes.
jq -n '{schema_version: 1, pool_id: "dpool", os_profile: "rhel9",
  manifest_variant: "large-odf", namespace: "vm-cbt-demo",
  vm_count: 3, incremental_passes: 2,
  run_ids: ["dpool-0001", "dpool-0002", "dpool-0003"],
  created_at: "2026-10-14T00:00:00Z"}' > "$TEST_ROOT/density/dpool/pool.json"

# Fake oc:
# - `get vm -l virt-cbt-lab/pool=dpool` returns VM1 ready, VM2 not ready,
#   VM3 absent.
# - `get vmbackup -l app.kubernetes.io/managed-by=virt-cbt-lab` returns
#   full done (VM1), inc1 done with a benign warning reason (VM1),
#   inc2 running (Done not True, VM1), and a failed incremental for VM2.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2 $3" == "get vm -n" ]]; then
  if [[ "$*" == *"virt-cbt-lab/pool=dpool"* ]]; then
    cat <<'VMJSON'
{"items":[
 {"metadata":{"name":"vm-dpool-0001","labels":{"virt-cbt-lab/run-id":"dpool-0001","virt-cbt-lab/pool":"dpool"}},
  "status":{"ready":true}},
 {"metadata":{"name":"vm-dpool-0002","labels":{"virt-cbt-lab/run-id":"dpool-0002","virt-cbt-lab/pool":"dpool"}},
  "status":{}}
]}
VMJSON
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

status_output="$(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  POOL=dpool NAMESPACE=vm-cbt-demo bash "$TEST_ROOT/scripts/density-status.sh")"

expected_header='TOTAL=3 CREATING=2 CREATED=1 FULL=1 INC1=1 INC2=0'
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
if ! grep -qF 'dpool-0003                 missing' <<<"$status_output"; then
  printf 'Row 3 mismatch (missing VM).\nGot:\n%s\n' "$status_output" >&2
  exit 1
fi

# Unknown pool must fail with the file path.
unknown_status=0
(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  POOL=nosuchpool bash "$TEST_ROOT/scripts/density-status.sh" >/dev/null 2>&1) || unknown_status=$?
if ((unknown_status == 0)); then
  printf 'Unknown pool must exit non-zero.\n' >&2
  exit 1
fi

printf 'PASS: density-status renders the pool funnel with ready/creating/missing states and done/running/failed/- backups.\n'
