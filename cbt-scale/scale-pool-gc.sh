#!/usr/bin/env bash
# scale-pool-gc.sh — find (and optionally delete) orphaned RBD images in the
# replica-1 backup pool. An image is an orphan when no PersistentVolume in the
# cluster references it (imageName). Orphans appear when a wipe force-strips PV
# finalizers / deletes PV objects while the backing RBD image survives; they
# consume raw Ceph capacity but are unreachable from Kubernetes.
# Only plain csi-vol-<uuid> images count; ceph-csi internal clone parents
# (rf-*, rest-*, csi-vol-<uuid>-temp) are reported as skipped, never deleted.
#
# Usage: KUBECONFIG=... cbt-scale/scale-pool-gc.sh [--pool cbt-scale-pool]
#                                                  [--namespace vm-cbt-demo]
#                                                  [--delete] [--jobs 8]
#   (default)  report only: prints orphan count / written GiB, exit 0
#   --delete   rbd rm each orphan + its CSI omap entries, then re-verify
# Exit: 0 clean/deleted, 1 orphans remain after --delete or deletes failed,
#       2 usage/safety refusal.
# Safety:
#   * Only images in --pool are considered; VM roots live in
#     ocs-storagecluster-cephblockpool and are never listed.
#   * Refuses to delete while any PVC in the namespace is Pending (an image
#     may exist before its PV object is created).
#   * The PV set is re-read right before deletion.
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG}"
POOL="cbt-scale-pool"; NS="${NAMESPACE:-vm-cbt-demo}"; DELETE=0; JOBS=8
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool) POOL="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --delete) DELETE=1; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ "$JOBS" =~ ^[0-9]+$ ]] && (( JOBS > 0 )) || { echo "--jobs must be a positive integer" >&2; exit 2; }
log(){ printf '%s GC: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

TB=$(oc get pod -n openshift-storage -l app=rook-ceph-tools -o name | head -1)
[[ -n "$TB" ]] || { echo "rook-ceph-tools pod not found" >&2; exit 2; }
tools(){ oc exec -n openshift-storage "$TB" -- "$@"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pv_images(){  # image names referenced by any PV in $POOL
  oc get pv -o json | jq -r --arg p "$POOL" \
    '.items[] | select(.spec.csi.volumeAttributes.pool==$p) | .spec.csi.volumeAttributes.imageName' | sort -u
}
find_orphans(){  # writes $TMP/orphans.txt ; sets N_ORPH, ORPH_GIB, N_IMG
  # Image names come from `rbd ls` (authoritative). `rbd du` aborts with exit 2
  # when ONE image has a dangling parent snapshot (stale ceph-csi rf-*/rest-*
  # image), so it is best-effort and only supplies the written-size estimate.
  pv_images | LC_ALL=C sort -u > "$TMP/pv.txt"
  tools rbd ls -p "$POOL" | LC_ALL=C sort -u > "$TMP/names.txt"
  : > "$TMP/sizes.tsv"
  if tools rbd du -p "$POOL" --format json > "$TMP/du.json" 2>"$TMP/du.err" \
     || jq -e . "$TMP/du.json" >/dev/null 2>&1; then
    jq -r '.images[] | select(.snapshot == null) | [.name, (.used_size // 0)] | @tsv' "$TMP/du.json" \
      | LC_ALL=C sort -k1,1 > "$TMP/sizes.tsv" || true
  fi
  [[ -s "$TMP/sizes.tsv" ]] || log "WARNING: rbd du unusable; written size reported as 0 (see: $(grep -v librbd "$TMP/du.err" | tail -1))"
  LC_ALL=C join -t $'\t' -a1 -e0 -o 0,2.2 "$TMP/names.txt" "$TMP/sizes.tsv" > "$TMP/images.tsv"
  # Only plain CSI volumes (csi-vol-<uuid>) are orphan candidates. ceph-csi
  # internals (rf-*, rest-*, csi-vol-<uuid>-temp) are the clone parents of
  # live PVs (cross-pool clones of the golden images): never PV-referenced by
  # name, but `rbd rm` correctly refuses them while a child clone exists.
  LC_ALL=C comm -23 "$TMP/names.txt" "$TMP/pv.txt" > "$TMP/unreferenced.txt"
  grep -E '^csi-vol-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' "$TMP/unreferenced.txt" > "$TMP/orphans.txt" || true
  N_INTERNAL=$(( $(wc -l < "$TMP/unreferenced.txt" | tr -d ' ') - $(wc -l < "$TMP/orphans.txt" | tr -d ' ') ))
  N_ORPH=$(wc -l < "$TMP/orphans.txt" | tr -d ' ')
  ORPH_GIB=$(LC_ALL=C join -t $'\t' "$TMP/orphans.txt" "$TMP/images.tsv" | awk -F'\t' '{s+=$2} END{printf "%.0f", s/1073741824}')
  N_IMG=$(wc -l < "$TMP/names.txt" | tr -d ' ')
}

find_orphans
log "pool=$POOL images=$N_IMG pv-referenced=$(wc -l < "$TMP/pv.txt" | tr -d ' ') orphans=$N_ORPH written=${ORPH_GIB}GiB (ceph-csi internal images skipped: $N_INTERNAL)"
(( N_ORPH == 0 )) && exit 0
if (( ! DELETE )); then
  log "report only; re-run with --delete to remove them"
  exit 0
fi

pending=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | awk '$2=="Pending"' | wc -l | tr -d ' ')
if (( pending > 0 )); then
  echo "refusing: $pending PVC(s) Pending in $NS (provisioning in flight)" >&2; exit 2
fi
find_orphans   # re-read PV set immediately before deleting
(( N_ORPH == 0 )) && { log "no orphans after re-check"; exit 0; }

log "deleting $N_ORPH orphan images (jobs=$JOBS)"

# Stale exclusive locks: a dead CSI node-plugin session can keep a lock on an
# orphan image ("image still has watchers"), which blocks rbd rm. The image is
# already confirmed orphan (no PV references it), so the lock cannot belong to
# a live consumer. Release locks before deleting. Lock list output:
#   Locker          ID                     Address
#   client.5149359  auto 18446462598...    100.64.0.24:0/673861413
UNLOCK_SCRIPT=$(cat <<'REMOTE'
POOL="$1"
unlock_one(){
  img="$1"
  rbd lock list "$POOL/$img" 2>/dev/null | awk -v img="$img" '
    /^client\./ { locker=$1; id=$2; sub(/ .*/, "", id); print img "\t" locker "\t" id }
  ' | while IFS="$(printf "\t")" read -r im locker id; do
    rbd lock remove "$POOL/$im" "$id" "$locker" >/dev/null 2>&1 || echo "unlock-failed $im $locker"
  done
}
export -f unlock_one; export POOL
xargs -P 8 -I{} bash -c 'unlock_one {}'
REMOTE
)
log "releasing stale exclusive locks on orphan images"
oc exec -i -n openshift-storage "$TB" -- bash -c "$UNLOCK_SCRIPT" _ "$POOL" \
  < "$TMP/orphans.txt" > "$TMP/unlock.out" || true
unlock_fail=$(grep -c 'unlock-failed' "$TMP/unlock.out" || true)
(( unlock_fail == 0 )) || log "WARNING: $unlock_fail lock release(s) failed (live watchers?)"
# One exec: the script is passed as an argument, the orphan list on stdin.
# Per image: read PV name from image metadata, rm image, drop its CSI omap entries.
REMOTE_SCRIPT=$(cat <<'REMOTE'
POOL="$1"; JOBS="$2"
gc_one(){
  img="$1"; uuid="${img#csi-vol-}"
  pvn=$(rbd image-meta get "$POOL/$img" csi.storage.k8s.io/pv/name 2>/dev/null || true)
  if rbd rm "$POOL/$img" >/dev/null 2>&1; then
    if [ -n "$pvn" ]; then rados -p "$POOL" rmomapkey csi.volumes.default "csi.volume.$pvn" >/dev/null 2>&1 || true; fi
    rados -p "$POOL" rm "csi.volume.$uuid" >/dev/null 2>&1 || true
    echo "ok $img"
  else
    echo "FAIL $img"
  fi
}
export -f gc_one; export POOL
xargs -P "$JOBS" -I{} bash -c 'gc_one {}'
REMOTE
)
oc exec -i -n openshift-storage "$TB" -- bash -c "$REMOTE_SCRIPT" _ "$POOL" "$JOBS" \
  < "$TMP/orphans.txt" > "$TMP/gc.out"
ok=$(grep -c '^ok ' "$TMP/gc.out" || true); fail=$(grep -c '^FAIL ' "$TMP/gc.out" || true)
log "deleted=$ok failed=$fail (of $N_ORPH)"
find_orphans
log "after: images=$N_IMG orphans=$N_ORPH"
(( fail == 0 && N_ORPH == 0 )) || exit 1
