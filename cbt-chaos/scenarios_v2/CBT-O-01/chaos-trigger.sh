#!/usr/bin/env bash
# CBT-O-01: rebuild the RHEL9 golden on RBD + baseline ODF lifecycle (fixture).
#
# Prerequisite for the whole O-family. No chaos. Idempotent on the golden
# (skips import if the DataSource already exists and is Bound); always runs a
# fresh full+incremental lifecycle to record the ODF baseline durations that
# O-02..O-12 verdicts reference.
#
# Usage:
#   RUN_ID=20261014-cbto01-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     bash chaos-trigger.sh
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
# Force-set: .env may export large-odf; "odf" is the canonical O-family value
# and maps to the same rhel9 80Gi/30Gi large-odf sizing in common.sh.
MANIFEST_VARIANT="odf"
VM_DATA_SOURCE_NAME="${VM_DATA_SOURCE_NAME:-rhel9-rbd}"
VM_DATA_SOURCE_NAMESPACE="openshift-virtualization-os-images"
export NAMESPACE VM_DATA_SOURCE_NAME VM_DATA_SOURCE_NAMESPACE
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
GOLDEN_NS="$VM_DATA_SOURCE_NAMESPACE"
GOLDEN_DV="rhel9-rbd-golden"
GOLDEN_DS="$VM_DATA_SOURCE_NAME"
GOLDEN_SC="ocs-storagecluster-ceph-rbd"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-01/runs/$RUN_ID"

# --- Guards ---------------------------------------------------------------------
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
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'O01: golden rebuild check + ODF baseline lifecycle, run %s.\n' "$RUN_ID" >&2

# --- Golden rebuild (idempotent) ------------------------------------------------
ds_pvc="$(oc get datasource "$GOLDEN_DS" -n "$GOLDEN_NS" \
  -o jsonpath='{.spec.source.pvc.name}' 2>/dev/null || echo '')"
if [[ -n "$ds_pvc" ]]; then
  ds_sc="$(oc get pvc "$ds_pvc" -n "$GOLDEN_NS" \
    -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo '')"
  if [[ "$ds_sc" == "$GOLDEN_SC" ]]; then
    printf 'Golden DataSource %s already on %s (pvc %s) — skipping import.\n' \
      "$GOLDEN_DS" "$GOLDEN_SC" "$ds_pvc" >&2
    oc wait "pvc/$ds_pvc" -n "$GOLDEN_NS" \
      --for=jsonpath='{.status.phase}'=Bound --timeout=20m >/dev/null
  else
    printf 'DataSource %s exists but on %s (expected %s) — aborting for manual review.\n' \
      "$GOLDEN_DS" "${ds_sc:-unknown}" "$GOLDEN_SC" >&2
    exit 2
  fi
else
  printf 'Importing golden %s on %s (~10-30 min one-time).\n' "$GOLDEN_DV" "$GOLDEN_SC" >&2
  src_ref="$(oc get imagestream rhel9-guest -n "$GOLDEN_NS" \
    -o jsonpath='{.status.tags[?(@.tag=="latest")].items[0].dockerImageReference}' 2>/dev/null || echo '')"
  [[ -n "$src_ref" ]] || { printf 'Cannot resolve rhel9-guest imagestream digest.\n' >&2; exit 2; }
  printf 'Golden source image: %s\n' "$src_ref" >&2
  cat >"$EVIDENCE_DIR/golden-dv.yaml" <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: $GOLDEN_DV
  namespace: $GOLDEN_NS
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  source:
    registry:
      url: docker://$src_ref
      pullMethod: node
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 30Gi
    storageClassName: $GOLDEN_SC
    volumeMode: Filesystem
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: $GOLDEN_DS
  namespace: $GOLDEN_NS
spec:
  source:
    pvc:
      name: $GOLDEN_DV
      namespace: $GOLDEN_NS
EOF
  oc apply -f "$EVIDENCE_DIR/golden-dv.yaml" >/dev/null
  oc wait "dv/$GOLDEN_DV" -n "$GOLDEN_NS" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m >/dev/null
  printf 'Golden import Succeeded.\n' >&2
fi
# Golden-on-RBD prerequisite guard shared by the whole O-family.
printf 'CHECK golden-on-rbd: datasource=%s pvc=%s sc=%s\n' \
  "$GOLDEN_DS" "$ds_pvc" "${ds_sc:-preexisting}" >&2

# --- Baseline full lifecycle (background; observe at gate) ----------------------
copy_start_epoch=$(date +%s)
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s Progressing.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
vm_node=""
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$prog" == True ]]; then
    gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    vm_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null || echo '')"
    printf 'Progressing=True at %s; VM node=%s.\n' "$gate_hit_at" "${vm_node:-unknown}" >&2
    # RBD device visibility on the VM's node during the copy (ODF data-path proof).
    if [[ -n "$vm_node" ]]; then
      oc debug "node/$vm_node" --to-namespace=default -- chroot /host lsblk \
        >"$EVIDENCE_DIR/node-lsblk-during-copy.txt" 2>/dev/null || true
      grep -c rbd "$EVIDENCE_DIR/node-lsblk-during-copy.txt" \
        >"$EVIDENCE_DIR/node-rbd-device-count.txt" 2>/dev/null || echo 0 \
        >"$EVIDENCE_DIR/node-rbd-device-count.txt"
      printf 'RBD devices visible on node during copy: %s.\n' \
        "$(cat "$EVIDENCE_DIR/node-rbd-device-count.txt")" >&2
    fi
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
copy_end_epoch=$(date +%s)
full_wall=$((copy_end_epoch - copy_start_epoch))
printf 'Workflow (full) exit status: %d; wall gate-to-finish: %ss.\n' "$wf_status" "$full_wall" >&2

# --- Follow-up incremental + tracker --------------------------------------------
incr_status=""
if [[ "$wf_status" == 0 ]]; then
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
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2

# --- Verdict checks --------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* && "$wf_status" == 0 ]]; then
  printf 'CHECK baseline-full: PASS\n' | tee -a "$checks_file" >&2
else
  printf 'CHECK baseline-full: FAIL done=%s reason=%s wf=%s\n' \
    "$backup_done_status" "$backup_done_reason" "$wf_status" | tee -a "$checks_file" >&2
fi
printf 'CHECK baseline-full-seconds: %s (HPP reference 52-58)\n' "$full_wall" | tee -a "$checks_file" >&2
printf 'CHECK baseline-incremental-rc: %s\n' "${incr_status:-skipped}" | tee -a "$checks_file" >&2
printf 'CHECK baseline-vm-node: %s\n' "${vm_node:-unknown}" | tee -a "$checks_file" >&2
printf 'CHECK golden-on-rbd: datasource=%s\n' "$GOLDEN_DS" | tee -a "$checks_file" >&2
printf 'O01 complete.\n' >&2
exit 0
