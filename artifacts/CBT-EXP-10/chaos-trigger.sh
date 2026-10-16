#!/usr/bin/env bash
# EXP-10 (P5, closeout gate): non-422 redefinition error → infinite requeue
# wedging ALL backups on the tracker (cross-backup blast radius).
# Source (kubevirt v1.8.4): handleRedefinitionError clears the checkpoint
# ONLY on string-matched "422 Unprocessable Entity" errors; any other error
# shape requeues forever while checkPrerequisites holds new backups in
# Initializing ("Waiting for checkpoint redefinition").
#
# Design (Judge-mitigated):
#   1. Fresh HostPath-variant VM + full backup (checkpoint established).
#   2. Stop the VM, delete the VMI, restart it -> checkpointRedefinitionRequired
#      set at VMI start (redefinition window opens).
#   3. In that window: SIGTERM virt-handler on the VM's node (krkn container-
#      scenarios --action 1 per krknctl-bugs.md #8, or direct pod delete —
#      handler is a daemonset, restart is bounded, VMIs keep running).
#      The redefinition call (controller -> virt-handler subresource) fails
#      with a CONNECTION error (non-422 shape) -> exercises the string-match
#      branch -> potential infinite requeue.
#   4. Named primary criterion: after handler recovery, does the tracker
#      clear redefinition-required, and does a SECOND fresh-named backup on
#      the SAME tracker wedge (cross-backup blast radius)?
#   5. Recovery via the proven matrix if wedged (tracker deletion -> fresh
#      full -> restore-verify), leaving the VM healthy.
# Mitigations: handler logs captured BEFORE restart; fail-closed restart
# verification (new pod start time); time-boxed stop if handler not Ready
# in 5 min; collateral VMI watch (only 4 campaign VMIs on the node).
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
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-10/runs/$RUN_ID"
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

# ---------- Stage 1: fresh VM + full backup ----------
if make vm-setup RUN_ID="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT=1000 GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20 \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  setup_status=0
else
  setup_status=$?
fi
if ((setup_status != 0)); then exit "$setup_status"; fi
if make vm-backup RUN_ID="$RUN_ID" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  full_status=0
else
  full_status=$?
fi
if ((full_status != 0)); then exit "$full_status"; fi
printf 'Full backup complete; checkpoint established.\n' >&2

# ---------- Stage 2: restart VM (open the redefinition window) ----------
OLD_UID="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
printf 'UTC action request: delete VMI %s at %s (opens redefinition window).\n' \
  "$VM_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
oc delete vmi "$VM_NAME" -n "$NAMESPACE"

# ---------- Stage 3: SIGTERM virt-handler in the redefinition window ----------
NODE="d38-h18-000-r660"
HANDLER_POD="$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler \
  -o jsonpath="{.items[?(@.spec.nodeName==\"$NODE\")].metadata.name}")"
if [[ -z "$HANDLER_POD" ]]; then
  printf 'Could not find virt-handler on %s; aborting.\n' "$NODE" >&2; exit 6
fi
HANDLER_START_BEFORE="$(oc get pod "$HANDLER_POD" -n openshift-cnv -o jsonpath='{.status.startTime}')"
printf 'Target handler: %s (startTime %s). Capturing pre-restart logs.\n' \
  "$HANDLER_POD" "$HANDLER_START_BEFORE" >&2
oc logs "$HANDLER_POD" -n openshift-cnv --since=5m >"$EVIDENCE_DIR/handler-pre-restart.log" 2>/dev/null || true
# Wait for the new VMI to exist (redefinition window is at VMI start; the
# controller will attempt redefinition as soon as handler can serve it).
deadline=$(( $(date -u +%s) + 600 ))
while :; do
  new_uid="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ -n "$new_uid" && "$new_uid" != "$OLD_UID" && "$phase" == Running ]]; then break; fi
  if (( $(date -u +%s) > deadline )); then printf 'VMI restart timeout.\n' >&2; exit 5; fi
  sleep 2
done
printf 'VMI restarted (uid %s) — redefinition window open; killing handler NOW.\n' "$new_uid" >&2
printf 'UTC action request: SIGTERM virt-handler %s at %s (mid-redefinition-window).\n' \
  "$HANDLER_POD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
oc delete pod "$HANDLER_POD" -n openshift-cnv --wait=false
# Fail-closed: verify the handler pod actually restarted (new start time).
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  HANDLER_START_AFTER="$(oc get pod "$HANDLER_POD" -n openshift-cnv -o jsonpath='{.status.startTime}' 2>/dev/null || true)"
  if [[ -n "$HANDLER_START_AFTER" && "$HANDLER_START_AFTER" != "$HANDLER_START_BEFORE" ]]; then break; fi
  if (( $(date -u +%s) > deadline )); then
    printf 'Handler did not restart within 300s (time-box stop condition).\n' >&2
    exit 7
  fi
  sleep 5
done
printf 'Handler restarted (new startTime %s). Waiting for Ready.\n' "$HANDLER_START_AFTER" >&2
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  ready="$(oc get pod "$HANDLER_POD" -n openshift-cnv -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  [[ "$ready" == True ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'Handler not Ready within 300s (time-box stop condition).\n' >&2
    exit 7
  fi
  sleep 5
done
printf 'Handler back Ready. Observation window: 10 minutes for tracker redefinition behavior.\n' >&2

# ---------- Stage 4: observe tracker + the named criterion ----------
# Watch the tracker's checkpointRedefinitionRequired for up to 10 min.
deadline=$(( $(date -u +%s) + 600 ))
redef_state="unknown"
while :; do
  redef_state="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.checkpointRedefinitionRequired}' 2>/dev/null || echo missing)"
  if [[ "$redef_state" == false ]]; then
    printf 'Tracker redefinition cleared (checkpointRedefinitionRequired=false) at %s.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    redef_outcome=cleared
    break
  fi
  if (( $(date -u +%s) > deadline )); then
    printf 'Tracker redefinition NOT cleared after 10 min (state=%s) — WEDGE candidate.\n' "$redef_state" >&2
    redef_outcome=stuck
    break
  fi
  sleep 10
done
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker-final.yaml" 2>/dev/null || true
LEADER="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$LEADER" -n openshift-cnv --since=15m >"$EVIDENCE_DIR/controller-window.log" 2>/dev/null || true
oc logs "$HANDLER_POD" -n openshift-cnv --since=15m >"$EVIDENCE_DIR/handler-post-restart.log" 2>/dev/null || true

# Named primary criterion: does a SECOND fresh-named backup on the SAME
# tracker wedge (cross-backup blast radius)?
printf '=== PRIMARY CRITERION: second fresh-named backup on the same tracker ===\n' >&2
RB2="vm-p5-second-${RUN_ID}"
RP2="vm-p5-pvc-${RUN_ID}"
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$RB2|g" \
  -e "s|__FULL_BACKUP_PVC__|$RP2|g" \
  -e "s|__LARGE_DISK_SIZE__|80Gi|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null 2>&1 || true
if oc wait "vmbackup/$RB2" -n "$NAMESPACE" --for=condition=Done --timeout=10m; then
  second_done=True
else
  second_done=False
fi
second_reason="$(oc get vmbackup "$RB2" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
second_progress="$(oc get vmbackup "$RB2" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"
printf 'SECOND BACKUP: Done=%s reason=%s progressing-reason=%s\n' \
  "$second_done" "${second_reason:-?}" "${second_progress:-?}" >&2
oc get vmbackup "$RB2" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/second-backup.yaml" 2>/dev/null || true
if [[ "$second_done" != True ]]; then
  printf 'CROSS-BACKUP BLAST RADIUS CONFIRMED: second backup wedged (Done=%s, reason=%s).\n' \
    "$second_done" "${second_reason:-?}" >&2
fi

# ---------- Stage 5: recovery via the proven matrix ----------
printf '=== RECOVERY: delete wedged CRs + tracker, fresh full, restore-verify ===\n' >&2
oc delete vmbackup "$RB2" -n "$NAMESPACE" --ignore-not-found
oc delete pvc "$RP2" -n "$NAMESPACE" --ignore-not-found
oc delete vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" --ignore-not-found
if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  recover_status=0
else
  recover_status=$?
fi
printf 'Recovery status: %d (workflow recover: fresh-named full + restore-verify).\n' "$recover_status" >&2
printf 'EXP-10 complete. redefinition=%s second-backup-done=%s recovery=%d\n' \
  "$redef_outcome" "$second_done" "$recover_status" >&2
exit "$recover_status"
