#!/usr/bin/env bash
# leg1-tracker-repair.sh — CBT-EXP-06 follow-up leg 1 (human-approved).
#
# Question it answers: the wedge could be caused either by the checkpoint/bitmap
# state itself or by the TRACKER still advertising a volume whose bitmap is gone.
# If the request list comes from the tracker, repairing the tracker to match the
# redefined checkpoint (which declares only vda) should let a new pass complete —
# and if it completes Done=True with includedVolumes omitting the datadisk, that
# is the terminal form of the silent per-disk protection loss this experiment
# hunted. If it wedges anyway, the wedge is bitmap-driven and tracker repair does
# not help.
#
# Why this leg has no provenance gap: its mutation is an API write on an object
# anyone can read before and after (no launcher exec, no timing race), so the
# before/after states are captured in-line and no injector-only witness is
# involved.
#
# Safety: fail-closed preconditions, bounded waits, a live pool free-space guard,
# and it deletes exactly one object — the wedged backup CR — while keeping its
# PVC. The tracker status is snapshotted before the patch.
#
# Usage: leg1-tracker-repair.sh [--plan]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set the graded run id (e.g. 20261016-exp06-r02)}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
valid_run_id "$RUN_ID" || { printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2; }
for command in oc jq python3; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
export NAMESPACE
FOLLOWUP_DIR="${FOLLOWUP_DIR:-$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/followup/${RUN_ID}-leg1-tracker-repair}"
TRACKER="vm-tracker-${RUN_ID}"
WEDGED="vm-incremental-${RUN_ID}-p02"
NEW_CR="vm-incremental-${RUN_ID}-p03"
NEW_PVC="vm-incremental-pvc-${RUN_ID}-p03"
MIN_FREE_BYTES=$((25 * 1024 * 1024 * 1024))
ABORT_FREE_BYTES=$((8 * 1024 * 1024 * 1024))
POOL_DATA_DIR="/cbt-demo-pool-data-dir/csi"

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
tracker_volumes() {
  oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json 2>/dev/null | jq -c \
    '{checkpoint:.status.latestCheckpoint.name, volumes:[.status.latestCheckpoint.volumes[]?|(.diskTarget+"/"+.volumeName)]}'
}
launcher_pod() {
  oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=vm-${RUN_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
qmp_bitmaps() { # $1 = node-name ; prints that node's dirty-bitmap names
  local pod; pod="$(launcher_pod)"
  oc exec -n "$NAMESPACE" "$pod" -c compute -- \
    virsh qemu-monitor-command "vm-cbt-demo_vm-${RUN_ID}" '{"execute":"query-named-block-nodes"}' 2>/dev/null \
    | python3 -c "
import json,sys
node=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
for n in d.get('return',[]):
    if n.get('node-name')==node:
        print(json.dumps([b.get('name') for b in n.get('dirty-bitmaps',[])])); sys.exit(0)
sys.exit(4)" "$1"
}

if [[ "$PLAN_MODE" == true ]]; then
  printf 'PLAN (read-only; mutates nothing)\n'
  printf 'RUN_ID: %s  namespace=%s  evidence=%s\n' "$RUN_ID" "$NAMESPACE" "$FOLLOWUP_DIR"
  printf '  L1 snapshot: VMI/VM state, tracker, checkpoint XML, both disks QEMU bitmaps, wedged %s\n' "$WEDGED"
  printf '  L2 delete the wedged CR ONLY (%s); its PVC %s is kept\n' "$WEDGED" "vm-incremental-pvc-${RUN_ID}-p02"
  printf '  L3 patch %s status.latestCheckpoint.volumes -> [{vda,rootdisk}] (merge patch on the status subresource), read back at +0s and +30s to detect a controller revert\n' "$TRACKER"
  printf '  L4 create %s + %s (30Gi) in the workflow schema\n' "$NEW_CR" "$NEW_PVC"
  printf '  L5 wait <=20 min, classify: terminal-silent-per-disk-drop (Done=True, Incremental, datadisk missing) | recovered | clean-failure | wedged\n'
  printf '  guards: VMI Running + CBT Enabled; wedged CR present and non-terminal; tracker present and not deleting; free >= 25 GiB before L4; abort a wait below 8 GiB\n'
  exit 0
fi

mkdir -p "$FOLLOWUP_DIR"
exec > >(tee -a "$FOLLOWUP_DIR/leg1.log") 2>&1
printf '=== leg 1 (tracker repair) for %s at %s UTC ===\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- L1: preconditions + snapshot ----------
vmi_phase="$(oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
vmi_cbt="$(oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
[[ "$vmi_phase" == Running && "$vmi_cbt" == Enabled ]] || {
  printf 'PRECONDITION FAILED: VMI phase=%s cbt=%s\n' "${vmi_phase:-?}" "${vmi_cbt:-?}" >&2; exit 3; }
wedged_state="$(backup_condition "$WEDGED")"
printf 'L1 wedged %s state type|done|reason|included = %s\n' "$WEDGED" "$wedged_state"
case "$wedged_state" in absent*) printf 'PRECONDITION FAILED: %s absent\n' "$WEDGED" >&2; exit 3 ;; esac
[[ "$wedged_state" != *"|True|"* ]] || { printf 'PRECONDITION FAILED: %s already terminal\n' "$WEDGED" >&2; exit 3; }
oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q . && {
  printf 'PRECONDITION FAILED: tracker is deleting\n' >&2; exit 3; }
printf 'L1 tracker before: %s\n' "$(tracker_volumes)"
oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/tracker-before-patch.json" 2>/dev/null || true
oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/vmi-before.json" 2>/dev/null || true
oc get vmbackup "$WEDGED" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/wedged-p02-before-delete.yaml" 2>/dev/null || true
pod="$(launcher_pod)"
oc exec -n "$NAMESPACE" "$pod" -c compute -- virsh checkpoint-dumpxml "vm-cbt-demo_vm-${RUN_ID}" \
  "$(oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint.name}')" \
  > "$FOLLOWUP_DIR/checkpoint-dumpxml-before-patch.xml" 2>&1 || true
printf 'L1 checkpoint disks before patch: %s\n' "$(grep -oE "<disk name='[^']+'" "$FOLLOWUP_DIR/checkpoint-dumpxml-before-patch.xml" 2>/dev/null | tr '\n' ' ')"
printf 'L1 QEMU bitmaps before patch: datadisk=%s rootdisk=%s\n' \
  "$(qmp_bitmaps libvirt-2-format || echo '?')" "$(qmp_bitmaps libvirt-4-format || echo '?')"

# ---------- L2: remove the wedged CR (one-backup-per-source lock) ----------
printf '=== L2: delete the wedged CR only (%s) ===\n' "$WEDGED"
t0="$(date -u +%s)"
oc delete vmbackup "$WEDGED" -n "$NAMESPACE" --wait=false > "$FOLLOWUP_DIR/l2-delete.out" 2>&1 || true
for _ in $(seq 1 60); do oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1 || break; sleep 2; done
if oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'L2 wedge not released after 120s; aborting.\n' >&2; exit 4
fi
printf 'L2 released in %ss; PVC %s kept\n' "$(( $(date -u +%s) - t0 ))" "vm-incremental-pvc-${RUN_ID}-p02"

# ---------- L3: repair the tracker so it matches the redefined checkpoint ----------
printf '=== L3: patch tracker status volumes -> [vda/rootdisk] ===\n'
oc patch vmbackuptracker "$TRACKER" -n "$NAMESPACE" --subresource=status --type=merge \
  -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}' \
  > "$FOLLOWUP_DIR/l3-patch.out" 2>&1 || { printf 'L3 patch failed; aborting.\n' >&2; cat "$FOLLOWUP_DIR/l3-patch.out" >&2; exit 5; }
printf 'L3 tracker at +0s: %s\n' "$(tracker_volumes)"
sleep 30
printf 'L3 tracker at +30s: %s\n' "$(tracker_volumes)"
if [[ "$(tracker_volumes)" == *datadisk* ]]; then
  printf 'LEG INVALID: a controller reverted the tracker status to include datadisk; the repair did not stick.\n'
  exit 6
fi

# ---------- L4: new pass against the repaired tracker ----------
free_now="$(pool_free_bytes || echo 0)"
printf '=== L4: create %s (pool free %s bytes) ===\n' "$NEW_CR" "$free_now"
if (( free_now < MIN_FREE_BYTES )); then printf 'REFUSED: pool free < 25 GiB\n' >&2; exit 7; fi
cat <<YAML | oc apply -f - > "$FOLLOWUP_DIR/l4-apply.out" 2>&1 || l4_status=$?
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NEW_PVC}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 30Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: ${NEW_CR}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: ${TRACKER}
  pvcName: ${NEW_PVC}
YAML
printf 'L4 apply exit=%s\n' "${l4_status:-0}"
sed -n '1,4p' "$FOLLOWUP_DIR/l4-apply.out" || true

# ---------- L5: observe and classify ----------
printf '=== L5: wait up to 20 min ===\n'
deadline=$(( $(date -u +%s) + 1200 ))
verdict="wedged"
while :; do
  state="$(backup_condition "$NEW_CR")"
  done_field="${state#*|}"; done_field="${done_field%%|*}"
  if [[ "$done_field" == "True" || "$done_field" == "False" ]]; then verdict="terminal"; break; fi
  (( $(date -u +%s) > deadline )) && { verdict="wedged"; break; }
  now_free="$(pool_free_bytes || echo 999999999)"
  (( now_free < ABORT_FREE_BYTES )) && { verdict="pool_starvation_abort"; break; }
  sleep 15
done
final="$(backup_condition "$NEW_CR")"
inc_field="${final##*|}"; [[ "$inc_field" == "-" ]] && inc_field=""
case "$final" in
  *"|True|"*)
    if [[ "${inc_field}" == *datadisk* ]]; then verdict="recovered-both-disks"
    elif [[ "${inc_field}" == "rootdisk" ]]; then verdict="terminal-silent-per-disk-drop"
    else verdict="terminal-other"; fi ;;
  *"|False|"*) verdict="clean-failure" ;;
esac
printf 'L5 RESULT: %s  state(type|done|reason|included)=%s\n' "$verdict" "$final"
oc get vmbackup "$NEW_CR" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/l5-new-backup.yaml" 2>/dev/null || true
oc get vmbackup "$NEW_CR" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/l5-new-backup.json" 2>/dev/null || true
oc get events -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/l5-events-ns.json" 2>/dev/null || true
jq -r '[.items[]?|select(.reason=="BackupError")]|length' "$FOLLOWUP_DIR/l5-events-ns.json" 2>/dev/null | sed 's/^/L5 BackupError events: /'
oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/tracker-after.json" 2>/dev/null || true
printf 'L5 tracker after: %s\n' "$(tracker_volumes)"
oc exec -n "$NAMESPACE" "$pod" -c compute -- virsh checkpoint-dumpxml "vm-cbt-demo_vm-${RUN_ID}" \
  "$(oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint.name}')" \
  > "$FOLLOWUP_DIR/checkpoint-dumpxml-after.xml" 2>&1 || true
printf 'L5 checkpoint disks after: %s\n' "$(grep -oE "<disk name='[^']+'" "$FOLLOWUP_DIR/checkpoint-dumpxml-after.xml" 2>/dev/null | tr '\n' ' ')"
jq -nc --arg verdict "$verdict" --arg state "$final" \
  '{leg: "leg1-tracker-repair", verdict: $verdict, new_backup_state: $state}' > "$FOLLOWUP_DIR/leg1-result.json"
printf 'leg 1 complete.\n'
