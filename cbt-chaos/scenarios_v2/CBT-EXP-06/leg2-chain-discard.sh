#!/usr/bin/env bash
# leg2-chain-discard.sh — CBT-EXP-06 follow-up leg 2 (human-approved).
#
# Question it answers: with the checkpoint chain discarded (tracker deleted and a
# fresh one created), does the VM regain backup capability — and does the
# resulting backup protect BOTH disks again? finding-1's recovery matrix records
# "delete tracker, then new backup -> next backup completes type=Full, chain
# silently discarded" for the deleted-tracker entry path; this leg verifies that
# row for the corrupt-checkpoint path on this VM, which is the last unverified
# escape hatch after leg 1 showed that repairing the tracker does not help.
#
# Also performs the approved cleanup: the wedged pass's CR is deleted (releasing
# its finalizer and detaching its leaked hotplug mount); its destination PVC is
# kept, as are the earlier passes' PVCs.
#
# Safety: fail-closed preconditions, bounded waits, a pool guard sized for a
# fully allocated ~80 GiB full image, and snapshots of everything it destroys.
#
# Usage: leg2-chain-discard.sh [--plan]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set the graded run id}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
valid_run_id "$RUN_ID" || { printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2; }
for command in oc jq python3; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
export NAMESPACE
FOLLOWUP_DIR="${FOLLOWUP_DIR:-$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/followup/${RUN_ID}-leg2-chain-discard}"
VM_NAME="vm-${RUN_ID}"
TRACKER="vm-tracker-${RUN_ID}"
WEDGED="vm-incremental-${RUN_ID}-p03"
FULL_CR="vm-followup-full-${RUN_ID}-f02"
FULL_PVC="vm-followup-full-pvc-${RUN_ID}-f02"
POOL_DATA_DIR="/cbt-demo-pool-data-dir/csi"
MIN_FREE_BYTES=$((95 * 1024 * 1024 * 1024))    # a full image is fully allocated (~80 GiB)
ABORT_FREE_BYTES=$((8 * 1024 * 1024 * 1024))

PLAN_MODE=false
for arg in "$@"; do
  case "$arg" in
    --plan) PLAN_MODE=true ;;
    -h|--help) printf 'Usage: %s [--plan]\n' "$(basename "$0")"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

pool_free_bytes() {
  local pod
  pod="$(oc get pods -n openshift-cnv -o name 2>/dev/null | grep hostpath-provisioner-csi | head -1 | cut -d/ -f2)"
  [[ -n "$pod" ]] || return 1
  oc exec -n openshift-cnv "$pod" -c hostpath-provisioner -- df -B1 "$POOL_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}'
}
backup_condition() {
  oc get vmbackup "$1" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
    [ (.status.type // "null"),
      ([.status.conditions[]?|select(.type=="Done")|.status]|first // "none"),
      ([.status.conditions[]?|select(.type=="Done")|.reason]|first // "-"),
      ([.status.includedVolumes[]?.volumeName]|join(",")) ] | join("|")' 2>/dev/null || printf 'absent|||\n'
}
launcher_pod() { oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true; }
hotplug_mounts() {
  oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -c '[.status.volumeStatus[]?|select(.phase=="MountedToPod")|.name]'
}

if [[ "$PLAN_MODE" == true ]]; then
  printf 'PLAN (read-only; mutates nothing)\n'
  printf 'RUN_ID: %s  namespace=%s  evidence=%s\n' "$RUN_ID" "$NAMESPACE" "$FOLLOWUP_DIR"
  printf '  L1 snapshot: VMI/VM, tracker, checkpoint XML, QEMU bitmaps, hotplug mounts, wedged %s\n' "$WEDGED"
  printf '  L2 cleanup (approved): delete %s (CR only; PVC kept) and confirm finalizer release + hotplug detach\n' "$WEDGED"
  printf '  L3 chain discard: delete %s (snapshotted first)\n' "$TRACKER"
  printf '  L4 recreate %s (spec source = VM) + %s (80Gi) + %s, wait <=30 min\n' "$TRACKER" "$FULL_PVC" "$FULL_CR"
  printf '  L5 classify: Done=True type=Full with both disks = capability restored | otherwise = escape hatch failed\n'
  printf '  guards: VMI Running + CBT Enabled; pool free >= 95 GiB before L4 (a full image is fully allocated); abort a wait below 8 GiB\n'
  exit 0
fi

mkdir -p "$FOLLOWUP_DIR"
exec > >(tee -a "$FOLLOWUP_DIR/leg2.log") 2>&1
printf '=== leg 2 (chain discard + capability restore) for %s at %s UTC ===\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- L1 ----------
vmi_phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
vmi_cbt="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
[[ "$vmi_phase" == Running && "$vmi_cbt" == Enabled ]] || { printf 'PRECONDITION FAILED: phase=%s cbt=%s\n' "${vmi_phase:-?}" "${vmi_cbt:-?}" >&2; exit 3; }
oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/tracker-before-delete.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/tracker-before-delete.json" 2>/dev/null || true
oc get vmbackup "$WEDGED" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/wedged-p03-before-delete.yaml" 2>/dev/null || true
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/vmi-before.json" 2>/dev/null || true
printf 'L1 wedged %s: %s\n' "$WEDGED" "$(backup_condition "$WEDGED")"
printf 'L1 hotplug mounts before: %s\n' "$(hotplug_mounts)"
printf 'L1 tracker before: %s\n' "$(oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint.name}{" volumes="}{.status.latestCheckpoint.volumes[*].volumeName}' 2>/dev/null)"
pod="$(launcher_pod)"
oc exec -n "$NAMESPACE" "$pod" -c compute -- virsh checkpoint-dumpxml "vm-cbt-demo_${VM_NAME}" \
  "$(oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint.name}')" \
  > "$FOLLOWUP_DIR/checkpoint-dumpxml-before.xml" 2>&1 || true
printf 'L1 checkpoint disks before: %s\n' "$(grep -oE "<disk name='[^']+'" "$FOLLOWUP_DIR/checkpoint-dumpxml-before.xml" 2>/dev/null | tr '\n' ' ')"

# ---------- L2 cleanup (approved) ----------
if oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf '=== L2: delete the wedged CR only (%s) ===\n' "$WEDGED"
  t0="$(date -u +%s)"
  oc delete vmbackup "$WEDGED" -n "$NAMESPACE" --wait=false > "$FOLLOWUP_DIR/l2-delete.out" 2>&1 || true
  for _ in $(seq 1 60); do oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1 || break; sleep 2; done
  if oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1; then printf 'L2 not released after 120s; aborting.\n' >&2; exit 4; fi
  printf 'L2 released in %ss\n' "$(( $(date -u +%s) - t0 ))"
  sleep 15
  printf 'L2 hotplug mounts after: %s\n' "$(hotplug_mounts)"
else
  printf 'L2 nothing to clean: %s already absent\n' "$WEDGED"
fi

# ---------- L3 chain discard ----------
printf '=== L3: delete the tracker (chain discard) ===\n'
oc delete vmbackuptracker "$TRACKER" -n "$NAMESPACE" --wait=true --timeout=120s > "$FOLLOWUP_DIR/l3-delete-tracker.out" 2>&1 || {
  printf 'L3 tracker delete failed; aborting.\n' >&2; cat "$FOLLOWUP_DIR/l3-delete-tracker.out" >&2; exit 5; }
printf 'L3 tracker absent: %s\n' "$(oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" >/dev/null 2>&1 && echo no || echo yes)"
printf 'L3 QEMU bitmaps after chain discard: datadisk=%s rootdisk=%s\n' \
  "$(oc exec -n "$NAMESPACE" "$pod" -c compute -- virsh qemu-monitor-command "vm-cbt-demo_${VM_NAME}" '{"execute":"query-named-block-nodes"}' 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps([b.get('name') for n in d.get('return',[]) if n.get('node-name')=='libvirt-2-format' for b in n.get('dirty-bitmaps',[])]))" 2>/dev/null || echo '?')" \
  "$(oc exec -n "$NAMESPACE" "$pod" -c compute -- virsh qemu-monitor-command "vm-cbt-demo_${VM_NAME}" '{"execute":"query-named-block-nodes"}' 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps([b.get('name') for n in d.get('return',[]) if n.get('node-name')=='libvirt-4-format' for b in n.get('dirty-bitmaps',[])]))" 2>/dev/null || echo '?')"

# ---------- L4 fresh tracker + full backup ----------
free_now="$(pool_free_bytes || echo 0)"
printf '=== L4: recreate the tracker and take a full backup (pool free %s bytes) ===\n' "$free_now"
if (( free_now < MIN_FREE_BYTES )); then printf 'REFUSED: pool free %s < %s bytes\n' "$free_now" "$MIN_FREE_BYTES" >&2; exit 6; fi
cat <<YAML | oc apply -f - > "$FOLLOWUP_DIR/l4-apply.out" 2>&1 || l4_status=$?
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: ${TRACKER}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${VM_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${FULL_PVC}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 80Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: ${FULL_CR}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: ${TRACKER}
  pvcName: ${FULL_PVC}
YAML
printf 'L4 apply exit=%s\n' "${l4_status:-0}"
sed -n '1,4p' "$FOLLOWUP_DIR/l4-apply.out" || true

# ---------- L5 classify ----------
printf '=== L5: wait up to 30 min ===\n'
deadline=$(( $(date -u +%s) + 1800 ))
verdict="wedged"
while :; do
  state="$(backup_condition "$FULL_CR")"
  done_field="${state#*|}"; done_field="${done_field%%|*}"
  if [[ "$done_field" == "True" || "$done_field" == "False" ]]; then verdict="terminal"; break; fi
  (( $(date -u +%s) > deadline )) && { verdict="wedged"; break; }
  now_free="$(pool_free_bytes || echo 999999999)"
  (( now_free < ABORT_FREE_BYTES )) && { verdict="pool_starvation_abort"; break; }
  sleep 20
done
final="$(backup_condition "$FULL_CR")"
inc="${final##*|}"
case "$final" in
  *"|True|"*)
    if [[ "$inc" == *datadisk* && "$inc" == *rootdisk* ]]; then verdict="capability-restored-both-disks"
    elif [[ "$inc" == "rootdisk" ]]; then verdict="capability-restored-rootdisk-only"
    else verdict="terminal-other"; fi ;;
  *"|False|"*) verdict="clean-failure" ;;
esac
printf 'L5 RESULT: %s  state(type|done|reason|included)=%s\n' "$verdict" "$final"
oc get vmbackup "$FULL_CR" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/l5-full-backup.yaml" 2>/dev/null || true
oc get vmbackup "$FULL_CR" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/l5-full-backup.json" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/tracker-after.json" 2>/dev/null || true
oc get events -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/l5-events-ns.json" 2>/dev/null || true
printf 'L5 tracker after: %s\n' "$(oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint.name}{" volumes="}{.status.latestCheckpoint.volumes[*].volumeName}' 2>/dev/null)"
printf 'L5 hotplug mounts after: %s\n' "$(hotplug_mounts)"
jq -nc --arg verdict "$verdict" --arg state "$final" \
  '{leg: "leg2-chain-discard", verdict: $verdict, full_backup_state: $state}' > "$FOLLOWUP_DIR/leg2-result.json"
printf 'leg 2 complete.\n'
