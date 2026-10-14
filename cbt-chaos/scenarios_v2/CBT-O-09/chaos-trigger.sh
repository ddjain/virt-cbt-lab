#!/usr/bin/env bash
# CBT-O-09: per-volume RBD ENOSPC — pre-fill the backup destination PVC
# (I-05 r02 recipe) before backup creation, on the ODF large-odf sizing.
#
# Usage:
#   RUN_ID=20261014-cbto09-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     [TARGET=full|incremental] [FILL_SIZE_GIB=78] bash chaos-trigger.sh
#   legs: o09a TARGET=full FILL=78 | o09b TARGET=incremental FILL=29 | o09c TARGET=full FILL=70
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="odf"
VM_DATA_SOURCE_NAME="${VM_DATA_SOURCE_NAME:-rhel9-rbd}"
VM_DATA_SOURCE_NAMESPACE="openshift-virtualization-os-images"
export NAMESPACE VM_DATA_SOURCE_NAME VM_DATA_SOURCE_NAMESPACE
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TARGET="${TARGET:-full}"               # full | incremental
FILL_SIZE_GIB="${FILL_SIZE_GIB:-78}"
FILLER_IMAGE="registry.redhat.io/rhel9/toolbox:latest"
FILLER_POD_NAME="filler-${RUN_ID}"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
INCR_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p01"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-09/runs/$RUN_ID"

# --- Guards (ODF family) -------------------------------------------------------------
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
  exit 2
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Refusing to run: resources for %s already exist.\n' "$RUN_ID" >&2
  exit 2
fi
ceph_health="$(oc get cephcluster -n openshift-storage \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo '')"
if [[ "$ceph_health" != HEALTH_OK ]]; then
  printf 'Ceph cluster not HEALTH_OK (got: %s) — aborting.\n' "${ceph_health:-unavailable}" >&2
  exit 2
fi
golden_pvc="$(oc get datasource "$VM_DATA_SOURCE_NAME" -n "$VM_DATA_SOURCE_NAMESPACE" \
  -o jsonpath='{.spec.source.pvc.name}' 2>/dev/null || echo '')"
golden_sc="$(oc get pvc "$golden_pvc" -n "$VM_DATA_SOURCE_NAMESPACE" \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo '')"
if [[ "$golden_sc" != "ocs-storagecluster-ceph-rbd" ]]; then
  printf 'Golden DataSource %s not on RBD (sc=%s) — run CBT-O-01 first.\n' \
    "$VM_DATA_SOURCE_NAME" "${golden_sc:-unknown}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'O09: dest-PVC pre-fill ENOSPC (target=%s fill=%sGiB), run %s.\n' \
  "$TARGET" "$FILL_SIZE_GIB" "$RUN_ID" >&2

# --- Stage 0 (incremental leg): clean full first ---------------------------------------
if [[ "$TARGET" == incremental ]]; then
  if make e2e TYPE=full NAME="$RUN_ID" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
    GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH" \
    >"$EVIDENCE_DIR/full-stage.log" 2>&1; then
    full_rc=0
  else
    full_rc=$?
  fi
  printf 'Clean full stage rc=%s (prerequisite for the incremental leg).\n' "$full_rc" >&2
  ((full_rc == 0)) || exit "$full_rc"
  DEST_PVC="$INCR_PVC_NAME"
  DEST_BACKUP="$INCR_BACKUP_NAME"
  STAGE_MANIFEST="incremental-backup"
else
  DEST_PVC="$FULL_BACKUP_PVC_NAME"
  DEST_BACKUP="$FULL_BACKUP_NAME"
  STAGE_MANIFEST="full-backup"
fi

# --- Stage 1: pre-create the destination PVC from the stage's own template -------------
sed \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_PVC__|$FULL_BACKUP_PVC_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$FULL_BACKUP_NAME|g" \
  -e "s|__INCREMENTAL_BACKUP_PVC__|$INCR_PVC_NAME|g" \
  -e "s|__INCREMENTAL_BACKUP_NAME__|$INCR_BACKUP_NAME|g" \
  -e "s|__LARGE_DISK_SIZE__|80Gi|g" \
  "$(manifest_path "$STAGE_MANIFEST")" >"$EVIDENCE_DIR/dest-manifest-rendered.yaml"
# Split off ONLY the PVC document (record-separator split keeps apiVersion with kind).
awk -v RS='---' '/PersistentVolumeClaim/{print; exit}' \
  "$EVIDENCE_DIR/dest-manifest-rendered.yaml" | oc apply -f - >/dev/null
printf 'Pre-created destination PVC %s.\n' "$DEST_PVC" >&2
if ! oc wait "pvc/$DEST_PVC" -n "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Bound --timeout=300s 2>/dev/null; then
  printf 'Pre-created PVC did not become Bound in 5m — aborting.\n' >&2
  exit 2
fi

# --- Stage 2: fill the destination PVC --------------------------------------------------
kubectl run "$FILLER_POD_NAME" \
  --namespace "$NAMESPACE" \
  --restart=Never \
  --image="$FILLER_IMAGE" \
  --overrides "{\"spec\":{\"containers\":[{\"name\":\"filler\",\"image\":\"${FILLER_IMAGE}\",\"command\":[\"sh\",\"-c\",\"df -B1 /data | tail -1 > /fill-report.txt; fallocate -l ${FILL_SIZE_GIB}G /data/.cbt-filler && df -B1 /data | tail -1 >> /fill-report.txt; sync; cat /fill-report.txt; echo FILLER_DONE\"],\"securityContext\":{\"privileged\":true},\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"${DEST_PVC}\"}}]}}" \
  >/dev/null
printf 'UTC action request: filler %s on %s at %s.\n' \
  "$FILLER_POD_NAME" "$DEST_PVC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$EVIDENCE_DIR/injection-requested-utc.txt"
filler_phase="unknown"
for ((i = 0; i < 60; i++)); do
  filler_phase="$(oc get pod "$FILLER_POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
  [[ "$filler_phase" == Succeeded || "$filler_phase" == Failed ]] && break
  sleep 5
done
oc logs "$FILLER_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/filler-pod.log" 2>/dev/null || true
oc delete pod "$FILLER_POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
if [[ "$filler_phase" != Succeeded ]] || ! grep -q FILLER_DONE "$EVIDENCE_DIR/filler-pod.log" 2>/dev/null; then
  printf 'Filler did not Succeed (phase=%s) — aborting before backup creation.\n' "$filler_phase" >&2
  exit 2
fi
printf 'Destination pre-filled to +%sGiB (df in filler-pod.log).\n' "$FILL_SIZE_GIB" >&2
# Wait for volume release (no pod mounts the PVC) — Multi-Attach guard.
for ((i = 0; i < 30; i++)); do
  mounter="$(oc get pvc "$DEST_PVC" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/storage-provisioner}' 2>/dev/null || true)"
  va_attached="$(oc get volumeattachment -o json 2>/dev/null \
    | jq -r --arg pvc "$DEST_PVC" '.items[] | select(.spec.source.persistentVolumeName != null) | .status.attached' 2>/dev/null | head -1 || true)"
  # Simplest release check: no pod in the namespace references the PVC.
  referencing="$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r --arg pvc "$DEST_PVC" '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | .metadata.name' 2>/dev/null | head -1 || true)"
  [[ -z "$referencing" ]] && break
  sleep 2
done
printf 'Volume release check: referencing pods=%s.\n' "${referencing:-none}" >&2

# --- Stage 3: backup against the pre-filled destination ----------------------------------
if [[ "$TARGET" == incremental ]]; then
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH" \
    >"$EVIDENCE_DIR/incr-stage.log" 2>&1; then
    stage_rc=0
  else
    stage_rc=$?
  fi
else
  if make e2e TYPE=full NAME="$RUN_ID" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
    GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH" \
    >"$EVIDENCE_DIR/full-stage.log" 2>&1; then
    stage_rc=0
  else
    stage_rc=$?
  fi
fi
printf 'Backup stage exit status: %s (failure expected on ENOSPC legs).\n' "$stage_rc" >&2

# --- Tracker sampling (I-05 r02 watch pattern) --------------------------------------------
tracker_cp=""
for ((i = 0; i < 25; i++)); do
  tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" \
    -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$tracker_cp" >>"$EVIDENCE_DIR/tracker-samples.txt"
  sleep 10
done
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$DEST_BACKUP" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$DEST_BACKUP" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
printf 'Backup %s: Done=%s reason=%s.\n' "$DEST_BACKUP" "$backup_done_status" "$backup_done_reason" >&2
vmi_state="$(oc get vmi -n "$NAMESPACE" "$VM_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || echo '')"

# --- Verdict checks ------------------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
printf 'CHECK fill-size-gib: %s target=%s pvc=%s\n' \
  "$FILL_SIZE_GIB" "$TARGET" "$DEST_PVC" | tee -a "$checks_file" >&2
printf 'CHECK backup-terminal-state: done=%s reason=%s (expect no-space failure class)\n' \
  "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK tracker-state: latestCheckpoint=%s (expect previous checkpoint held)\n' \
  "$tracker_cp" | tee -a "$checks_file" >&2
printf 'CHECK vmi-paused: %s (expect not-paused — dest-only ENOSPC)\n' \
  "${vmi_state:-unknown}" | tee -a "$checks_file" >&2
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* ]]; then
  printf 'CHECK unexpected-success: investigate fill-erased vs copy-fit (post df + listing needed)\n' \
    | tee -a "$checks_file" >&2
fi
printf 'O09 complete.\n' >&2
exit 0
