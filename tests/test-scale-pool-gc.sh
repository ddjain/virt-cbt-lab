#!/usr/bin/env bash
set -euo pipefail
# Offline (fake oc, no cluster): scale-pool-gc.sh
#  * still reports orphans when `rbd du` exits non-zero because one image has a
#    dangling parent snapshot (regression: the run aborted and no orphan was
#    ever cleaned);
#  * treats a PV-referenced image as live;
#  * skips ceph-csi internal rf-*/rest-*/csi-vol-<uuid>-temp images, which are
#    clone parents of live PVs and can never be removed while children exist.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

LIVE=csi-vol-11111111-1111-1111-1111-111111111111
ORPHAN=csi-vol-22222222-2222-2222-2222-222222222222

cat > "$TEST_TMP/bin/oc" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get pod"*) echo pod/rook-ceph-tools-fake ;;
  "get pv -o json") printf '%s' '{"items":[{"spec":{"csi":{"volumeAttributes":{"pool":"cbt-scale-pool","imageName":"$LIVE"}}}}]}' ;;
  *"rbd ls"*) printf '%s\n' $LIVE $ORPHAN rf-stale rest-stale $ORPHAN-temp ;;
  *"rbd du"*)
    printf '%s' '{"images":[{"name":"$LIVE","used_size":1073741824},{"name":"$ORPHAN","used_size":2147483648},{"name":"$ORPHAN","snapshot":"s","used_size":99}]}'
    echo 'rbd: error opening snapshot rf-stale@x: (2) No such file or directory' >&2
    exit 2 ;;
esac
EOF
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" KUBECONFIG=/nonexistent

out="$(bash "$ROOT_DIR/cbt-scale/scale-pool-gc.sh" 2>&1)" || fail "report-only exited non-zero: $out"
[[ "$out" == *"images=5 pv-referenced=1 orphans=1 written=2GiB (ceph-csi internal images skipped: 3)"* ]] \
  || fail "unexpected report: $out"
printf 'PASS: scale-pool-gc tolerates rbd du failure and skips ceph-csi internals\n'
