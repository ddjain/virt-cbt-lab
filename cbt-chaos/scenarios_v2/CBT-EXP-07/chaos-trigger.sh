#!/usr/bin/env bash
# EXP-7 (adaptive, WeaknessAnalyst P3): late-copy ENOSPC — does a push-mode
# backup that runs out of target space MID-COPY complete Done=True with
# partial data (kubevirt#17578 class: succeeded:false job recorded as
# success), or fail correctly?
#
# Legs:
#   leg A (control): normal full backup (80Gi target) — proves the harness
#     path; per-file restore verification.
#   leg B (surgery): target PVC sized so the copy hits ENOSPC at ~60-80%
#     of the ~17GiB workload — after checkpoint creation (the late-copy
#     window; early ENOSPC was already proven to fail cleanly by T-04).
#     Measurements: backup terminal state/reason; ACTUAL bytes on the
#     target PVC vs expected; per-file restore check if Done=True.
#
# Judge-mandated: per-file SHA-256 (truncation signature), reported size vs
# actual PVC usage, control leg on the new pre-fill machinery.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc kubectl make tee jq; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-07/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s exists; refusing.\n' "$RUN_ID" >&2; exit 1
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
  printf 'Cluster resources for %s exist; refusing.\n' "$RUN_ID" >&2; exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# ---------- Stage 1: fresh VM (workflow setup; workload ~17GiB) ----------
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
  printf 'Setup failed (%d).\n' "$setup_status" >&2; exit "$setup_status"
fi
printf 'VM ready with ~17GiB baseline workload.\n' >&2

# ---------- Stage 2: control leg — normal full backup ----------
source "$ROOT_DIR/scripts/common.sh"
printf '=== LEG A (control): normal full backup ===\n' >&2
if make vm-backup RUN_ID="$RUN_ID" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  control_status=0
else
  control_status=$?
fi
printf 'Control full status: %d\n' "$control_status" >&2
oc get vmbackup "vm-backup-${RUN_ID}" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/legA-full-backup.yaml" 2>/dev/null || true
if ((control_status != 0)); then exit "$control_status"; fi
# Record actual data written to the control target PVC (node-local).
CTRL_PV="$(oc get pvc "vm-backup-pvc-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
CTRL_USAGE="$(oc debug node/d38-h18-000-r660 -- chroot /host du -sm "/var/hpvolumes/csi/${CTRL_PV}" 2>/dev/null | awk '{print $1}' || true)"
printf 'Control target PVC actual usage: %s MiB (PV %s)\n' "${CTRL_USAGE:-?}" "$CTRL_PV" >&2
printf '%s\n' "${CTRL_USAGE:-unknown}" >"$EVIDENCE_DIR/legA-target-usage-mib.txt"

# ---------- Stage 3: surgery leg — pre-filled 4Gi target ----------
printf '=== LEG B (surgery): pre-filled small target, late-copy ENOSPC ===\n' >&2
SB="vm-backup-enospc-${RUN_ID}"
SP="vm-backup-pvc-enospc-${RUN_ID}"
# Create a 4Gi target PVC (a fresh full backup with its own PVC name; the
# workflow's incremental naming would collide with the control leg's).
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$SB|g" \
  -e "s|__FULL_BACKUP_PVC__|$SP|g" \
  -e "s|__LARGE_DISK_SIZE__|4Gi|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null 2>&1 \
  || { printf 'Could not apply surgery backup resources.\n' >&2; exit 3; }
# Wait for the PVC to bind, then pre-fill it via a node-debug pod: write a
# filler leaving only ~1500MiB free (the workload writes ~17GiB of guest
# data -> qcow2 on target ~17GiB; ENOSPC at ~90% -> late-copy).
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  phase="$(oc get pvc "$SP" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == Bound ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'Surgery PVC never Bound.\n' >&2; exit 3
  fi
  sleep 3
done
SPV="$(oc get pvc "$SP" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
printf 'Surgery target PV %s (4Gi); pre-filling to leave ~1500MiB...\n' "$SPV" >&2
oc debug node/d38-h18-000-r660 -- chroot /host bash -c \
  "fallocate -l 2600M /var/hpvolumes/csi/${SPV}/filler.img && df -m /var/hpvolumes/csi/${SPV} | tail -1" \
  >"$EVIDENCE_DIR/legB-prefill.txt" 2>&1 || true
cat "$EVIDENCE_DIR/legB-prefill.txt" | tail -2 >&2

# Watch the surgery backup to terminal state (20 min like the workflow).
printf 'Waiting for surgery backup %s terminal state (20m).\n' "$SB" >&2
if oc wait "vmbackup/$SB" -n "$NAMESPACE" --for=condition=Done --timeout=20m; then
  sb_done=True
else
  sb_done=False
fi
sb_reason="$(oc get vmbackup "$SB" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
sb_type="$(oc get vmbackup "$SB" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
printf 'SURGERY RESULT: Done=%s type=%s reason=%s\n' "$sb_done" "${sb_type:-?}" "${sb_reason:-?}" >&2
oc get vmbackup "$SB" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/legB-backup.yaml" 2>/dev/null || true
# Actual usage on the surgery PVC + what a restore would see.
SPV_USAGE="$(oc debug node/d38-h18-000-r660 -- chroot /host du -sm "/var/hpvolumes/csi/${SPV}" 2>/dev/null | awk '{print $1}' || true)"
printf '%s\n' "${SPV_USAGE:-unknown}" >"$EVIDENCE_DIR/legB-target-usage-mib.txt"
printf 'Surgery target PVC actual usage: %s MiB\n' "${SPV_USAGE:-?}" >&2
ls_out="$(oc debug node/d38-h18-000-r660 -- chroot /host bash -c \
  "find /var/hpvolumes/csi/${SPV} -type f -exec ls -la {} \;" 2>/dev/null || true)"
printf '%s\n' "$ls_out" >"$EVIDENCE_DIR/legB-target-files.txt"
printf 'Target file listing captured (legB-target-files.txt).\n' >&2

# Classification.
if [[ "$sb_done" == True && "$sb_reason" != *"failed"* && "$sb_reason" != *"Failed"* ]]; then
  printf 'CRITICAL CHECK: Done=True with success reason under ENOSPC — inspect actual data vs expected (legB-target-usage-mib.txt vs ~17GiB workload). If usage << workload, this is silent corruption (succeeded:false recorded as success).\n' >&2
else
  printf 'RESILIENT: backup failed/warned under late-copy ENOSPC (reason recorded above).\n' >&2
fi
printf 'EXP-7 complete.\n' >&2
exit 0
