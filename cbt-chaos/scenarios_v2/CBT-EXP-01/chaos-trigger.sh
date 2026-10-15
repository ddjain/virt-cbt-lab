#!/usr/bin/env bash
# EXP-1 (adaptive): VM restart between full backup and incremental pass —
# exercises the checkpoint-redefinition path (virt-handler sets
# checkpointRedefinitionRequired on VMI restart while a checkpoint exists;
# the controller re-derives/redefines the checkpoint in libvirt and probes
# each disk for a usable bitmap; failure modes under test: tracker stuck in
# redefinition, silent fall-back to full, checkpoint cleared, or an
# incremental that no longer covers the full data set).
#
# Stages: fresh VM + full backup (clean) → HARD restart the VM (delete VMI so
# virt-launcher is recreated; tracker carries latestCheckpoint across it) →
# wait for VMI Running + CBT Enabled → mutation → incremental pass →
# verification (type must remain Incremental + chain + restore hashes).
# Degradation signals: type=Full on p01 (silent full fallback), tracker stuck
# (checkpointRedefinitionRequired not cleared / incremental blocked), long
# redefinition delay, restore mismatches.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc jq make tee kubectl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
VM_NAME="vm-${RUN_ID}"
VMI_NAME="$VM_NAME"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-01/runs/$RUN_ID"
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing.\n' "$RUN_ID" >&2
    exit 1
  fi
  unexpected_observer_content="$(find "$EVIDENCE_DIR/observer" -mindepth 1 \
    \( -name trigger.log \) -print -quit)"
  if [[ -n "$unexpected_observer_content" ]]; then
    printf 'Run ID %s observer already contains run artifacts; refusing.\n' "$RUN_ID" >&2
    exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Run ID %s evidence path is not a directory; refusing.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing.\n' "$RUN_ID" >&2; exit 1
fi
existing="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume -n "$NAMESPACE" -o name 2>/dev/null)"
if [[ "$existing" == *"$RUN_ID"* ]]; then
  printf 'Cluster resources for %s already exist; refusing.\n' "$RUN_ID" >&2; exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# ---------- Stage 1: clean full backup ----------
if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  full_status=0
else
  full_status=$?
fi
if ((full_status != 0)); then
  printf 'Full stage failed (%d); aborting experiment.\n' "$full_status" >&2
  exit "$full_status"
fi
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
full_duration="$(jq -r '.backups.full.duration_seconds' "$ROOT_DIR/runs/$RUN_ID/run.json")"
old_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
old_pod="$(oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=${VM_NAME}" -o jsonpath='{.items[0].metadata.name}')"
printf 'Full backup clean: checkpoint=%s duration=%ss; VMI uid=%s pod=%s\n' \
  "$full_checkpoint" "$full_duration" "$old_uid" "$old_pod" >&2

# ---------- Stage 2: hard VM restart (delete VMI; VM object recreates it) ----------
restart_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'UTC action request: delete VMI %s (hard restart) at %s; tracker latestCheckpoint=%s\n' \
  "$VMI_NAME" "$restart_requested_utc" \
  "$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint}')" >&2
oc delete vmi "$VMI_NAME" -n "$NAMESPACE"
redefine_start="$(date -u +%s)"
# Wait for the new VMI to exist and reach Running.
deadline=$((redefine_start + 900))
while :; do
  new_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  phase="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ -n "$new_uid" && "$new_uid" != "$old_uid" && "$phase" == Running ]]; then break; fi
  if (( $(date -u +%s) > deadline )); then
    printf 'New VMI did not reach Running within 900s (uid=%s phase=%s).\n' "${new_uid:-none}" "${phase:-none}" >&2
    exit 5
  fi
  sleep 3
done
running_after_restart="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'VMI recreated: new uid=%s Running at %s (restart-to-running %ss).\n' \
  "$new_uid" "$running_after_restart" "$(( $(date -u +%s) - redefine_start ))" >&2
# Observe checkpointRedefinitionRequired on the VMI (may be transient).
oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vmi-after-restart.yaml"
cbt_state="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
printf 'CBT state after restart: %s\n' "${cbt_state:-unknown}" >&2
# Wait for CBT Enabled (redefinition must settle before an incremental can work).
cbt_deadline=$(( $(date -u +%s) + 300 ))
while :; do
  cbt_state="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
  [[ "$cbt_state" == Enabled ]] && break
  if (( $(date -u +%s) > cbt_deadline )); then
    printf 'CBT did not return to Enabled within 300s after restart (state=%s).\n' "${cbt_state:-none}" >&2
    oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vmi-cbt-not-enabled.yaml" || true
    break
  fi
  sleep 3
done
tracker_yaml_after="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml)"
printf '%s\n' "$tracker_yaml_after" >"$EVIDENCE_DIR/tracker-after-restart.yaml"
redefine_flag="$(printf '%s\n' "$tracker_yaml_after" | grep -c 'checkpointRedefinitionRequired: true' || true)"
printf 'Tracker after restart: checkpointRedefinitionRequired-true hits=%s; latestCheckpoint=%s\n' \
  "$redefine_flag" \
  "$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint}')" >&2

# ---------- Stage 3: incremental pass on the restarted VM ----------
printf 'Starting incremental pass on the restarted VM (checkpoint chain must survive the restart).\n' >&2
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
incr_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
incr_checkpoint="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
incr_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
incr_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
incr_duration="$(jq -r '.backups.incremental_passes[0].duration_seconds // empty' \
  "$ROOT_DIR/runs/$RUN_ID/run.json" 2>/dev/null || true)"
printf 'INCREMENTAL RESULT: type=%s Done=%s reason=%s checkpoint=%s duration=%ss (full control: %ss).\n' \
  "${incr_type:-unknown}" "${incr_done:-unknown}" "${incr_reason:-unknown}" \
  "${incr_checkpoint:-unknown}" "${incr_duration:-unknown}" "$full_duration" >&2
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/incremental-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker-final.yaml" 2>/dev/null || true
oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vmi-final.yaml" 2>/dev/null || true

# ---------- Classification ----------
if [[ "$incr_type" == Full ]]; then
  printf 'DEGRADATION SIGNAL: p01 fell back to type=Full after the VM restart (silent full fallback; incremental chain not preserved).\n' >&2
fi
if ((incr_status != 0)); then
  printf 'Incremental stage failed; preserving evidence for classification.\n' >&2
  exit "$incr_status"
fi
printf 'Experiment complete: restart between full and incremental executed; classification above (type/chain/restore in run report).\n' >&2
exit 0
