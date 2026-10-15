#!/usr/bin/env bash
# EXP-1 continuation (r01b): the r01 attempt created a clean full backup
# (vm-backup-20261014-exp01-r01 Done, checkpoint recorded) but died at the
# VMI_NAME unbound-variable bug before the restart stage. This script runs
# ONLY stages 2-3 (restart + incremental + classification) against the
# existing lifecycle 20261014-exp01-r01. Same experiment, same hypothesis;
# evidence continues in runs/20261014-exp01-r01/.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"
RUN_ID=20261014-exp01-r01
KUBECONFIG_PATH=/root/mno/kubeconfig
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE=vm-cbt-demo
VM_NAME="vm-${RUN_ID}"
VMI_NAME="$VM_NAME"
TRACKER_NAME="vm-tracker-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-01/runs/$RUN_ID"
for command in oc jq make tee; do
  command -v "$command" >/dev/null || { printf 'Missing %s\n' "$command" >&2; exit 2; }
done
# Preconditions: full backup terminal-successful, tracker exists, VMI running.
full_done="$(oc get vmbackup "vm-backup-${RUN_ID}" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
if [[ "$full_done" != True ]]; then
  printf 'Precondition failed: full backup not Done=True (%s).\n' "${full_done:-missing}" >&2
  exit 3
fi
if ! oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'Precondition failed: tracker missing.\n' >&2; exit 3
fi
[[ -d "$EVIDENCE_DIR" ]] || { printf 'Evidence dir missing.\n' >&2; exit 3; }
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
full_duration="$(jq -r '.backups.full.duration_seconds' "$ROOT_DIR/runs/$RUN_ID/run.json")"
old_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
old_pod="$(oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=${VM_NAME}" -o jsonpath='{.items[0].metadata.name}')"
printf 'Continuation r01b: full backup already clean (checkpoint=%s duration=%ss); VMI uid=%s pod=%s\n' \
  "$full_checkpoint" "$full_duration" "$old_uid" "$old_pod" >&2

# ---------- Stage 2: hard VM restart ----------
restart_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'UTC action request: delete VMI %s (hard restart) at %s; tracker latestCheckpoint=%s\n' \
  "$VMI_NAME" "$restart_requested_utc" \
  "$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint}')" >&2
oc delete vmi "$VMI_NAME" -n "$NAMESPACE"
redefine_start="$(date -u +%s)"
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
printf 'VMI recreated: new uid=%s Running at %s (restart-to-running %ss).\n' \
  "$new_uid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( $(date -u +%s) - redefine_start ))" >&2
oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vmi-after-restart.yaml"
cbt_state="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
printf 'CBT state after restart: %s\n' "${cbt_state:-unknown}" >&2
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
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker-after-restart.yaml"
redefine_flag="$(grep -c 'checkpointRedefinitionRequired: true' "$EVIDENCE_DIR/tracker-after-restart.yaml" || true)"
printf 'Tracker after restart: checkpointRedefinitionRequired-true hits=%s; latestCheckpoint=%s\n' \
  "$redefine_flag" \
  "$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint}')" >&2

# ---------- Stage 3: incremental pass on the restarted VM ----------
printf 'Starting incremental pass on the restarted VM (checkpoint chain must survive the restart).\n' >&2
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS=rhel9 MANIFEST_VARIANT=default KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
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
if [[ "$incr_type" == Full ]]; then
  printf 'DEGRADATION SIGNAL: p01 fell back to type=Full after the VM restart (silent full fallback).\n' >&2
fi
if ((incr_status != 0)); then exit "$incr_status"; fi
printf 'Experiment EXP-1 complete (continuation r01b).\n' >&2
exit 0
