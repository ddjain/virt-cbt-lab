#!/usr/bin/env bash
# EXP-2 (adaptive): delete the full-backup CustomResource mid-copy —
# push-mode abort semantics. Source-derived hypotheses:
#   - CR deletion mid-copy triggers Abort cmd -> DOMAIN_JOB_CANCELLED ->
#     backup marked Failed; finalizer must be removed for the object to go.
#   - If the abort API call succeeds but the cancel event is lost, the CR
#     may hang with a stuck finalizer.
#   - The hotplugged target PVC is detached only by controller cleanup; if
#     cleanup races the deletion, the volume can stay attached (leak).
#   - Partial .qcow2 files may remain on the target PVC (cleanup only
#     removes the backup dir when BackupBegin itself fails).
#   - Freeze/thaw wraps BackupBegin; by mid-copy the guest is already
#     thawed — deletion at copy N% verifies the VM stays healthy.
# Measurements: CR deletion velocity (finalizer removal), VMI conditions
# (frozen? healthy?), hotplug attachment state, target-PVC residue, tracker
# checkpoint retention, and same-VM recovery via a fresh-named full backup.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc jq make tee; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
MIDCOPY_DELAY_SECONDS="${MIDCOPY_DELAY_SECONDS:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
VMI_NAME="$VM_NAME"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-02/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing.\n' "$RUN_ID" >&2; exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing.\n' "$RUN_ID" >&2; exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Evidence path not a directory; refusing.\n' "$RUN_ID" >&2; exit 1
fi
existing="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume -n "$NAMESPACE" -o name 2>/dev/null)"
if [[ "$existing" == *"$RUN_ID"* ]]; then
  printf 'Cluster resources for %s already exist; refusing.\n' "$RUN_ID" >&2; exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# ---------- Stage 1: fresh VM (setup only — no backup yet) ----------
# vm-setup creates the VM, disk, service, and baseline workload and writes
# runs/<RUN_ID>/run.json; the backup is created manually in stage 2 so it
# can be deleted mid-copy (make e2e TYPE=full would wait for Done).
if make vm-setup RUN_ID="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  setup_status=0
else
  setup_status=$?
fi
if ((setup_status != 0)); then
  printf 'Setup stage failed (%d); aborting.\n' "$setup_status" >&2
  exit "$setup_status"
fi
printf 'VM ready with baseline workload; creating full backup to delete mid-copy.\n' >&2

# ---------- Stage 2: create the backup (workflow-identical mechanism) ----
# Same manifest templating as scripts/vm-backup.sh (PVC + tracker + backup
# applied in one manifest).
source "$ROOT_DIR/scripts/common.sh"
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$FULL_BACKUP_NAME|g" \
  -e "s|__FULL_BACKUP_PVC__|$FULL_BACKUP_PVC_NAME|g" \
  -e "s|__LARGE_DISK_SIZE__|$LARGE_MANIFEST_DISK_SIZE|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null
backup_created_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Backup %s created at %s; waiting for active copy (Progressing=True).\n' \
  "$FULL_BACKUP_NAME" "$backup_created_utc" >&2
# Wait for the active copy (same compound condition as F-09).
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  progress="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
  done_status="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
  [[ "$progress" == True && "$done_status" != True ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'Backup never reached active copy within 300s.\n' >&2
    exit 4
  fi
  sleep 1
done
copy_started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Active copy confirmed at %s. Waiting %ss (mid-copy), then deleting the backup CR.\n' \
  "$copy_started_utc" "$MIDCOPY_DELAY_SECONDS" >&2
sleep "$MIDCOPY_DELAY_SECONDS"
# Verify still in copy (not already Done) at deletion time.
done_status="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
if [[ "$done_status" == True ]]; then
  printf 'Backup already Done before deletion (copy finished early); harness-invalid.\n' >&2
  exit 4
fi
delete_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'UTC action request: delete vmbackup %s mid-copy at %s.\n' \
  "$FULL_BACKUP_NAME" "$delete_requested_utc" >&2
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/backup-pre-delete.yaml"
oc delete vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE"

# ---------- Stage 3: observe abort semantics ----------
# Deletion velocity: how long until the object is gone (finalizer removed)?
stuck=0
gone_deadline=$(( $(date -u +%s) + 300 ))
while oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; do
  if (( $(date -u +%s) > gone_deadline )); then
    printf 'STUCK FINALIZER: backup CR still present 300s after deletion request.\n' >&2
    oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/backup-stuck.yaml" || true
    stuck=1
    break
  fi
  sleep 2
done
if ((stuck != 1)); then
  printf 'Backup CR gone (finalizer removed) %ss after deletion request.\n' \
    "$(( $(date -u +%s) - $(date -u -d "$delete_requested_utc" +%s) ))" >&2
fi
# VMI state after abort: healthy? frozen? volume detached?
sleep 5
oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vmi-after-abort.yaml"
vmi_phase="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
frozen="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || true)"
printf 'VMI after abort: phase=%s paused=%s\n' "${vmi_phase:-unknown}" "${frozen:-none}" >&2
# Hotplug target PVC: still attached to the launcher?
attached="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o json \
  | jq -r --arg pvc "$FULL_BACKUP_PVC_NAME" \
    '.status.volumeStatus[]? | select(.name | contains($pvc)) | .name' 2>/dev/null | head -1 || true)"
printf 'Hotplug target PVC attachment after abort: %s\n' "${attached:-detached-or-unknown}" >&2
# Tracker state: checkpoint retained (should be empty for a failed first backup)?
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker-after-abort.yaml" || true
tracker_ckpt="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint}' 2>/dev/null || true)"
printf 'Tracker after abort: latestCheckpoint=%s\n' "${tracker_ckpt:-none}" >&2
# Target PVC contents: partial qcow2 residue (node-local path listing).
oc debug node/d38-h18-000-r660 -- chroot /host bash -c \
  "find /var/hpvolumes/cbt-demo-local-pool -maxdepth 6 -path '*${RUN_ID}*' -size +0 2>/dev/null | head -20" \
  >"$EVIDENCE_DIR/target-pvc-residue.txt" 2>&1 || true
printf 'Target PVC residue listing captured.\n' >&2

# ---------- Stage 4: same-VM recovery oracle ------------------------------
# The workflow's recovery stage creates a fresh-named full backup
# (vm-recovery-full-<RUN_ID>-<attempt>) through the existing tracker on the
# SAME VM, waits for Done, and restore-verifies it.
if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  recover_status=0
else
  recover_status=$?
fi
printf 'Recovery (same-VM fresh-named full backup) status: %d\n' "$recover_status" >&2
oc get vmbackup -n "$NAMESPACE" -o name | grep "$RUN_ID" \
  >"$EVIDENCE_DIR/backups-after-recovery.txt" || true
if ((stuck == 1)); then
  printf 'ABORT DEFECT SIGNAL: stuck finalizer observed.\n' >&2
fi
exit "$recover_status"
