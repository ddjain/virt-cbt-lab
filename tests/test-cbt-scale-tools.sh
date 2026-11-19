#!/usr/bin/env bash
set -euo pipefail
# Offline (fake oc, no cluster): cbt-scale/ tools write runtime state under
# SCALE_STATE_DIR, refuse unsafe/invalid invocations, and carry no
# environment-specific paths or stale artifacts/<tool>.sh code references.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCALE="$ROOT_DIR/cbt-scale"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Fake oc: records every call; answers just what storage-snapshot.sh asks for.
cat > "$TEST_TMP/bin/oc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_OC_LOG"
case "$*" in
  *"get pod"*) printf 'rook-ceph-tools-fake' ;;
  *rsh*) printf '%s' '{"stats":{"total_bytes":4294967296,"total_used_raw_bytes":1073741824},"pools":[{"name":"cbt-scale-pool","stats":{"stored":2147483648,"bytes_used":2147483648}},{"name":"ocs-storagecluster-cephblockpool","stats":{"stored":1073741824,"bytes_used":1073741824}}]}' ;;
  *"get pvc"*) printf '%s' '{"items":[{"spec":{"storageClassName":"ocs-storagecluster-ceph-rbd-scale","resources":{"requests":{"storage":"2Gi"}}}}]}' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" FAKE_OC_LOG="$TEST_TMP/oc.log" KUBECONFIG=/nonexistent
: > "$FAKE_OC_LOG"

# 1. storage-snapshot appends its CSV row under SCALE_STATE_DIR (not a fixed path).
state="$TEST_TMP/state"
out="$(SCALE_STATE_DIR="$state" bash "$SCALE/storage-snapshot.sh" smoke)"
[[ "$out" == snapshot\[smoke\]* ]] || fail "snapshot output: $out"
[[ -f "$state/storage-200b.csv" ]] || fail "csv not written under SCALE_STATE_DIR"
row="$(tail -n 1 "$state/storage-200b.csv")"
[[ "$row" == *,smoke,4,1,2,2,1,1,1,2,0,0 ]] || fail "csv row: $row"

# 2. ns-wipe refuses without --yes, exit 2, before touching the cluster.
: > "$FAKE_OC_LOG"
rc=0; bash "$SCALE/ns-wipe.sh" >/dev/null 2>"$TEST_TMP/err" || rc=$?
[[ "$rc" == 2 ]] || fail "ns-wipe without --yes exit $rc"
grep -q -- '--yes' "$TEST_TMP/err" || fail "ns-wipe refusal message missing"
[[ ! -s "$FAKE_OC_LOG" ]] || fail "ns-wipe called oc without --yes"

# 3. fleet-e2e rejects missing counts and unknown args with exit 2.
for args in "fleet-setup" "fleet-setup --bogus 1"; do
  rc=0
  # shellcheck disable=SC2086
  SCALE_STATE_DIR="$state" bash "$SCALE/fleet-e2e.sh" $args >/dev/null 2>"$TEST_TMP/err" || rc=$?
  [[ "$rc" == 2 ]] || fail "fleet-e2e '$args' exit $rc"
done
[[ ! -e "$state/fleet.yaml" ]] || fail "invalid fleet-setup created a registry"

# 4. density-e2e rejects an unsupported OS.
rc=0; bash "$SCALE/density-e2e.sh" --os debian --count 1 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "density-e2e --os debian exit $rc"

# 5. Code guard: no environment paths, no stale artifacts/<tool>.sh references.
if grep -rn '/root/' "$SCALE"; then fail "environment-specific /root/ path in cbt-scale"; fi
if grep -rnE 'artifacts/(density|fleet|scale|storage|ns-wipe|prom)[a-z0-9-]*\.sh' "$SCALE"; then
  fail "stale artifacts/<tool>.sh reference in cbt-scale"
fi

printf 'PASS: cbt-scale tools\n'
