#!/usr/bin/env bash
# CBT-O-08: ceph pool-quota ENOSPC — set ocs-storagecluster-cephblockpool
# max_bytes to usage+headroom before the backup cycle; restore (0=unlimited)
# in a trap. Direct ceph CLI via the rook-ceph-tools pod (no krkn plugin).
#
# Usage:
#   RUN_ID=20261014-cbto08-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     [QUOTA_HEADROOM_GIB=200] bash chaos-trigger.sh
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
QUOTA_HEADROOM_GIB="${QUOTA_HEADROOM_GIB:-200}"
CEPH_NS="openshift-storage"
POOL="ocs-storagecluster-cephblockpool"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-08/runs/$RUN_ID"
TOOLBOX_POD() { oc get pods -n "$CEPH_NS" -l app=rook-ceph-tools -o name | head -1; }
TOOLBOX_CMD() { oc exec -n "$CEPH_NS" "$(TOOLBOX_POD)" -- "$@"; }

# --- Guards (ODF family + quota unlimited) ------------------------------------------
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
ceph_health="$(oc get cephcluster -n "$CEPH_NS" \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo '')"
if [[ "$ceph_health" != HEALTH_OK ]]; then
  printf 'Ceph cluster not HEALTH_OK (got: %s) — aborting.\n' "${ceph_health:-unavailable}" >&2
  exit 2
fi
current_quota="$(TOOLBOX_CMD ceph osd pool get-quota "$POOL" 2>/dev/null \
  | awk '/max_bytes/ {print $3, $4}')"
if [[ "$current_quota" != "0 N/A" && "$current_quota" != "0"* ]]; then
  printf 'Pool quota is not unlimited (%s) — leftover from an aborted run? Aborting.\n' \
    "$current_quota" >&2
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
printf 'O08: pool quota ENOSPC (headroom=%sGiB), run %s.\n' "$QUOTA_HEADROOM_GIB" "$RUN_ID" >&2

# Current pool usage (bytes_used of the block pool, from ceph df JSON).
pool_bytes_used="$(TOOLBOX_CMD ceph df -f json 2>/dev/null \
  | jq -r --arg pool "$POOL" '.pools[] | select(.name == $pool) | .stats.bytes_used')"
[[ -n "$pool_bytes_used" && "$pool_bytes_used" != null ]] || { printf 'Cannot read pool usage.\n' >&2; exit 2; }
quota_bytes=$((pool_bytes_used + QUOTA_HEADROOM_GIB * 1024 * 1024 * 1024))
printf 'Pool usage=%s bytes; setting quota=%s bytes (headroom %sGiB).\n' \
  "$pool_bytes_used" "$quota_bytes" "$QUOTA_HEADROOM_GIB" >&2

# Cluster-global quota: restore no matter how the script exits.
quota_set=false
cleanup_quota() {
  if [[ "$quota_set" == true ]]; then
    printf 'Restoring pool quota to unlimited (max_bytes 0).\n' >&2
    TOOLBOX_CMD ceph osd pool set-quota "$POOL" max_bytes 0 \
      >"$EVIDENCE_DIR/quota-restore.txt" 2>&1 || \
      printf 'QUOTA RESTORE FAILED — manual action required: ceph osd pool set-quota %s max_bytes 0\n' "$POOL" >&2
  fi
}
trap cleanup_quota EXIT
TOOLBOX_CMD ceph osd pool set-quota "$POOL" max_bytes "$quota_bytes" >/dev/null
quota_set=true
TOOLBOX_CMD ceph osd pool get-quota "$POOL" >"$EVIDENCE_DIR/quota-during.txt" 2>/dev/null || true

# --- Full lifecycle under quota -------------------------------------------------------
copy_start_epoch=$(date +%s)
if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1; then
  wf_status=0
else
  wf_status=$?
fi
copy_end_epoch=$(date +%s)
full_wall=$((copy_end_epoch - copy_start_epoch))
printf 'Workflow (full) exit status: %d; wall: %ss.\n' "$wf_status" "$full_wall" >&2
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
printf 'Backup: Done=%s reason=%s.\n' "$backup_done_status" "$backup_done_reason" >&2
TOOLBOX_CMD ceph df >"$EVIDENCE_DIR/ceph-df-during.txt" 2>/dev/null || true

# --- Incremental only if full succeeded; tracker state either way ---------------------
incr_status=""
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* ]]; then
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH" \
    >"$EVIDENCE_DIR/incr-stage.log" 2>&1; then
    incr_status=0
  else
    incr_status=$?
  fi
  printf 'Incremental stage exit status: %s.\n' "$incr_status" >&2
fi
# Tracker sampling (I-05 r02 semantics: expect FULL checkpoint held on failure).
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
for ((i = 0; i < 12; i++)); do
  printf '%s %s\n' "$(date -u +%H:%M:%S)" \
    "$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" \
      -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')" \
    >>"$EVIDENCE_DIR/tracker-samples.txt"
  sleep 10
done
vmi_conditions="$(oc get vmi -n "$NAMESPACE" "$VM_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || echo '')"

# --- Quota lift + recovery proof -------------------------------------------------------
quota_set=false   # trap will not double-restore
cleanup_quota
TOOLBOX_CMD ceph osd pool get-quota "$POOL" >"$EVIDENCE_DIR/quota-after.txt" 2>/dev/null || true
pool_writable=UNKNOWN
if TOOLBOX_CMD ceph osd pool set-quota "$POOL" max_bytes 0 >/dev/null 2>&1; then
  pool_writable=YES
fi
printf 'Pool quota lifted; writable probe=%s.\n' "$pool_writable" >&2

# --- Verdict checks --------------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
printf 'CHECK quota-headroom-gib: %s (usage=%s quota=%s)\n' \
  "$QUOTA_HEADROOM_GIB" "$pool_bytes_used" "$quota_bytes" | tee -a "$checks_file" >&2
printf 'CHECK backup-terminal-state: done=%s reason=%s\n' \
  "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK tracker-state: latestCheckpoint=%s (expect FULL held on failure)\n' \
  "$tracker_cp" | tee -a "$checks_file" >&2
printf 'CHECK vmi-paused: %s\n' "${vmi_conditions:-unknown}" | tee -a "$checks_file" >&2
printf 'CHECK quota-restored-unlimited: %s\n' \
  "$(grep -q "0 N/A" "$EVIDENCE_DIR/quota-after.txt" 2>/dev/null && echo YES || echo VERIFY)" \
  | tee -a "$checks_file" >&2
printf 'CHECK followup-incremental: rc=%s\n' "${incr_status:-skipped}" | tee -a "$checks_file" >&2
printf 'O08 complete.\n' >&2
exit 0
