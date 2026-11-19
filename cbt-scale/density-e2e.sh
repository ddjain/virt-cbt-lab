#!/usr/bin/env bash
# density-e2e.sh — deterministic end-to-end scale run for N VMs.
# Encodes the exact steps used in the validated 2026-11-18 runs
# (10/50 RHEL, 10 Windows, and mixed 5 RHEL + 5 Windows fleets) so the
# scale skill can invoke one command instead of re-deriving the workflow.
#
# Usage (single OS):
#   density-e2e.sh --os rhel9|rhel9-light|windows --count N [--wave 25]
#                  [--keep]          # skip cleanup gate (NOT allowed by skill
#                                   # unless pool is a fresh id)
#                  [--pool <id>]     # default: auto <os-prefix>-<timestamp>
#                  [--backup-sc <sc>]# default: cbt-scale-pool (rhel and windows,
#                                   # replica-1, test data only)
#                  [--incr-profile light]  # light is the only tested profile
#
# Usage (mixed fleet — both pools created and both drivers run concurrently,
# all fulls in one parallel wave, all incrementals in one parallel wave):
#   density-e2e.sh --mixed rhel9=5,windows=5 [--wave 25] [--pool <prefix>]
#     Pool ids become <prefix>-rhel / <prefix>-win (default prefix: mix-<ts>).
#     Backup SCs: rhel and windows both default to cbt-scale-pool (replica-1
#     scale pool, test data only). Override windows with env
#     WIN_SC=ocs-storagecluster-ceph-rbd for durable (3-copy) backups.
#
# Phases: preflight (SC existence check) -> cleanup -> pool create ->
#         snapshots -> driver A-D -> live-cluster validation ->
#         storage accounting -> summary JSON.
# Chaos is intentionally NOT included (run cbt-chaos-simple separately).
#
# Requirements (validated execution host): oc, jq, KUBECONFIG=<path to kubeconfig>,
# run from the virt-cbt-lab checkout root.

set -euo pipefail

OS=""; COUNT=""; WAVE=25; KEEP=false; POOL=""; BACKUP_SC=""; PROFILE="light"; MIXED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --wave) WAVE="$2"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    --pool) POOL="$2"; shift 2 ;;
    --backup-sc) BACKUP_SC="$2"; shift 2 ;;
    --incr-profile) PROFILE="$2"; shift 2 ;;
    --mixed) MIXED="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$PROFILE" == "light" ]] || { echo "only --incr-profile light is validated" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Code lives in cbt-scale/ (tracked); runtime state and evidence live in
# SCALE_STATE_DIR (default: <repo>/artifacts, gitignored).
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"; export SCALE_STATE_DIR
cd "$ROOT_DIR"
: "${KUBECONFIG:?export KUBECONFIG=<path to kubeconfig>}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"

check_sc_exists(){  # $1 = storageclass name; hard-fail with fix hint
  if ! oc get sc "$1" >/dev/null 2>&1; then
    echo "PREFLIGHT: StorageClass '$1' NOT FOUND — backup PVCs would sit Pending" >&2
    echo "  (2026-11-18 incident: cbt-scale-pool SC was deleted when the pool was" >&2
    echo "   recreated; backups stalled ~25min in Initializing with only PVC" >&2
    echo "   ProvisioningFailed events.) Fix — recreate the SC aliasing the live pool:" >&2
    echo "   oc get sc ocs-storagecluster-ceph-rbd-scale -o json | jq 'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.managedFields,.metadata.annotations,.metadata.labels) | .metadata.name=\"$1\"' | oc apply -f -" >&2
    exit 2
  fi
}

if [[ -n "$MIXED" ]]; then
  # ---------- mixed-fleet mode: two pools, both drivers concurrently ----------
  RHEL_N="${MIXED%%,*}"; RHEL_N="${RHEL_N#rhel9=}"
  WIN_N="${MIXED##*,}"; WIN_N="${WIN_N#windows=}"
  [[ "$RHEL_N" =~ ^[0-9]+$ && "$WIN_N" =~ ^[0-9]+$ ]] || { echo "--mixed rhel9=N,windows=N required" >&2; exit 2; }
  RHEL_SC="cbt-scale-pool"; WIN_SC="${WIN_SC:-cbt-scale-pool}"
  check_sc_exists "$RHEL_SC"; check_sc_exists "$WIN_SC"
  MIX_PREFIX="${POOL:-mix-$(date -u +%m%d%H%M%S)}"
  export RHEL_POOL="$MIX_PREFIX-rhel" WIN_POOL="$MIX_PREFIX-win" \
         RHEL_N WIN_N WAVE RHEL_SC WIN_SC NAMESPACE
  exec bash "$(dirname "$0")/density-e2e-mixed.sh"
fi

[[ "$OS" == "rhel9" || "$OS" == "rhel9-light" || "$OS" == "windows" ]] || { echo "--os rhel9|rhel9-light|windows (or --mixed) required" >&2; exit 2; }
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "--count N required" >&2; exit 2; }
check_sc_exists "${BACKUP_SC:-cbt-scale-pool}"

if [[ "$OS" == "rhel9" ]]; then
  PREFIX="rhel"; MANIFEST_ARGS=(MANIFEST_VARIANT=large-odf)
  : "${BACKUP_SC:=cbt-scale-pool}"
elif [[ "$OS" == "rhel9-light" ]]; then
  # right-sized RHEL 9 (10Gi root; needs `make rhel-light-golden` once);
  # backup PVCs are sized to match in the driver (see Phase 2)
  PREFIX="rhl"; MANIFEST_ARGS=(MANIFEST_VARIANT=large-odf)
  : "${BACKUP_SC:=cbt-scale-pool}"
else
  PREFIX="win"; MANIFEST_ARGS=()
  # (windows root disk SC is unaffected; only the backup target changes)
  # windows backups default to the replica-1 scale pool too (test data only);
  # override with --backup-sc ocs-storagecluster-ceph-rbd for durable backups
  : "${BACKUP_SC:=cbt-scale-pool}"
fi
[[ -n "$POOL" ]] || POOL="$PREFIX-$(date -u +%m%d%H%M%S)"
EVIDENCE="$SCALE_STATE_DIR/density-scale-$POOL"
mkdir -p "$EVIDENCE"
SUMMARY_JSON="$EVIDENCE/summary.json"
LOG="$EVIDENCE/e2e.log"
log(){ printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }

# ---- Phase 0: cleanup gate ----
existing=$(oc get vm,vmbackup,vmbackuptracker,pvc,svc,dv -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if (( existing > 0 )); then
  if [[ "$KEEP" == true ]]; then
    log "CLEANUP: --keep given with $existing existing objects — refusing (skill rule 1)"
    exit 2
  fi
  log "CLEANUP: wiping $existing objects from previous run"
  oc delete vmbackup,vmbackuptracker,vm,dv,pvc,svc -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1
  # vmbackup finalizer stall is the known 4-hop chain; force after drain
  sleep 90
  oc get vmbackup -n "$NAMESPACE" -o name 2>/dev/null | while read -r vb; do
    oc patch -n "$NAMESPACE" "$vb" --type=json \
      -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  done
  sleep 60
  oc delete vmbackup,vmbackuptracker,vm,dv,pvc,svc -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1 || true
  # purge stale PVs so storage returns to baseline
  oc get pv -o json | jq -r '.items[] | select(.status.phase=="Released" or .status.phase=="Available") | .metadata.name' \
  | while read -r pv; do
    oc patch pv "$pv" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
    oc delete pv "$pv" --wait=false >/dev/null 2>&1 || true
  done
  sleep 30
fi
stale=$(oc get pv --no-headers 2>/dev/null | grep -cE 'Released|Available' || true)
(( stale == 0 )) || log "WARN: $stale stale PVs remain (deletion async)"
# orphan RBD images (PV objects gone, image survived) waste raw capacity — GC them
bash "$ROOT_DIR/cbt-scale/scale-pool-gc.sh" --delete 2>&1 | tee -a "$LOG" || log "WARN: scale-pool-gc failed (see above)"
bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "pre-setup-$POOL" 2>&1 | tail -1 | tee -a "$LOG"

# ---- Phase 1: pool creation ----
log "SETUP: creating $COUNT $OS VMs (pool $POOL)"
set -a; . ./.env 2>/dev/null || true; set +a
# VM_OS/POOL go to make as ARGUMENTS: `.env` (VM_OS=rhel9) overrides env vars in make
setup_env=(VM_OS="$OS" POOL="$POOL" DENSITY_VM_COUNT="$COUNT" DENSITY_INCREMENTAL_PASSES=1
           DENSITY_QPS=50 DENSITY_WAIT_MINUTES="$(( COUNT / 4 + 60 ))")
[[ "$OS" == "windows" ]] && setup_env+=(GUEST_EXEC_POLL_ATTEMPTS=450)
if ! make density-setup "${setup_env[@]}" "${MANIFEST_ARGS[@]}" >>"$LOG" 2>&1; then
  log "SETUP: FAILED (see $LOG)"; exit 1
fi
ready=$(oc get vm -n "$NAMESPACE" -o json | jq '[.items[]|select(.status.ready==true)]|length')
log "SETUP: ready $ready/$COUNT"
(( ready == COUNT )) || { log "SETUP: not all VMs ready"; exit 1; }
bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "post-setup-$POOL" 2>&1 | tail -1 | tee -a "$LOG"

# ---- Phase 2: driver phases A-D ----
log "DRIVER: starting (backup SC $BACKUP_SC, wave $WAVE)"
T0=$(date +%s)
driver_env=()
if [[ "$OS" == "rhel9-light" ]]; then
  driver_env=(FULL_DEST_SIZE="${RHEL_LIGHT_FULL_BACKUP_SIZE:-12Gi}" INCR_DEST_SIZE="${RHEL_LIGHT_INCREMENTAL_PVC_SIZE:-2Gi}")
fi
if ! env ${driver_env[@]+"${driver_env[@]}"} EVIDENCE_DIR="$EVIDENCE" BACKUP_SC="$BACKUP_SC" \
     bash "$ROOT_DIR/cbt-scale/scale-driver2.sh" "$POOL" 1 "$COUNT" "$WAVE" >>"$LOG" 2>&1; then
  log "DRIVER: nonzero exit (see $LOG) — continuing to validation"
fi
FULL_WALL=$(grep -m1 "full phase wall" "$LOG" | grep -o '[0-9]*s' | tr -d s || true)
INCR_WALL=$(grep -m1 "incr phase wall" "$LOG" | grep -o '[0-9]*s' | tr -d s || true)

# ---- Phase 3: live-cluster validation (authoritative, not driver logs) ----
# Known driver artifact: windows pools have no vm-ssh Service, so the driver
# marks workload FAILED; backups themselves are judged from cluster state.
full_fail=$(oc get vmbackup -n "$NAMESPACE" -o json | jq \
  '[.items[] | select(.metadata.name|startswith("vm-backup-")) |
    .status.conditions[]? | select(.type=="Done") |
    select(.reason|startswith("Backup has failed"))] | length')
incr_fail=$(oc get vmbackup -n "$NAMESPACE" -o json | jq \
  '[.items[] | select(.metadata.name|startswith("vm-incremental-")) |
    .status.conditions[]? | select(.type=="Done") |
    select(.reason|startswith("Backup has failed"))] | length')
full_ok=$(oc get vmbackup -n "$NAMESPACE" -o json | jq \
  '[.items[] | select(.metadata.name|startswith("vm-backup-")) |
    .status.conditions[]? | select(.type=="Done" and .status=="True")] | length')
incr_ok=$(oc get vmbackup -n "$NAMESPACE" -o json | jq \
  '[.items[] | select(.metadata.name|startswith("vm-incremental-")) |
    .status.conditions[]? | select(.type=="Done" and .status=="True")] | length')
tracker_ok=$(oc get vmbackuptracker -n "$NAMESPACE" -o json | jq \
  --arg p "vm-incremental-$POOL-" \
  '[.items[] | select(.status.latestCheckpoint.name // "" | startswith($p))] | length')
bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "post-backup-$POOL" 2>&1 | tail -1 | tee -a "$LOG"

VERDICT=PASS
(( full_ok == COUNT && incr_ok == COUNT && tracker_ok == COUNT && full_fail == 0 && incr_fail == 0 )) || VERDICT=FAIL

# ---- Phase 4: summary ----
jq -n \
  --arg pool "$POOL" --arg os "$OS" --argjson count "$COUNT" \
  --arg backup_sc "$BACKUP_SC" --arg wave "$WAVE" \
  --argjson full_ok "$full_ok" --argjson incr_ok "$incr_ok" \
  --argjson tracker_ok "$tracker_ok" \
  --argjson full_fail "$full_fail" --argjson incr_fail "$incr_fail" \
  --arg verdict "$VERDICT" \
  --arg full_wall "${FULL_WALL:-null}s" --arg incr_wall "${INCR_WALL:-null}s" \
  --arg evidence "$EVIDENCE" \
  '{pool:$pool, os:$os, count:$count, backup_sc:$backup_sc, wave:$wave,
    incr_profile:"light",
    verdict:$verdict,
    full_ok:$full_ok, incr_ok:$incr_ok, tracker_ok:$tracker_ok,
    full_failed:$full_fail, incr_failed:$incr_fail,
    full_wall:$full_wall, incr_wall:$incr_wall,
    evidence_dir:$evidence,
    note:"rhel: workload+backups validated end to end. windows: backups+trackers validated; guest workload step is a driver artifact (no vm-ssh Service on windows pools) — incr sizes are CBT overhead only."}' \
  | tee "$SUMMARY_JSON"
log "DONE verdict=$VERDICT full=$full_ok/$COUNT incr=$incr_ok/$COUNT trackers=$tracker_ok/$COUNT"
[[ "$VERDICT" == PASS ]]
