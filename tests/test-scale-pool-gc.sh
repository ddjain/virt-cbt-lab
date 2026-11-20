#!/usr/bin/env bash
set -euo pipefail
# Offline (fake oc, no cluster): scale-pool-gc.sh still reports orphans when
# `rbd du` exits non-zero because one image has a dangling parent snapshot
# (regression: the run aborted and no orphan was ever cleaned), and treats a
# PV-referenced image as live.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$TEST_TMP/bin/oc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get pod"*) echo pod/rook-ceph-tools-fake ;;
  "get pv -o json") printf '%s' '{"items":[{"spec":{"csi":{"volumeAttributes":{"pool":"cbt-scale-pool","imageName":"csi-vol-live"}}}}]}' ;;
  *"rbd ls"*) printf '%s\n' csi-vol-live csi-vol-orphan rf-stale ;;
  *"rbd du"*)
    printf '%s' '{"images":[{"name":"csi-vol-live","used_size":1073741824},{"name":"csi-vol-orphan","used_size":2147483648},{"name":"csi-vol-orphan","snapshot":"s","used_size":99}]}'
    echo 'rbd: error opening snapshot rf-stale@x: (2) No such file or directory' >&2
    exit 2 ;;
esac
EOF
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" KUBECONFIG=/nonexistent

out="$(bash "$ROOT_DIR/cbt-scale/scale-pool-gc.sh" 2>&1)" || fail "report-only exited non-zero: $out"
[[ "$out" == *"images=3 pv-referenced=1 orphans=2 written=2GiB"* ]] || fail "unexpected report: $out"
printf 'PASS: scale-pool-gc tolerates rbd du failure\n'
