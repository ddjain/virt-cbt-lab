#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
TEST_ROOT="$TEST_TMP/repo"
RUN_ID=restore-failure-test
VM="vm-$RUN_ID"
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/runs/$RUN_ID/fragments" \
  "$TEST_ROOT/runs/$RUN_ID/logs" "$TEST_ROOT/runs/$RUN_ID/evidence"
cp "$ROOT_DIR/scripts/common.sh" "$TEST_ROOT/scripts/common.sh"
cp "$ROOT_DIR/scripts/run-id.sh" "$TEST_ROOT/scripts/run-id.sh"
cp "$ROOT_DIR/scripts/vm-cbt-verify.sh" "$TEST_ROOT/scripts/vm-cbt-verify.sh"

cat > "$TEST_ROOT/scripts/vm-cbt-restore-test.sh" <<'RESTORE_TEST'
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME=mock-restore-test
load_run_id
write_report_fragment restore-test \
  '{"verification":{"checks":[{"name":"pass_03_restore_manifest_match","passed":false,"expected":"sha256-expected","actual":"sha256-observed"}]}}'
exit 1
RESTORE_TEST
chmod +x "$TEST_ROOT/scripts/vm-cbt-restore-test.sh"

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'get vmbackuptracker')
    printf 'checkpoint-03\n'
    ;;
  'get vmbackup')
    case "$*" in
      *'.status.type}'*)
        if [[ "${3:-}" == vm-backup-* ]]; then printf 'Full\n'; else printf 'Incremental\n'; fi
        ;;
      *'.status.checkpointName}'*)
        if [[ "${3:-}" == vm-backup-* ]]; then
          printf 'checkpoint-full\n'
        else
          printf 'checkpoint-%s\n' "${3##*-p}"
        fi
        ;;
      *'.status.conditions'*'.status}'*) printf 'True\n' ;;
      *'.status.conditions'*'.reason}'*) printf 'Successfully completed VirtualMachineBackup\n' ;;
      *) printf 'Unexpected vmbackup query: %s\n' "$*" >&2; exit 2 ;;
    esac
    ;;
  'get vm')
    case "$*" in
      *'.status.changedBlockTracking.state}'*) printf 'Enabled\n' ;;
      *' -o json'*) printf '{"metadata":{"uid":"restore-failure-test-uid"}}\n' ;;
      *) printf 'Unexpected VM query: %s\n' "$*" >&2; exit 2 ;;
    esac
    ;;
  'get pod')
    printf ''
    ;;
  *)
    printf 'Unexpected fake oc command: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE_OC
chmod +x "$TEST_TMP/bin/oc"

jq -n --arg run_id "$RUN_ID" --arg vm "$VM" '
  {schema_version: 1, run_id: $run_id, vm_name: $vm, namespace: "vm-cbt-demo",
   vm_uid: "restore-failure-test-uid", os_profile: "rhel9", manifest_variant: "large-odf",
   status: "verification_pending", incremental_passes_total: 3,
   incremental_passes_completed: 3, next_incremental_pass: null,
   guest: {baseline: {file_count: 1}, incremental_file_count_per_pass: 1,
           size_range_mib: {min_inclusive: 1, max_inclusive: 1}},
   backups: {
     full: {name: ("vm-backup-" + $run_id), type: "Full", checkpoint_name: "checkpoint-full"},
     incrementals: [range(1; 4) as $pass |
       {pass: $pass, name: ("vm-incremental-" + $run_id + "-p0" + ($pass | tostring)),
        type: "Incremental", checkpoint_name: ("checkpoint-0" + ($pass | tostring))}]}}
' > "$TEST_ROOT/runs/$RUN_ID/run.json"

if PATH="$TEST_TMP/bin:$PATH" KUBECONFIG_PATH= KUBECONFIG= RUN_ID="$RUN_ID" VM="$VM" \
   bash "$TEST_ROOT/scripts/vm-cbt-verify.sh" >"$TEST_TMP/verify.stdout" 2>"$TEST_TMP/verify.stderr"; then
  printf 'A failed cumulative restore unexpectedly passed vm-cbt-verify.\n' >&2
  exit 1
fi
if [[ ! -r "$TEST_ROOT/runs/$RUN_ID/report.json" ]]; then
  cat "$TEST_TMP/verify.stdout" "$TEST_TMP/verify.stderr" >&2
  printf 'Verifier exited before writing its report.\n' >&2
  exit 1
fi
jq -e '
  .verification.overall_passed == false and
  any(.verification.checks[];
      .name == "pass_03_restore_manifest_match" and .passed == false and
      .expected == "sha256-expected" and .actual == "sha256-observed")
' "$TEST_ROOT/runs/$RUN_ID/report.json" >/dev/null
jq -e '.status == "verification_failed"' "$TEST_ROOT/runs/$RUN_ID/run.json" >/dev/null
printf 'PASS: a failed cumulative restore check makes the merged report fail and marks the lifecycle failed.\n'
