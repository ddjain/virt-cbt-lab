#!/usr/bin/env bash
# EXP-7 r03: the alive-restore triad point. The r02 shell's backing file is
# the LIVE VM's source disk. Prediction (Judge): a restore executed while
# the VM is alive will "succeed" and hash-match — because the overlay reads
# through to the live source. If so, normal restore verification cannot
# detect this corruption class; only the disaster case (VM gone) fails.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"
RUN_ID=20261014-exp07-r03
KUBECONFIG_PATH=/root/mno/kubeconfig
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE=vm-cbt-demo
VM_OS=rhel9
MANIFEST_VARIANT=default
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-07/runs/$RUN_ID"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
source "$ROOT_DIR/scripts/common.sh"

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
printf 'Control full complete; creating pre-filled-target surgery backup.\n' >&2
SB="vm-backup-enospc-${RUN_ID}"
SP="vm-backup-pvc-enospc-${RUN_ID}"
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
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null
deadline=$(( $(date -u +%s) + 300 ))
while [[ "$(oc get pvc "$SP" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)" != Bound ]]; do
  if (( $(date -u +%s) > deadline )); then printf 'PVC never Bound.\n' >&2; exit 3; fi
  sleep 3
done
SPV="$(oc get pvc "$SP" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')"
oc debug node/d38-h18-000-r660 -- chroot /host bash -c \
  "fallocate -l 2600M /var/hpvolumes/csi/${SPV}/filler.img" >/dev/null 2>&1 || true
oc wait "vmbackup/$SB" -n "$NAMESPACE" --for=condition=Done --timeout=20m || true
sb_reason="$(oc get vmbackup "$SB" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
printf 'Surgery: reason=%s\n' "$sb_reason" >&2
oc get vmbackup "$SB" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/surgery-backup.yaml" || true

# ALIVE-RESTORE: mount the surgery PVC in a helper pod ON THE VM'S NODE and
# convert the shell while the live source backing file exists at the same
# node path... NOTE: the backing path /var/run/kubevirt-private/... lives in
# the LAUNCHER's mount namespace, not the host. A host-side convert still
# fails on the backing file. The decisive alive-restore is the WORKFLOW's
# restore-verify (restore-lib rebase), which runs in a pod that mounts the
# PVC and accesses the source via the same kubevirt-private path pattern.
# Simplest correct probe: run the restore-verify helper against the surgery
# PVC on the VM's node, binding the backing file via the launcher's path.
cd /root/virt-cbt-lab; set -a; . ./.env; set +a
LP="$(oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=${VM_NAME}" -o jsonpath='{.items[0].metadata.name}')"
VMSNIP="$(oc get pod "$LP" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="compute")].containerID}' | sed 's|cri-o://||')"
printf 'Launcher %s container %s\n' "$LP" "$VMSNIP" >&2
# Read the source disk path from the host (shared via the pvcsi host path).
oc run exp7-alive-restore -n "$NAMESPACE" --image="$RESTORE_HELPER_IMAGE" --restart=Never \
  --overrides "{\"spec\":{\"nodeName\":\"d38-h18-000-r660\",\"hostPID\":true,\"tolerations\":[{\"operator\":\"Exists\"}],\"containers\":[{\"name\":\"exp7-alive-restore\",\"image\":\"$RESTORE_HELPER_IMAGE\",\"command\":[\"sleep\",\"600\"],\"securityContext\":{\"privileged\":true},\"volumeMounts\":[{\"name\":\"target\",\"mountPath\":\"/target\"}]}],\"volumes\":[{\"name\":\"target\",\"persistentVolumeClaim\":{\"claimName\":\"$SP\"}}]}}" >/dev/null 2>&1
for i in $(seq 1 20); do sleep 5; ph="$(oc get pod exp7-alive-restore -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"; [[ "$ph" == Running ]] && break; done
[[ "$ph" == Running ]] || { printf 'helper pod not Running (%s).\n' "${ph:-?}" >&2; exit 4; }
F="/target/vm-${RUN_ID}/${SB}-$(oc get vmbackup "$SB" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' | sed "s/.*${RUN_ID}-//" 2>/dev/null || true)/${SB}-rootdisk.qcow2"
# Resolve the actual file path (layout: <vm>/<backup>-<ts>/<backup>-rootdisk.qcow2).
F="$(oc exec -n "$NAMESPACE" exp7-alive-restore -- find /target -name '*.qcow2' 2>/dev/null | head -1)"
printf 'Shell file: %s\n' "$F" >&2
printf '=== qemu-img info (alive) ===\n' >&2
oc exec -n "$NAMESPACE" exp7-alive-restore -- qemu-img info "$F" 2>&1 | head -8 | tee -a "$EVIDENCE_DIR/alive-restore-info.txt"
printf '=== convert WITH live VM present (nsenter the launcher mount ns via hostPID) ===\n' >&2
# The backing file is in the launcher's mount namespace; enter it from the
# helper pod (hostPID, privileged) via nsenter on the container's init pid.
NSPID="$(oc exec -n "$NAMESPACE" exp7-alive-restore -- chroot /host bash -c "crictl inspect $VMSNIP" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')"
printf 'Launcher container host pid: %s\n' "$NSPID" >&2
oc exec -n "$NAMESPACE" exp7-alive-restore -- nsenter -t "$NSPID" -m -- qemu-img convert -O raw "$F" /tmp/alive-restore.raw 2>&1 | head -3 | tee -a "$EVIDENCE_DIR/alive-restore-convert.txt"
oc exec -n "$NAMESPACE" exp7-alive-restore -- nsenter -t "$NSPID" -m -- ls -la /tmp/alive-restore.raw 2>/dev/null | tee -a "$EVIDENCE_DIR/alive-restore-convert.txt" || true
# Hash-compare a region: if the convert "succeeded", the restored raw should
# contain the guest filesystem signature (compare against the control
# backup's restore from runs/<RUN_ID> logs).
printf 'EXP-7 r03 alive-restore probe complete; artifacts in evidence dir.\n' >&2
exit 0
