#!/usr/bin/env bash
# EXP-6 continuation (r01b): surgery leg only. The control leg already
# completed (full+incremental+verify PASS; includedVolumes rootdisk+datadisk;
# checkpoint vm-backup-20261014-exp06-r01-2026-10-14_19-15-36 on the
# tracker). This script runs stages 3-5: resolve vdb QEMU node, remove the
# checkpoint bitmap from vdb (fail-closed), hard-restart the VMI
# (redefinition), then the surgery incremental.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"
RUN_ID=20261014-exp06-r01
KUBECONFIG_PATH=/root/mno/kubeconfig
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE=vm-cbt-demo
VM_OS=rhel9
MANIFEST_VARIANT=default
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
INCR_NAME="vm-incremental-${RUN_ID}-p01"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/runs/$RUN_ID"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
for command in oc kubectl make tee python3; do
  command -v "$command" >/dev/null || { printf 'Missing %s\n' "$command" >&2; exit 2; }
done

launcher_pod() {
  oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=${VM_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

printf '=== LEG B (surgery, continuation r01b): remove vdb checkpoint bitmap ===\n' >&2
CHECKPOINT_NAME="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
if [[ -z "$CHECKPOINT_NAME" ]]; then
  printf 'No checkpoint on tracker; aborting.\n' >&2; exit 5
fi
printf 'Surgery target: checkpoint %s on disk vdb.\n' "$CHECKPOINT_NAME" >&2
DOM="vm-cbt-demo_${VM_NAME}"
LAUNCHER="$(launcher_pod)"
VDB_NODE="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" '{"execute":"query-named-block-nodes"}' 2>/dev/null \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
for n in d['return']:
    f = n.get('file','')
    if f.endswith('/cbt/datadisk.qcow2'):
        print(n['node-name']); break
" 2>/dev/null || true)"
if [[ -z "$VDB_NODE" ]]; then
  printf 'Could not resolve vdb QEMU node name; aborting (fail-closed).\n' >&2; exit 6
fi
printf 'vdb QEMU node: %s\n' "$VDB_NODE" >&2
bitmap_present() {
  # Check via query-block (query-block-dirty-bitmap is NOT a QMP command).
  local node="$1" name="$2"
  kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
    virsh qemu-monitor-command "$DOM" '{"execute":"query-block"}' 2>/dev/null \
    | python3 -c "
import json,sys
d = json.load(sys.stdin)
for b in d['return']:
    ins = b.get('inserted',{})
    if ins.get('node-name') == '$node':
        for x in (ins.get('dirty-bitmaps') or b.get('dirty-bitmaps') or []):
            if x['name'] == '$name':
                sys.exit(0)
sys.exit(1)
"
}
if ! bitmap_present "$VDB_NODE" "$CHECKPOINT_NAME"; then
  printf 'FAIL-CLOSED: checkpoint bitmap %s not found on vdb (%s) before surgery.\n' \
    "$CHECKPOINT_NAME" "$VDB_NODE" >&2
  exit 6
fi
printf 'Bitmap %s confirmed on vdb. Removing (QMP block-dirty-bitmap-remove).\n' "$CHECKPOINT_NAME" >&2
REMOVE_RESULT="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" \
  "{\"execute\":\"block-dirty-bitmap-remove\",\"arguments\":{\"node\":\"$VDB_NODE\",\"name\":\"$CHECKPOINT_NAME\"}}" 2>&1 || true)"
printf '%s\n' "$REMOVE_RESULT" >>"$EVIDENCE_DIR/qmp-remove-result.txt"
kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" '{"execute":"query-block"}' 2>/dev/null \
  >"$EVIDENCE_DIR/bitmaps-after.json" || true
if bitmap_present "$VDB_NODE" "$CHECKPOINT_NAME"; then
  printf 'FAIL-CLOSED: bitmap still present after removal; aborting.\n' >&2
  exit 6
fi
printf 'Bitmap removal VERIFIED on vdb.\n' >&2

# Hard restart to fire the redefinition path.
OLD_UID="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
printf 'UTC action request: delete VMI %s at %s (redefinition with vdb bitmap missing).\n' \
  "$VM_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
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
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/tracker-after-restart.yaml" 2>/dev/null || true
TRACKER_VOLUMES="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.volumes[*].volumeName}' 2>/dev/null || true)"
printf 'Tracker latestCheckpoint volumes after redefinition: %s\n' "${TRACKER_VOLUMES:-none}" >&2
LEADER="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$LEADER" -n openshift-cnv --since=5m >"$EVIDENCE_DIR/controller-redefinition-window.log" 2>/dev/null || true

# Surgery incremental.
printf 'Running surgery incremental pass.\n' >&2
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Surgery incremental status: %d\n' "$incr_status" >&2
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
if [[ "$incr_done" == True && "$incr_type" == Incremental && "$incr_volumes" != *datadisk* ]]; then
  printf 'DEFECT CONFIRMED: incremental Done=True WITHOUT datadisk (silent disk drop) — includedVolumes=%s\n' \
    "$incr_volumes" >&2
fi
if ((incr_status != 0)); then
  printf 'Incremental failed (%d) — detected-and-failed or wedge; evidence preserved.\n' "$incr_status" >&2
fi
printf 'EXP-6 surgery leg complete.\n' >&2
exit 0
