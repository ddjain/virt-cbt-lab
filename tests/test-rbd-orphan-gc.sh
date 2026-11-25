#!/usr/bin/env bash
set -euo pipefail
# Offline (fake oc, no cluster): rbd-orphan-gc.sh
#  * still reports orphans when `rbd du` exits non-zero because one image has a
#    dangling parent snapshot (regression: the run aborted and no orphan was
#    ever cleaned);
#  * treats a PV-referenced image as live;
#  * skips ceph-csi internal rf-*/rest-*/csi-vol-<uuid>-temp images, which are
#    clone parents of live PVs and can never be removed while children exist;
#  * --delete does NOT raise the full ratio for `backfillfull` OSDs (only for
#    real "N full osd(s)" health), and does not abort on the health pipe.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

LIVE=csi-vol-11111111-1111-1111-1111-111111111111
ORPHAN=csi-vol-22222222-2222-2222-2222-222222222222
MARKER="$TEST_TMP/deleted"

cat > "$TEST_TMP/bin/oc" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"bash -c"*) touch "$MARKER"; while read -r i; do echo "ok \$i"; done ;;
  *"get pod"*) echo pod/rook-ceph-tools-fake ;;
  "get pv -o json") printf '%s' '{"items":[{"spec":{"csi":{"volumeAttributes":{"pool":"ocs-storagecluster-cephblockpool","imageName":"$LIVE"}}}}]}' ;;
  *"get pvc -A"*) : ;;
  *"ceph health"*) echo 'HEALTH_WARN 1 backfillfull osd(s)' ;;
  *set-full-ratio*) echo RAISED >> "\$FAKE_LOG" ;;
  *"rbd ls"*)
    if [[ -e "$MARKER" ]]; then printf '%s\n' $LIVE rf-stale rest-stale; else printf '%s\n' $LIVE $ORPHAN rf-stale rest-stale $ORPHAN-temp; fi ;;
  *"rbd du"*)
    printf '%s' '{"images":[{"name":"$LIVE","used_size":1073741824},{"name":"$ORPHAN","used_size":2147483648},{"name":"$ORPHAN","snapshot":"s","used_size":99}]}'
    echo 'rbd: error opening snapshot rf-stale@x: (2) No such file or directory' >&2
    exit 2 ;;
esac
EOF
chmod +x "$TEST_TMP/bin/oc"
export PATH="$TEST_TMP/bin:$PATH" KUBECONFIG=/nonexistent FAKE_LOG="$TEST_TMP/calls.log"
: > "$FAKE_LOG"

out="$(bash "$ROOT_DIR/cbt-scale/rbd-orphan-gc.sh" 2>&1)" || fail "report-only exited non-zero: $out"
[[ "$out" == *"images=5 pv-referenced=1 orphans=1 written=2GiB (ceph-csi internal images skipped: 3)"* ]] \
  || fail "unexpected report: $out"
printf 'PASS: rbd-orphan-gc tolerates rbd du failure and skips ceph-csi internals\n'

rc=0; out="$(bash "$ROOT_DIR/cbt-scale/rbd-orphan-gc.sh" --delete 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "--delete exit $rc: $out"
! grep -q RAISED "$FAKE_LOG" || fail "full ratio raised for backfillfull-only health"
[[ "$out" == *"deleted=1 failed=0"* ]] || fail "unexpected delete output: $out"
printf 'PASS: rbd-orphan-gc --delete leaves full_ratio alone on backfillfull\n'
