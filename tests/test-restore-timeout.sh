#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  delete)
    exit 0
    ;;
  apply)
    cat >/dev/null
    ;;
  get)
    if [[ "${2:-}" != pod ]]; then
      printf 'Unexpected fake oc get command: %s\n' "$*" >&2
      exit 2
    fi
    printf 'Running'
    ;;
  logs)
    printf 'mock restore pod log\n'
    ;;
  *)
    printf 'Unexpected fake oc command: %s\n' "$*" >&2
    exit 2
    ;;
esac
FAKE_OC
chmod +x "$FAKE_BIN/oc"
PATH="$FAKE_BIN:$PATH"
export PATH
unset KUBECONFIG KUBECONFIG_PATH || true

VM_OS=debian
NAMESPACE=vm-cbt-demo
MANIFEST_VARIANT=default
RUN_ID=restore-timeout-test
source "$ROOT_DIR/scripts/common.sh"
RUNS_ROOT_DIR="$TEST_TMP/runs"
set_resource_names
mkdir -p "$REPORT_DIR"
RESTORE_HELPER_IMAGE=quay.io/example/restore-helper:test
source "$ROOT_DIR/scripts/restore-lib.sh"
RESTORE_VERIFY_TIMEOUT_SECONDS=2

if run_restore_verify_pod full-backup-pvc pass-01-pvc \
    >"$TEST_TMP/restore.stdout" 2>"$TEST_TMP/restore.stderr"; then
  printf 'A restore pod that remained Running unexpectedly passed timeout handling.\n' >&2
  exit 1
fi
if [[ "$RESTORE_POD_PHASE" != Running ]]; then
  printf 'Expected the timed-out restore phase to be Running; got %s.\n' "$RESTORE_POD_PHASE" >&2
  exit 1
fi
restore_error="$(cat "$TEST_TMP/restore.stderr")"
if [[ "$restore_error" != *'did not reach Succeeded within 2 seconds (current phase: Running)'* ]]; then
  printf 'Restore timeout message omitted the current phase or configured duration.\n%s\n' \
    "$restore_error" >&2
  exit 1
fi
[[ "$(cat "$REPORT_DIR/logs/restore-verify-pod.log")" == 'mock restore pod log' ]]
printf 'PASS: restore timeout retains the actual pod phase and diagnostic log.\n'
