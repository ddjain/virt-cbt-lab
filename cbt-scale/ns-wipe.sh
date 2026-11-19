#!/usr/bin/env bash
# ns-wipe.sh — deterministic namespace wipe for virt-cbt-lab scale/chaos runs.
# Deletes all workflow-managed objects in the namespace (vmbackups, trackers,
# VMs, PVCs, Services), force-unsticks stuck finalizers, and purges
# Released/Available PVs until zero so storage returns to baseline.
#
# Usage: KUBECONFIG=... cbt-scale/ns-wipe.sh [--yes] [--namespace vm-cbt-demo]
#   --yes  required for the destructive wipe (no confirmation inside scripts)
# Never touches golden images, infra namespaces, or the StorageClasses.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${KUBECONFIG:?export KUBECONFIG}"
NS="vm-cbt-demo"; CONFIRMED=0
for a in "$@"; do
  case "$a" in
    --yes) CONFIRMED=1 ;;
    --namespace) : ;; # consumed below via shift pairs
    *) [[ "${PREV:-}" == "--namespace" ]] && NS="$a" || { echo "unknown arg: $a" >&2; exit 2; } ;;
  esac
  PREV="$a"
done
(( CONFIRMED )) || { echo "refusing to wipe without --yes" >&2; exit 2; }
log(){ printf "%s %s\n" "$(date -u +%H:%M:%S)" "$*"; }
oc="oc -n $NS"

# 1. snapshot counts
for r in vmbackup vmbackuptracker vm pvc svc; do
  log "pre-$r: $($oc get $r --no-headers 2>/dev/null | wc -l | tr -d \" \")"
done

# 2. delete (wait=false; we poll drain ourselves)
$oc delete vmbackup --all --wait=false 2>/dev/null || true
$oc delete vmbackuptracker --all --wait=false 2>/dev/null || true
$oc delete pvc --all --wait=false 2>/dev/null || true
$oc delete vm --all --wait=false 2>/dev/null || true
$oc delete svc --all --wait=false 2>/dev/null || true

# 3. wait for drain, force-unstick finalizers after grace
DEADLINE=$(( $(date +%s) + 900 ))
STUCK_DONE=0
while :; do
  left=0
  for r in vmbackup vmbackuptracker vm pvc svc; do
    n=$($oc get $r --no-headers 2>/dev/null | wc -l | tr -d " ")
    left=$(( left + n ))
  done
  (( left == 0 )) && break
  if (( $(date +%s) > DEADLINE && STUCK_DONE == 0 )); then
    log "drain stalled ($left left) — stripping finalizers on stuck objects"
    for r in vmbackup vmbackuptracker; do
      $oc get $r -o name 2>/dev/null | while read -r n; do
        $oc patch "$n" --type=merge -p "{\"metadata\":{\"finalizers\":[]}}" >/dev/null 2>&1 || true
      done
    done
    STUCK_DONE=1
    DEADADLINE=$(( $(date +%s) + 600 )); DEADLINE=$DEADADLINE
  fi
  sleep 15
done
log "namespace objects drained"

# 4. purge Released/Available PVs until zero
for i in $(seq 1 120); do
  pvs=$($oc get pv -o json 2>/dev/null | jq -r ".items[] | select(.status.phase==\"Released\" or .status.phase==\"Available\") | select(.spec.claimRef.namespace==\"$NS\") | .metadata.name")
  [[ -z "$pvs" ]] && break
  while read -r pv; do
    [[ -n "$pv" ]] && oc delete pv "$pv" --wait=false >/dev/null 2>&1 || true
  done <<< "$pvs"
  sleep 10
done
left=$($oc get pv -o json 2>/dev/null | jq "[.items[] | select(.status.phase==\"Released\" or .status.phase==\"Available\") | select(.spec.claimRef.namespace==\"$NS\")] | length")
if (( left > 0 )); then log "WARNING: $left PVs still not purged"; exit 1; fi
log "wipe complete: namespace and PVs clean"

# 5. garbage-collect orphan RBD images left in the replica-1 backup pool
bash "$(dirname "$0")/scale-pool-gc.sh" --delete --namespace "$NS" || { log "WARNING: scale-pool-gc left orphans"; exit 1; }
log "scale pool clean: no orphan RBD images"
