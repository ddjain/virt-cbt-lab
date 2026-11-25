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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) CONFIRMED=1; shift ;;
    --namespace) [[ $# -ge 2 ]] || { echo "--namespace requires a value" >&2; exit 2; }; NS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
(( CONFIRMED )) || { echo "refusing to wipe without --yes" >&2; exit 2; }
log(){ printf "%s %s\n" "$(date -u +%H:%M:%S)" "$*"; }
oc="oc -n $NS"

# PVCs labeled virt-cbt-lab/golden=true belong to golden DataVolumes (CDI
# recreates them on delete); they are never wiped nor counted as drain leftovers.
KEEP_SEL='!virt-cbt-lab/golden'
# 1. snapshot counts
for r in vmbackup vmbackuptracker vm pvc svc; do
  log "pre-$r: $($oc get $r -l "$KEEP_SEL" --no-headers 2>/dev/null | wc -l | tr -d \" \")"
done
log "pre-secret (labeled): $($oc get secret -l app.kubernetes.io/managed-by=virt-cbt-lab --no-headers 2>/dev/null | wc -l | tr -d \" \")"

# 2. delete (wait=false; we poll drain ourselves)
$oc delete vmbackup --all --wait=false 2>/dev/null || true
$oc delete vmbackuptracker --all --wait=false 2>/dev/null || true
$oc delete pvc -l "$KEEP_SEL" --wait=false 2>/dev/null || true
$oc delete vm --all --wait=false 2>/dev/null || true
# Workflow-created secrets only (Windows OOBE etc.), selected by the managed-by
# label so default namespace secrets (service accounts, tokens) are never touched.
$oc delete secret -l app.kubernetes.io/managed-by=virt-cbt-lab --wait=false 2>/dev/null || true
$oc delete svc --all --wait=false 2>/dev/null || true

# 3. wait for drain, force-unstick finalizers after grace
DEADLINE=$(( $(date +%s) + 900 ))
STUCK_DONE=0
while :; do
  left=0
  for r in vmbackup vmbackuptracker vm pvc svc; do
    n=$($oc get $r -l "$KEEP_SEL" --no-headers 2>/dev/null | wc -l | tr -d " ")
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

# 5. garbage-collect orphan RBD images in the ODF block pool
bash "$(dirname "$0")/rbd-orphan-gc.sh" --delete || { log "WARNING: rbd-orphan-gc left orphans"; exit 1; }
log "block pool clean: no orphan RBD images"
