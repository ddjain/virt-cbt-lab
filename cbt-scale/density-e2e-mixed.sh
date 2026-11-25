#!/usr/bin/env bash
# density-e2e-mixed.sh — mixed-fleet companion to density-e2e.sh.
# Invoked via: density-e2e.sh --mixed rhel9=N,windows=5 [--wave 25] [--pool <prefix>]
# Env contract (set by the parent): RHEL_POOL WIN_POOL RHEL_N WIN_N WAVE
# RHEL_SC WIN_SC NAMESPACE, plus KUBECONFIG and cwd = repo root.
#
# Encodes the validated 2026-11-18 mixed run (rhel-mix + win-mix pools):
# cleanup (shared, with finalizer force-unstick + PV purge) -> both pools
# created concurrently -> N/N ready both -> both scale-driver2 instances
# run concurrently (all fulls in one wave, all incrementals in one wave) ->
# live-cluster validation per pool -> summary.json.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Code lives in cbt-scale/ (tracked); runtime state and evidence live in
# SCALE_STATE_DIR (default: <repo>/artifacts, gitignored).
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"; export SCALE_STATE_DIR
cd "$ROOT_DIR"
: "${KUBECONFIG:?}" "${RHEL_POOL:?}" "${WIN_POOL:?}" "${RHEL_N:?}" \
   "${WIN_N:?}" "${WAVE:?}" "${RHEL_SC:?}" "${WIN_SC:?}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"

EVIDENCE="$SCALE_STATE_DIR/density-scale-${RHEL_POOL%-rhel}"
mkdir -p "$EVIDENCE/rhel" "$EVIDENCE/win"
SUMMARY_JSON="$EVIDENCE/summary.json"
LOG="$EVIDENCE/e2e.log"
log(){ printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }

# ---- Phase 0: cleanup (shared namespace) ----
existing=$(oc get vm,vmbackup,vmbackuptracker,pvc,svc,dv -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if (( existing > 0 )); then
  log "CLEANUP: wiping $existing objects from previous run"
  oc delete vmbackup,vmbackuptracker,vm,dv,pvc,svc -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1
  sleep 90
  oc get vmbackup -n "$NAMESPACE" -o name 2>/dev/null | while read -r vb; do
    oc patch -n "$NAMESPACE" "$vb" --type=json \
      -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  done
  sleep 60
  oc delete vmbackup,vmbackuptracker,vm,dv,pvc,svc -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1 || true
  oc get pv -o json | jq -r '.items[] | select(.status.phase=="Released" or .status.phase=="Available") | .metadata.name' \
  | while read -r pv; do
    oc patch pv "$pv" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
    oc delete pv "$pv" --wait=false >/dev/null 2>&1 || true
  done
  sleep 30
fi
# orphan RBD images (PV objects gone, image survived) waste raw capacity — GC them
bash "$ROOT_DIR/cbt-scale/rbd-orphan-gc.sh" --delete 2>&1 | tee -a "$LOG" || log "WARN: rbd-orphan-gc failed (see above)"
bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "pre-setup-mixed" 2>&1 | tail -1 | tee -a "$LOG"

# ---- Phase 1: both pools concurrently ----
log "SETUP: creating $RHEL_N rhel9 ($RHEL_POOL) + $WIN_N windows ($WIN_POOL)"
set -a; . ./.env 2>/dev/null || true; set +a
# VM_OS/POOL are make ARGUMENTS: `.env` (VM_OS=rhel9) overrides env vars in make
make density-setup VM_OS=rhel9 POOL="$RHEL_POOL" MANIFEST_VARIANT=large-odf \
  DENSITY_VM_COUNT="$RHEL_N" DENSITY_INCREMENTAL_PASSES=1 DENSITY_QPS=50 \
  DENSITY_WAIT_MINUTES=$(( RHEL_N / 4 + 60 )) > "$EVIDENCE/setup-rhel.log" 2>&1 &
RP=$!
make density-setup VM_OS=windows POOL="$WIN_POOL" GUEST_EXEC_POLL_ATTEMPTS=450 \
  DENSITY_VM_COUNT="$WIN_N" DENSITY_INCREMENTAL_PASSES=1 DENSITY_QPS=50 \
  DENSITY_WAIT_MINUTES=$(( WIN_N / 4 + 120 )) > "$EVIDENCE/setup-win.log" 2>&1 &
WP=$!
wait "$RP" || { log "SETUP: rhel pool FAILED (see $EVIDENCE/setup-rhel.log)"; exit 1; }
wait "$WP" || { log "SETUP: win pool FAILED (see $EVIDENCE/setup-win.log)"; exit 1; }
read -r R_READY W_READY TOTAL < <(oc get vm -n "$NAMESPACE" -o json | jq -r '
  [([.items[]|select(.status.ready==true and .metadata.labels["virt-cbt-lab/pool"]=="'"$RHEL_POOL"'")]|length),
   ([.items[]|select(.status.ready==true and .metadata.labels["virt-cbt-lab/pool"]=="'"$WIN_POOL"'")]|length),
   (.items|length)] | @tsv')
log "SETUP: ready rhel=$R_READY/$RHEL_N win=$W_READY/$WIN_N (total VMs $TOTAL)"
(( R_READY == RHEL_N && W_READY == WIN_N )) || { log "SETUP: not all VMs ready"; exit 1; }
bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "post-setup-mixed" 2>&1 | tail -1 | tee -a "$LOG"

# ---- Phase 2: both drivers concurrently ----
log "DRIVER: starting both (rhel SC=$RHEL_SC win SC=$WIN_SC wave=$WAVE)"
T0=$(date +%s)
EVIDENCE_DIR="$EVIDENCE/rhel" BACKUP_SC="$RHEL_SC" \
  bash "$ROOT_DIR/cbt-scale/scale-driver2.sh" "$RHEL_POOL" 1 "$RHEL_N" "$WAVE" > "$EVIDENCE/driver-rhel.log" 2>&1 &
DR=$!
EVIDENCE_DIR="$EVIDENCE/win" BACKUP_SC="$WIN_SC" \
  bash "$ROOT_DIR/cbt-scale/scale-driver2.sh" "$WIN_POOL" 1 "$WIN_N" "$WAVE" > "$EVIDENCE/driver-win.log" 2>&1 &
DW=$!
wait "$DR" || log "DRIVER: rhel nonzero exit (see $EVIDENCE/driver-rhel.log)"
wait "$DW" || log "DRIVER: win nonzero exit (see $EVIDENCE/driver-win.log)"
TOTAL_WALL=$(( $(date +%s) - T0 ))
R_FULL_WALL=$(grep -m1 "full phase wall" "$EVIDENCE/driver-rhel.log" | grep -oE 'wall: [0-9]+s' | grep -oE '[0-9]+s' || true)
W_FULL_WALL=$(grep -m1 "full phase wall" "$EVIDENCE/driver-win.log" | grep -oE 'wall: [0-9]+s' | grep -oE '[0-9]+s' || true)

# ---- Phase 3: live-cluster validation (authoritative) ----
validate(){  # $1 pool  $2 expected count
  local pool="$1" n="$2" f i t
  f=$(oc get vmbackup -n "$NAMESPACE" -o json | jq --arg p "vm-backup-$pool-" \
    '[.items[] | select(.metadata.name|startswith($p)) | .status.conditions[]?
      | select(.type=="Done" and .status=="True")] | length')
  i=$(oc get vmbackup -n "$NAMESPACE" -o json | jq --arg p "vm-incremental-$pool-" \
    '[.items[] | select(.metadata.name|startswith($p)) | .status.conditions[]?
      | select(.type=="Done" and .status=="True")] | length')
  t=$(oc get vmbackuptracker -n "$NAMESPACE" -o json | jq --arg p "vm-incremental-$pool-" \
    '[.items[] | select(.status.latestCheckpoint.name // "" | startswith($p))] | length')
  echo "$f $i $t"
  (( f == n && i == n && t == n ))
}
read -r RF RI RT < <(validate "$RHEL_POOL" "$RHEL_N") || true
read -r WF WI WT < <(validate "$WIN_POOL" "$WIN_N") || true
bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "post-backup-mixed" 2>&1 | tail -1 | tee -a "$LOG"

VERDICT=PASS
(( RF == RHEL_N && RI == RHEL_N && RT == RHEL_N )) || VERDICT=FAIL
(( WF == WIN_N  && WI == WIN_N  && WT == WIN_N  )) || VERDICT=FAIL

# ---- Phase 4: summary ----
jq -n \
  --arg prefix "${RHEL_POOL%-rhel}" --arg rhel_pool "$RHEL_POOL" --arg win_pool "$WIN_POOL" \
  --argjson rhel_n "$RHEL_N" --argjson win_n "$WIN_N" --arg rhel_sc "$RHEL_SC" --arg win_sc "$WIN_SC" \
  --argjson rhel_full "$RF" --argjson rhel_incr "$RI" --argjson rhel_trackers "$RT" \
  --argjson win_full "$WF" --argjson win_incr "$WI" --argjson win_trackers "$WT" \
  --arg verdict "$VERDICT" --arg total_wall "${TOTAL_WALL}s" \
  --arg rhel_full_wall "${R_FULL_WALL:-null}" --arg win_full_wall "${W_FULL_WALL:-null}" \
  --arg evidence "$EVIDENCE" \
  '{mode:"mixed", prefix:$prefix,
    rhel:{pool:$rhel_pool, n:$rhel_n, backup_sc:$rhel_sc, full_ok:$rhel_full,
          incr_ok:$rhel_incr, trackers_ok:$rhel_trackers, full_wall:$rhel_full_wall},
    windows:{pool:$win_pool, n:$win_n, backup_sc:$win_sc, full_ok:$win_full,
             incr_ok:$win_incr, trackers_ok:$win_trackers, full_wall:$win_full_wall},
    verdict:$verdict, total_wall:$total_wall, incr_profile:"light",
    evidence_dir:$evidence,
    note:"verdict from live cluster state (Done reasons + tracker checkpoints), not driver tallies; windows workload step is a driver artifact (no vm-ssh Service)."}' \
  | tee "$SUMMARY_JSON"
log "DONE verdict=$VERDICT rhel=$RF/$RHEL_N full,$RI/$RHEL_N incr,$RT trackers win=$WF/$WIN_N full,$WI/$WIN_N incr,$WT trackers total_wall=${TOTAL_WALL}s"
[[ "$VERDICT" == PASS ]]
