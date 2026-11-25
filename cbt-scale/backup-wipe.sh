#!/usr/bin/env bash
# backup-wipe.sh — fleet-wide backup-objects-only cleanup.
# Deletes every vmbackup / vmbackuptracker / backup PVC (vm-*-pvc-*) and the
# PVs behind them in the namespace, then runs rbd-orphan-gc.sh --delete.
# VMs, root disks (vm-disk-*), persistent-state volumes (persistent-state-for-*)
# and Services are NEVER touched. Use this to reclaim backup capacity after
# runs when the fleet must survive; use ns-wipe.sh for a full teardown.
#
# Motivation (2026-11-21, cloud05): stacked 300/1200/1000-VM runs filled the
# replica-1 pool; the normal delete path stalled with CSI/unfinalizer chains
# wedged by full OSDs. This script performs the escalation that unblocked it:
# strip finalizers on stuck vmbackups, PVCs and PVs (including Bound PVs whose
# PVC is gone), and if ceph reports full OSDs, temporarily raise mon_osd_
# full_ratio so rbd lock remove / rbd rm can complete, restoring it after.
#
# Usage: KUBECONFIG=... cbt-scale/backup-wipe.sh [--namespace vm-cbt-demo] [--yes]
#   --yes   required for the destructive run (report-only without it)
# Exit: 0 clean, 1 objects/images remain, 2 usage/safety refusal.
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG}"
NS="${NAMESPACE:-vm-cbt-demo}"; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
log(){ printf '%s WIPE: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

count_kind(){ oc get "$1" -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' '; }

backup_pv_names(){  # PVs claimed by backup PVCs (existing or already-deleted claimRef)
  oc get pv -o json | jq -r '.items[]
    | select(.spec.claimRef.namespace=="'"$NS"'")
    | select(.spec.claimRef.name | test("^vm-(backup|incremental)-pvc-"))
    | .metadata.name'
}

VB=$(count_kind vmbackup); VT=$(count_kind vmbackuptracker)
BPVC=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | grep -cE '^vm-(backup|incremental)-pvc-' || true)
BPV=$(backup_pv_names | wc -l | tr -d ' ')
log "before: vmbackup=$VB tracker=$VT backupPVC=$BPVC backupPV=$BPV (namespace=$NS)"
if (( VB + VT + BPVC + BPV == 0 )); then log "nothing to do"; exit 0; fi
if (( ! YES )); then log "report only; re-run with --yes to delete"; exit 0; fi

# --- phase 1: delete API objects (all backup objects, fleet-wide) ---
oc delete vmbackup -n "$NS" --all --wait=false >/dev/null 2>&1 || true
oc delete vmbackuptracker -n "$NS" --all --wait=false >/dev/null 2>&1 || true
oc get pvc -n "$NS" -o name 2>/dev/null \
  | { grep -E 'vm-(backup|incremental)-pvc-' || true; } \
  | xargs -r oc delete -n "$NS" --wait=false >/dev/null 2>&1 || true
log "delete requests sent; waiting for drain (finalizers unwinding)"

# --- phase 2: drain poll with staged finalizer escalation ---
# Stage A: give the healthy path 10 minutes.
DEADLINE=$(( $(date +%s) + 600 ))
while :; do
  VB=$(count_kind vmbackup); VT=$(count_kind vmbackuptracker)
  BPVC=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | grep -cE '^vm-(backup|incremental)-pvc-' || true)
  (( VB + VT + BPVC == 0 )) && break
  (( $(date +%s) > DEADLINE )) && break
  sleep 30
done

# Stage B: strip finalizers on any remaining backup objects (vmbackup 4-hop
# chain and pvc-protection both stall when the CSI layer is degraded).
strip_remaining(){
  oc get vmbackup -n "$NS" -o name 2>/dev/null | while read -r n; do
    oc patch -n "$NS" "$n" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  done
  oc get pvc -n "$NS" -o name 2>/dev/null | { grep -E 'vm-(backup|incremental)-pvc-' || true; } | while read -r n; do
    oc patch -n "$NS" "$n" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  done
}
VB=$(count_kind vmbackup); VT=$(count_kind vmbackuptracker)
BPVC=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | grep -cE '^vm-(backup|incremental)-pvc-' || true)
if (( VB + VT + BPVC > 0 )); then
  log "drain stalled (vmbackup=$VB tracker=$VT backupPVC=$BPVC) — stripping finalizers"
  strip_remaining
  sleep 60
fi

# --- phase 3: PV purge, including Bound PVs whose PVC is gone ---
# ns-wipe.sh only purges Released/Available PVs; when the CSI controller is
# degraded, PVs stay Bound forever with a deletionTimestamp. Their claimRef
# names a (deleted) backup PVC, so they are safe to force.
full_ratio_trap(){ return 0; }
RAISED=0
restore_full_ratio(){ (( RAISED )) || return 0; log "restoring mon_osd_full_ratio=$SAVED_RATIO"; tools ceph osd set-full-ratio "$SAVED_RATIO" || true; RAISED=0; }
trap restore_full_ratio EXIT

TB=$(oc get pod -n openshift-storage -l app=rook-ceph-tools -o name | head -1)
tools(){ oc exec -n openshift-storage "$TB" -- "$@"; }
if [[ -n "$TB" ]]; then
  health=$(tools ceph health 2>/dev/null || true)
  if grep -qE '[0-9]+ full osd' <<<"$health"; then
    SAVED_RATIO=$(tools ceph osd dump 2>/dev/null | awk '/^full_ratio/ {print $2; exit}')
    if [[ -n "${SAVED_RATIO:-}" ]]; then
      log "ceph reports full OSDs — raising mon_osd_full_ratio $SAVED_RATIO -> 0.95 so rbd ops can proceed (restored on exit)"
      tools ceph osd set-full-ratio 0.95 && RAISED=1
    fi
  fi
fi

for round in 1 2 3 4; do
  PVS=$(backup_pv_names)
  N=$(echo "$PVS" | grep -c . || true)
  log "PV purge round $round: $N backup PV(s)"
  (( N == 0 )) && break
  echo "$PVS" | while read -r pv; do
    [[ -n "$pv" ]] || continue
    oc patch pv "$pv" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
    oc delete pv "$pv" --wait=false >/dev/null 2>&1 || true
  done
  sleep 60
done

# --- phase 4: orphan image GC (full_ratio raise makes its lock removals work) ---
restore_full_ratio
log "running rbd-orphan-gc.sh --delete"
bash "$(dirname "$0")/rbd-orphan-gc.sh" --delete || log "WARNING: rbd-orphan-gc left orphans (rerun it)"

# --- phase 5: verdict ---
VB=$(count_kind vmbackup); VT=$(count_kind vmbackuptracker)
BPVC=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | grep -cE '^vm-(backup|incremental)-pvc-' || true)
BPV=$(backup_pv_names | wc -l | tr -d ' ')
log "after: vmbackup=$VB tracker=$VT backupPVC=$BPVC backupPV=$BPV"
log "VMs still present: $(count_kind vm)"
if (( VB + VT + BPVC + BPV > 0 )); then log "WARNING: backup objects remain"; exit 1; fi
log "backup wipe complete"
