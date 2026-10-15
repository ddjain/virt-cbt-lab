#!/usr/bin/env bash
# EXP-8 (P2-r1 compact): delete the backup TRACKER mid-copy — second entry
# path to the no-deadline wedge (source: updateBackupTracker 404 → infinite
# requeue). Judge-mandated: (i) trigger on OBSERVED copy start (watch
# Progressing=True), not wall clock; (ii) fail-closed tracker-deletion proof
# (GET 404) + capture the controller's updateBackupTracker-404 log line;
# (iii) recovery leg: delete the wedged backup CR, then fresh-named backup —
# does the controller RECREATE the tracker, and does the fresh backup
# complete with consistent checkpoint state; (iv) pre-registered alternative
# criterion: if the backup COMPLETES despite the deletion, classify the
# tracker's post-state (recreated silently? chain intact?).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then printf 'Bad RUN_ID\n' >&2; exit 2; fi
for command in oc kubectl make tee jq; do
  command -v "$command" >/dev/null || { printf 'Missing %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-08/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then printf 'Run exists\n' >&2; exit 1; fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Evidence exists\n' >&2; exit 1
  fi
fi
existing="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume -n "$NAMESPACE" -o name 2>/dev/null)"
if [[ "$existing" == *"$RUN_ID"* ]]; then printf 'Cluster resources exist\n' >&2; exit 1; fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
source "$ROOT_DIR/scripts/common.sh"

# ---------- Stage 1: fresh VM (setup only) ----------
if make vm-setup RUN_ID="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT=1000 GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20 \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  setup_status=0
else
  setup_status=$?
fi
if ((setup_status != 0)); then exit "$setup_status"; fi

# ---------- Stage 2: create backup; delete TRACKER on observed copy start ----------
printf '=== INJECTION LEG: tracker deleted at observed copy start +15s ===\n' >&2
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$FULL_BACKUP_NAME|g" \
  -e "s|__FULL_BACKUP_PVC__|vm-backup-pvc-${RUN_ID}|g" \
  -e "s|__LARGE_DISK_SIZE__|80Gi|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null
# Watcher: on OBSERVED Progressing=True (copy started), wait 15s (mid-copy,
# copy runs ~53s), then delete the tracker; fail-closed verify 404.
(
  deadline=$(( $(date -u +%s) + 900 ))
  while :; do
    progress="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
    [[ "$progress" == True ]] && break
    if (( $(date -u +%s) > deadline )); then echo "watcher-timeout" >"$EVIDENCE_DIR/inject-result.txt"; exit 9; fi
    sleep 1
  done
  printf 'Copy start observed at %s; holding 15s (mid-copy).\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  sleep 15
  printf 'UTC action request: delete tracker %s at %s (copy in progress).\n' \
    "$TRACKER_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  oc delete vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" || true
  sleep 3
  if oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "deletion-failed" >"$EVIDENCE_DIR/inject-result.txt"; exit 9
  fi
  echo "tracker-deleted-404-verified" >"$EVIDENCE_DIR/inject-result.txt"
) &
watcher_pid=$!
# Wait for the backup to settle (Done or stuck): poll up to 15 min.
deadline=$(( $(date -u +%s) + 900 ))
while :; do
  done_status="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
  [[ "$done_status" == True || "$done_status" == False && -n "$done_status" ]] && : ;
  if [[ "$done_status" == True ]]; then outcome=completed; break; fi
  # Pre-registered stuck criteria: >10min no terminal + we check controller logs after.
  if (( $(date -u +%s) > deadline )); then outcome=stuck; break; fi
  sleep 10
done
wait "$watcher_pid" || true
inject_result="$(cat "$EVIDENCE_DIR/inject-result.txt" 2>/dev/null || echo missing)"
printf 'Injection result: %s; backup outcome: %s\n' "$inject_result" "$outcome" >&2
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/backup-final.yaml" || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker-final.yaml" 2>/dev/null || echo "tracker absent" >"$EVIDENCE_DIR/tracker-final.yaml"
LEADER="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$LEADER" -n openshift-cnv --since=20m >"$EVIDENCE_DIR/controller-window.log" 2>/dev/null || true
printf 'Controller log captured (controller-window.log; grep for tracker 404/requeue).\n' >&2

# ---------- Stage 3: recovery leg (Judge iii) ----------
printf '=== RECOVERY: delete the backup CR, then fresh-named backup ===\n' >&2
if [[ "$outcome" == stuck ]]; then
  oc delete vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" || true
  deadline=$(( $(date -u +%s) + 300 ))
  while oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; do
    if (( $(date -u +%s) > deadline )); then printf 'CR deletion stuck.\n' >&2; break; fi
    sleep 5
  done
fi
RB="vm-recovery-full-${RUN_ID}-r1"
RP="vm-recovery-pvc-${RUN_ID}-r1"
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$RB|g" \
  -e "s|__FULL_BACKUP_PVC__|$RP|g" \
  -e "s|__LARGE_DISK_SIZE__|80Gi|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null
if oc wait "vmbackup/$RB" -n "$NAMESPACE" --for=condition=Done --timeout=15m; then
  rec_done=True
else
  rec_done=False
fi
rec_type="$(oc get vmbackup "$RB" -n "$NAMESPACE" -o jsonpath='{.status.type}')"
rec_reason="$(oc get vmbackup "$RB" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
tracker_recreated=no
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" >/dev/null 2>&1 && tracker_recreated=yes
printf 'RECOVERY: fresh backup Done=%s type=%s reason=%s; tracker recreated: %s\n' \
  "$rec_done" "$rec_type" "$rec_reason" "$tracker_recreated" >&2
oc get vmbackup "$RB" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/recovery-backup.yaml" || true
printf 'EXP-8 complete. Classifications: outcome=%s inject=%s recovery(done/type/tracker-recreated)=%s/%s/%s\n' \
  "$outcome" "$inject_result" "$rec_done" "$rec_type" "$tracker_recreated" >&2
exit 0
