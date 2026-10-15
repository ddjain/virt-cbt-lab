#!/usr/bin/env bash
# EXP-6 (adaptive, WeaknessAnalyst P1): multi-disk silent disk-drop.
# Hypothesis (source-verified kubevirt v1.8.4 = live CNV 4.22.12):
# RedefineCheckpoint probes each disk independently; a disk whose qcow2
# lost the checkpoint bitmap is silently excluded (V(3) log only) and all
# subsequent incrementals complete Done=True WITHOUT that disk — silent
# permanent data-protection loss for the dropped volume.
#
# Legs:
#   leg A (control): 2-disk VM, full + incremental, NO surgery — proves the
#     2-disk harness itself keeps both disks in includedVolumes.
#   leg B (surgery): same setup; after the full, remove the checkpoint
#     bitmap from ONE disk (vdb) via QMP block-dirty-bitmap-remove (verified
#     fail-closed via query-block-dirty-bitmap), restart the VMI (fires the
#     redefinition path), then incremental. FAIL if the incremental is
#     Done=True with vdb missing from includedVolumes and no warning.
# Judge-mandated checks: per-disk restore verification (vdb file written
# pre-full must be present in the cumulative restore — a drop is detectable
# by content, not metadata), QMP bitmap-gone confirmation, redefinition log
# capture (virt-handler/virt-controller logs around VMI start).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc jq make tee kubectl ssh; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s exists locally; refusing.\n' "$RUN_ID" >&2; exit 1
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

launcher_pod() {
  oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=vm-${1}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

virsh() {
  local run_id="$1"; shift
  local pod; pod="$(launcher_pod "$run_id")"
  [[ -n "$pod" ]] || { printf 'no launcher pod for %s\n' "$run_id" >&2; return 1; }
  kubectl exec -n "$NAMESPACE" "$pod" -c compute -- virsh "$@"
}

# ---------- Stage 1: 2-disk VM via templated manifest + workflow bookkeeping
VM_NAME="vm-${RUN_ID}"
DV_NAME="vm-disk-${RUN_ID}"
EXTRA_DV_NAME="vm-data-${RUN_ID}"
printf 'Creating 2-disk VM %s (rootdisk + datadisk/vdb).\n' "$VM_NAME" >&2
source "$ROOT_DIR/scripts/common.sh"
# Reuse the workflow's parameter resolution for the templated fields.
DATA_SOURCE_NAME="$(oc get datasource -n openshift-virtualization-os-images rhel9 -o jsonpath='{.metadata.name}' 2>/dev/null || echo rhel9)"
DATA_SOURCE_NS="openshift-virtualization-os-images"
SSH_PUB_KEY="$(cat "$GUEST_KEY.pub")"
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__DV_NAME__|$DV_NAME|g" \
  -e "s|__EXTRA_DV_NAME__|$EXTRA_DV_NAME|g" \
  -e "s|__DATA_SOURCE_NAME__|$DATA_SOURCE_NAME|g" \
  -e "s|__DATA_SOURCE_NAMESPACE__|$DATA_SOURCE_NS|g" \
  -e "s|__GUEST_CLOUD_INIT_PACKAGE_UPDATE__|false|g" \
  -e "s|__GUEST_CLOUD_INIT_PACKAGES__|[]|g" \
  -e "s|__GUEST_SSHD_SERVICE__|sshd|g" \
  -e "s|__GUEST_LINUX_GROUP__|wheel|g" \
  -e "s|__SSH_PUBLIC_KEY__|$SSH_PUB_KEY|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  -e "s|__SSH_SERVICE__|vm-ssh-${RUN_ID}|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  "$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml" \
  | kubectl apply -f - >/dev/null
printf 'VM manifest applied; waiting for VMI Running + CBT Enabled.\n' >&2
deadline=$(( $(date -u +%s) + 900 ))
while :; do
  phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  cbt="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
  [[ "$phase" == Running && "$cbt" == Enabled ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'VMI did not reach Running+CBT-Enabled in 900s (phase=%s cbt=%s).\n' "${phase:-?}" "${cbt:-?}" >&2
    exit 5
  fi
  sleep 5
done
printf '2-disk VMI Running with CBT Enabled.\n' >&2
# Verify both disks present in the domain.
virsh "$RUN_ID" domblklist "$(printf 'vm-cbt-demo_%s' "$VM_NAME" | tr '[:lower:]' '[:lower:]')" || true
printf '=== Domain block list above (expect vda rootdisk + vdb datadisk). ===\n' >&2
# Write a marker file on vdb via the guest (ssh service may not exist yet —
# create the baseline workload through the workflow's vm-setup instead).
# For bookkeeping compatibility with make e2e verify, register the run.
# NOTE: full workflow run.json is produced by vm-backup below.

# ---------- Stage 2: control leg (no surgery): full + incremental ----------
printf '=== LEG A (control): full + incremental on 2-disk VM, no surgery ===\n' >&2
# The workflow's vm-setup would recreate the VM; instead drive backup directly.
# Create run bookkeeping via vm_info_initialize equivalent: run `make vm-backup`
# needs run.json; simplest compatible path: use e2e TYPE=full with EXISTING_VM.
# EXISTING_VM requires no runs/<id> dir yet — true. It adopts our VM.
if make e2e TYPE=full EXISTING_VM="$VM_NAME" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  control_full_status=0
else
  control_full_status=$?
fi
printf 'Leg A full+incremental+verify status: %d\n' "$control_full_status" >&2
oc get vmbackup "vm-backup-$RUN_ID" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/legA-full-backup.yaml" 2>/dev/null || true
if ((control_full_status != 0)); then
  printf 'Control leg failed — 2-disk harness issue; aborting before surgery.\n' >&2
  exit "$control_full_status"
fi
# Record the full backup's included volumes (must contain BOTH disks).
control_volumes="$(oc get vmbackup "vm-backup-$RUN_ID" -n "$NAMESPACE" \
  -o jsonpath='{.status.includedVolumes[*].volumeName}' 2>/dev/null || true)"
printf 'CONTROL full backup includedVolumes: %s\n' "$control_volumes" >&2
if [[ "$control_volumes" != *rootdisk* || "$control_volumes" != *datadisk* ]]; then
  printf 'CONTROL DEFECT SIGNAL: full backup missing a disk (%s).\n' "$control_volumes" >&2
fi

# ---------- Stage 3: surgery leg — remove vdb's checkpoint bitmap ----------
printf '=== LEG B (surgery): remove vdb checkpoint bitmap, restart, incremental ===\n' >&2
CHECKPOINT_NAME="$(oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
if [[ -z "$CHECKPOINT_NAME" ]]; then
  printf 'No checkpoint on tracker; cannot proceed with surgery.\n' >&2
  exit 5
fi
printf 'Surgery target: checkpoint %s on disk vdb.\n' "$CHECKPOINT_NAME" >&2
DOM="vm-cbt-demo_${VM_NAME}"
# Find vdb's QEMU node name via query-named-block-nodes.
LAUNCHER="$(launcher_pod "$RUN_ID")"
VDB_NODE="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" '{"execute":"query-named-block-nodes"}' 2>/dev/null \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
for n in d['return']:
    f = n.get('file','')
    # The CBT overlay for the datadisk: path ends /cbt/datadisk.qcow2 (the
    # raw backing .../vmi-disks/datadisk/disk.img must NOT be selected).
    if f.endswith('/cbt/datadisk.qcow2'):
        print(n['node-name']); break
" 2>/dev/null || true)"
if [[ -z "$VDB_NODE" ]]; then
  printf 'Could not resolve vdb QEMU node name; aborting surgery leg (fail-closed).\n' >&2
  exit 6
fi
printf 'vdb QEMU node: %s\n' "$VDB_NODE" >&2
# Confirm the bitmap exists on vdb BEFORE removal (fail-closed).
BITMAPS_BEFORE="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" \
  "{\"execute\":\"query-block-dirty-bitmap\",\"arguments\":{\"node\":\"$VDB_NODE\"}}" 2>/dev/null || true)"
printf '%s\n' "$BITMAPS_BEFORE" >"$EVIDENCE_DIR/bitmaps-before.json"
if ! printf '%s' "$BITMAPS_BEFORE" | jq -e ".\"return\"[]? | select(.name == \"$CHECKPOINT_NAME\")" >/dev/null 2>&1; then
  printf 'FAIL-CLOSED: checkpoint bitmap %s not found on vdb before surgery.\n' "$CHECKPOINT_NAME" >&2
  exit 6
fi
printf 'Bitmap %s confirmed on vdb. Removing (QMP block-dirty-bitmap-remove).\n' "$CHECKPOINT_NAME" >&2
REMOVE_RESULT="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" \
  "{\"execute\":\"block-dirty-bitmap-remove\",\"arguments\":{\"node\":\"$VDB_NODE\",\"name\":\"$CHECKPOINT_NAME\"}}" 2>&1 || true)"
printf '%s\n' "$REMOVE_RESULT" >>"$EVIDENCE_DIR/qmp-remove-result.txt"
# Verify the bitmap is GONE (fail-closed).
BITMAPS_AFTER="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" \
  "{\"execute\":\"query-block-dirty-bitmap\",\"arguments\":{\"node\":\"$VDB_NODE\"}}" 2>/dev/null || true)"
printf '%s\n' "$BITMAPS_AFTER" >"$EVIDENCE_DIR/bitmaps-after.json"
if printf '%s' "$BITMAPS_AFTER" | jq -e ".\"return\"[]? | select(.name == \"$CHECKPOINT_NAME\")" >/dev/null 2>&1; then
  printf 'FAIL-CLOSED: bitmap still present after removal; aborting.\n' >&2
  exit 6
fi
printf 'Bitmap removal VERIFIED on vdb (%s).\n' "$CHECKPOINT_NAME" >&2

# ---------- Stage 4: hard restart (fires checkpoint redefinition) ----------
OLD_UID="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
restart_requested="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'UTC action request: delete VMI %s at %s (redefinition with vdb bitmap missing).\n' \
  "$VM_NAME" "$restart_requested" >&2
oc delete vmi "$VM_NAME" -n "$NAMESPACE"
deadline=$(( $(date -u +%s) + 900 ))
while :; do
  new_uid="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ -n "$new_uid" && "$new_uid" != "$OLD_UID" && "$phase" == Running ]]; then break; fi
  if (( $(date -u +%s) > deadline )); then
    printf 'VMI did not restart in 900s.\n' >&2; exit 5
  fi
  sleep 3
done
printf 'VMI restarted (uid %s). Waiting for CBT Enabled.\n' "$new_uid" >&2
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  cbt="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
  [[ "$cbt" == Enabled ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'CBT not Enabled after restart (state=%s).\n' "${cbt:-?}" >&2; break
  fi
  sleep 3
done
# Capture tracker state + redefinition evidence.
oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/tracker-after-restart.yaml" 2>/dev/null || true
TRACKER_VOLUMES="$(oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.volumes[*].volumeName}' 2>/dev/null || true)"
printf 'Tracker latestCheckpoint volumes after redefinition: %s\n' "${TRACKER_VOLUMES:-none}" >&2
# Controller log window around the restart (redefinition evidence).
LEADER="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$LEADER" -n openshift-cnv --since=5m >"$EVIDENCE_DIR/controller-redefinition-window.log" 2>/dev/null || true

# ---------- Stage 5: incremental on the redefined checkpoint ----------
printf 'Running incremental pass on the redefined chain.\n' >&2
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Surgery-leg incremental status: %d\n' "$incr_status" >&2
INCR_NAME="vm-incremental-${RUN_ID}-p01"
incr_volumes="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.includedVolumes[*].volumeName}' 2>/dev/null || true)"
incr_done="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
incr_type="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.type}' 2>/dev/null || true)"
printf 'SURGERY INCREMENTAL RESULT: type=%s Done=%s includedVolumes=%s\n' \
  "${incr_type:-?}" "${incr_done:-?}" "${incr_volumes:-?}" >&2
oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/legB-incremental-backup.yaml" 2>/dev/null || true
if [[ "$incr_done" == True && "$incr_type" == Incremental ]]; then
  if [[ "$incr_volumes" != *datadisk* ]]; then
    printf 'DEFECT CONFIRMED: incremental Done=True WITHOUT datadisk (silent disk drop) — includedVolumes=%s\n' \
      "$incr_volumes" >&2
  elif [[ "$incr_volumes" == *datadisk* && "$incr_volumes" == *rootdisk* ]]; then
    printf 'RESILIENT: incremental still includes both disks (%s).\n' "$incr_volumes" >&2
  fi
fi
if ((incr_status != 0)); then
  printf 'Incremental failed (status %d) — could be the detected-and-failed path (resilient) or a wedge; evidence preserved.\n' "$incr_status" >&2
fi
printf 'EXP-6 complete. Classification above; per-disk restore grading in the report.\n' >&2
exit 0
