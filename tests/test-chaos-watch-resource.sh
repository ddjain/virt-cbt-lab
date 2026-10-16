#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
watcher_pid=''
cleanup() {
  if [[ -n "$watcher_pid" ]]; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT
mkdir -p "$TEST_TMP/bin"
printf 'test kubeconfig\n' > "$TEST_TMP/kubeconfig"
cat > "$TEST_TMP/bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${KUBECONFIG:-}" && -r "$KUBECONFIG" ]] || { printf 'Missing configuration\n' >&2; exit 91; }
if [[ "${1:-}" == auth && "${2:-}" == can-i ]]; then
  [[ "${OC_BEHAVIOR:-}" != watch-forbidden ]] || { printf 'Watch forbidden\n' >&2; exit 1; }
  printf 'yes\n'
  exit 0
fi
[[ "${1:-}" == get ]] || { printf 'Unexpected mutation\n' >&2; exit 90; }
watch=false
for arg in "$@"; do [[ "$arg" == --watch ]] && watch=true; done
if [[ "$watch" == false ]]; then
  if [[ "${OC_BEHAVIOR:-}" == preflight-denied ]]; then
    printf 'Forbidden\n' >&2
    exit 1
  fi
  printf '{"items":[]}\n'
  exit 0
fi
if [[ "${OC_BEHAVIOR:-}" == watch-denied ]]; then
  printf 'Forbidden watch\n' >&2
  exit 1
fi
printf '{"type":"BOOKMARK","object":{"metadata":{"name":"scoped"}}}\n'
while [[ ! -e "${WATCH_STOP_FILE:?}" ]]; do sleep 0.05; done
exit 4
FAKE_OC
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" WATCH_STOP_FILE="$TEST_TMP/stop"
helper="$ROOT_DIR/cbt-chaos/watch-resource.sh"

if KUBECONFIG_PATH="$TEST_TMP/missing" bash "$helper" test-namespace pods label app=scoped \
  "$TEST_TMP/missing.jsonl" "$TEST_TMP/missing.ready" > "$TEST_TMP/missing.log" 2>&1; then
  printf 'Missing kubeconfig falsely armed the watch.\n' >&2
  exit 1
fi
[[ ! -e "$TEST_TMP/missing.ready" ]]
if KUBECONFIG_PATH="$TEST_TMP/kubeconfig" OC_BEHAVIOR=preflight-denied \
  bash "$helper" test-namespace pods label app=scoped \
  "$TEST_TMP/denied.jsonl" "$TEST_TMP/denied.ready" > "$TEST_TMP/denied.log" 2>&1; then
  printf 'Failed API preflight falsely armed the watch.\n' >&2
  exit 1
fi
[[ ! -e "$TEST_TMP/denied.ready" ]]
if KUBECONFIG_PATH="$TEST_TMP/kubeconfig" OC_BEHAVIOR=watch-forbidden \
  bash "$helper" test-namespace pods label app=scoped \
  "$TEST_TMP/forbidden.jsonl" "$TEST_TMP/forbidden.ready" > "$TEST_TMP/forbidden.log" 2>&1; then
  printf 'Missing watch authorization falsely armed the watch.\n' >&2
  exit 1
fi
[[ ! -e "$TEST_TMP/forbidden.ready" ]]
if KUBECONFIG_PATH="$TEST_TMP/kubeconfig" OC_BEHAVIOR=watch-denied \
  bash "$helper" test-namespace vmbackup name backup-scoped \
  "$TEST_TMP/watch-denied.jsonl" "$TEST_TMP/watch-denied.ready" > "$TEST_TMP/watch-denied.log" 2>&1; then
  printf 'Failed watch falsely remained armed.\n' >&2
  exit 1
fi
[[ ! -e "$TEST_TMP/watch-denied.ready" ]]

KUBECONFIG_PATH="$TEST_TMP/kubeconfig" OC_BEHAVIOR=live \
  bash "$helper" test-namespace vmbackup name backup-scoped \
  "$TEST_TMP/live.jsonl" "$TEST_TMP/live.ready" > "$TEST_TMP/live.log" 2>&1 &
watcher_pid=$!
armed=false
for ((attempt = 0; attempt < 50; attempt++)); do
  if [[ -s "$TEST_TMP/live.ready" ]]; then armed=true; break; fi
  if ! kill -0 "$watcher_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[[ "$armed" == true ]] || { printf 'Authenticated watch never armed.\n' >&2; exit 1; }
jq -e '.items == []' "$TEST_TMP/live.jsonl.baseline.json" >/dev/null
jq -e '.type == "BOOKMARK" and .object.metadata.name == "scoped"' "$TEST_TMP/live.jsonl" >/dev/null
: > "$WATCH_STOP_FILE"
if wait "$watcher_pid"; then
  printf 'Unexpected watch exit was accepted.\n' >&2
  exit 1
fi
watcher_pid=''
[[ ! -e "$TEST_TMP/live.ready" ]] || { printf 'Watch exit left a stale armed marker.\n' >&2; exit 1; }

KUBECONFIG_PATH="$TEST_TMP/kubeconfig" WATCH_STOP_FILE="$TEST_TMP/never-stop" \
  bash "$helper" - nodes name worker-scoped \
  "$TEST_TMP/node.jsonl" "$TEST_TMP/node.ready" > "$TEST_TMP/node.log" 2>&1 &
watcher_pid=$!
armed=false
for ((attempt = 0; attempt < 50; attempt++)); do
  if [[ -s "$TEST_TMP/node.ready" ]]; then armed=true; break; fi
  if ! kill -0 "$watcher_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[[ "$armed" == true ]] || { printf 'Cluster-scoped watch never armed.\n' >&2; exit 1; }
child_pid=''
while IFS='=' read -r key value; do
  if [[ "$key" == watch_pid ]]; then child_pid="$value"; fi
done < "$TEST_TMP/node.ready"
[[ "$child_pid" =~ ^[1-9][0-9]*$ ]]
kill "$watcher_pid"
if wait "$watcher_pid"; then
  printf 'Stopped watcher unexpectedly succeeded.\n' >&2
  exit 1
fi
watcher_pid=''
[[ ! -e "$TEST_TMP/node.ready" ]] || { printf 'Stopped watcher left a stale armed marker.\n' >&2; exit 1; }
if kill -0 "$child_pid" 2>/dev/null; then
  printf 'Stopped watcher left an oc child running.\n' >&2
  exit 1
fi
# A malformed bound is refused before any cluster access.
if KUBECONFIG_PATH="$TEST_TMP/kubeconfig" WATCH_MAX_SECONDS=soon \
  bash "$helper" test-namespace vmbackup name backup-bound \
  "$TEST_TMP/bound.jsonl" "$TEST_TMP/bound.ready" > "$TEST_TMP/bound.log" 2>&1; then
  printf 'Watcher accepted a malformed WATCH_MAX_SECONDS.\n' >&2
  exit 1
fi
grep -q 'Invalid WATCH_MAX_SECONDS' "$TEST_TMP/bound.log" || {
  printf 'Watcher did not explain the malformed WATCH_MAX_SECONDS.\n' >&2
  exit 1
}

# WATCH_MAX_SECONDS self-terminates an armed watch and revokes readiness.
KUBECONFIG_PATH="$TEST_TMP/kubeconfig" WATCH_STOP_FILE="$TEST_TMP/never-stop-bound" \
  WATCH_MAX_SECONDS=2 \
  bash "$helper" test-namespace vmbackup name backup-bounded \
  "$TEST_TMP/bounded.jsonl" "$TEST_TMP/bounded.ready" > "$TEST_TMP/bounded.log" 2>&1 &
watcher_pid=$!
bounded_armed=false
for ((attempt = 0; attempt < 50; attempt++)); do
  if [[ -s "$TEST_TMP/bounded.ready" ]]; then bounded_armed=true; break; fi
  if ! kill -0 "$watcher_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
[[ "$bounded_armed" == true ]] || { printf 'Bounded watch never armed.\n' >&2; exit 1; }
bounded_child=''
while IFS='=' read -r key value; do
  if [[ "$key" == watch_pid ]]; then bounded_child="$value"; fi
done < "$TEST_TMP/bounded.ready"
[[ "$bounded_child" =~ ^[1-9][0-9]*$ ]]
set +e
wait "$watcher_pid"
bounded_status=$?
set -e
watcher_pid=''
if ((bounded_status != 3)); then
  printf 'Bounded watch exited %s, expected 3 (WATCH_MAX_SECONDS reached).\n' "$bounded_status" >&2
  exit 1
fi
grep -q 'WATCH_MAX_SECONDS=2; self-terminating' "$TEST_TMP/bounded.log" || {
  printf 'Bounded watch did not report its self-termination.\n' >&2
  exit 1
}
[[ ! -e "$TEST_TMP/bounded.ready" ]] || { printf 'Bounded watch left a stale armed marker.\n' >&2; exit 1; }
if kill -0 "$bounded_child" 2>/dev/null; then
  printf 'Bounded watch left an oc child running.\n' >&2
  exit 1
fi

printf 'Authenticated watch readiness and loss behavior passed.\n'
