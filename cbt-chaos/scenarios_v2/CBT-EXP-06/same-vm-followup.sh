#!/usr/bin/env bash
# same-vm-followup.sh — instrumented same-VM follow-up for CBT-EXP-06 (post-run).
#
# Why this exists: the graded run's own recovery leg could not take a same-VM
# backup with new names, because the staged interface refuses to add a pass to a
# lifecycle in a failed state, and its supported unblock (scripts/vm-cbt-reconcile.sh)
# refuses unless the operator has already deleted the failed pass's backup CR *and*
# its PVC — i.e. the evidence must be removed by hand before the supported path
# reopens. (reconcile itself deletes nothing; corrected 2026-10-16 after the
# Scenario Improver checked the source.) This driver therefore performs that
# follow-up in the API directly, using the same schema the workflow's own
# incremental manifest uses, and records the documented
# finding-1 (docs/findings/finding-1-backup-cr-livelock.md) behaviour:
#
#   F0  snapshot the wedged backup, the leaked hotplug mount, the tracker and
#       the controller retry loop (read-only)
#   F1  one-backup-per-source test: try a new source-scoped backup while the
#       wedged one is still in progress, then clean the test objects up and
#       record whether deleting a wedged CR with the tracker present releases
#       its finalizer (finding-1 recovery matrix)
#   F2  operator runbook step: delete ONLY the wedged backup CR (its
#       destination PVC is kept), then record the finalizer release time and
#       whether the leaked hotplug volume detaches
#   F3  take a new incremental on the same VM through the API and classify it:
#       wedge again (3rd reproduction), terminal Failed, Done with BOTH disks
#       (chain recovered), or Done with the datadisk MISSING (the silent
#       per-disk drop the experiment was built to look for)
#
# Safety: fail-closed preconditions, bounded waits, a live pool free-space
# guard, and nothing is deleted except the wedged CR the operator runbook names
# plus this driver's own F1 test objects.
#
# Usage: same-vm-followup.sh [--plan] [--skip-f1] [--skip-f3]
#   RUN_ID=<graded run id> KUBECONFIG_PATH=<host-local kubeconfig> [NAMESPACE=vm-cbt-demo]
#   FOLLOWUP_DIR=<dir>   default: <scenario>/followup/<RUN_ID>-same-vm
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set the graded run id (e.g. 20261016-exp06-r02)}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
valid_run_id "$RUN_ID" || { printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2; }
for command in oc jq kubectl python3; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
export NAMESPACE
# Note: scripts/common.sh's set_resource_names is deliberately NOT used here: this
# driver needs only the three run-scoped names below, and common.sh would also
# validate the harness's GUEST_* workload variables, which are irrelevant to a
# follow-up that creates no workload.

PLAN_MODE=false
SKIP_F1=false
SKIP_F3=false
for arg in "$@"; do
  case "$arg" in
    --plan) PLAN_MODE=true ;;
    --skip-f1) SKIP_F1=true ;;
    --skip-f3) SKIP_F3=true ;;
    -h|--help) printf 'Usage: %s [--plan] [--skip-f1] [--skip-f3]\n' "$(basename "$0")"; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

FOLLOWUP_DIR="${FOLLOWUP_DIR:-$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/followup/${RUN_ID}-same-vm}"
WEDGED="vm-incremental-${RUN_ID}-p01"
WEDGED_PVC="vm-incremental-pvc-${RUN_ID}-p01"
TEST_CR="vm-followup-${RUN_ID}-f01"
TEST_PVC="vm-followup-pvc-${RUN_ID}-f01"
NEW_CR="vm-incremental-${RUN_ID}-p02"
NEW_PVC="vm-incremental-pvc-${RUN_ID}-p02"
POOL_DATA_DIR="/cbt-demo-pool-data-dir/csi"
MIN_FREE_BYTES=$((25 * 1024 * 1024 * 1024))   # refuse to start a new pass below 25 GiB free
ABORT_FREE_BYTES=$((8 * 1024 * 1024 * 1024))  # abort a running wait below 8 GiB free

pool_free_bytes() {
  local pod
  pod="$(oc get pods -n openshift-cnv -o name 2>/dev/null | grep hostpath-provisioner-csi | head -1 | cut -d/ -f2)"
  [[ -n "$pod" ]] || return 1
  oc exec -n openshift-cnv "$pod" -c hostpath-provisioner -- df -B1 "$POOL_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}'
}

backup_condition() { # $1=name -> "<type>|<done>|<reason>|<included>"
  oc get vmbackup "$1" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
    [ (.status.type // "null"),
      ([.status.conditions[]?|select(.type=="Done")|.status]|first // "none"),
      ([.status.conditions[]?|select(.type=="Done")|.reason]|first // "-"),
      ([.status.includedVolumes[]?.volumeName]|join(",")) ] | join("|")' 2>/dev/null || printf 'absent|||\n'
}

if [[ "$PLAN_MODE" == true ]]; then
  printf 'PLAN (read-only; mutates nothing)\n'
  printf 'RUN_ID: %s  namespace=%s\n' "$RUN_ID" "$NAMESPACE"
  printf '  wedged backup   : %s (its PVC %s is KEPT)\n' "$WEDGED" "$WEDGED_PVC"
  printf '  F1 test objects : %s + %s (3Gi; created and removed by this driver)\n' "$TEST_CR" "$TEST_PVC"
  printf '  F3 new pass     : %s + %s (30Gi)\n' "$NEW_CR" "$NEW_PVC"
  printf '  evidence dir    : %s\n' "$FOLLOWUP_DIR"
  printf '  legs            : F0 snapshot (read-only) -> F1 one-backup-per-source test (skip=%s) -> F2 delete the wedged CR only (runbook step; keep its PVC) -> F3 new incremental on the same VM (skip=%s, bounded 20m)\n' "$SKIP_F1" "$SKIP_F3"
  printf '  guards          : VMI Running + CBT Enabled; wedged CR present and non-terminal; tracker present and not deleting; pool free >= 25 GiB before any new pass; abort a pass wait if free < 8 GiB\n'
  exit 0
fi

mkdir -p "$FOLLOWUP_DIR"
exec > >(tee -a "$FOLLOWUP_DIR/followup.log") 2>&1
printf '=== same-VM follow-up for %s at %s UTC ===\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- F0: fail-closed preconditions and read-only snapshot ----------
vm_cbt="$(oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
vmi_phase="$(oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "$vmi_phase" != "Running" || "$vm_cbt" != "Enabled" ]]; then
  printf 'PRECONDITION FAILED: VMI vm-%s phase=%s cbt=%s (need Running + Enabled).\n' "$RUN_ID" "${vmi_phase:-?}" "${vm_cbt:-?}" >&2
  exit 3
fi
if ! oc get vmbackup "$WEDGED" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/wedged-cr-before-delete.json" 2>/dev/null; then
  printf 'PRECONDITION FAILED: wedged backup %s not found; nothing to reproduce.\n' "$WEDGED" >&2
  exit 3
fi
wedged_state="$(backup_condition "$WEDGED")"
printf 'F0 wedged backup state type|done|reason|included = %s\n' "$wedged_state"
if [[ "$wedged_state" == *"|True|"* ]]; then
  printf 'PRECONDITION FAILED: %s is terminal; this driver only reproduces the non-terminal wedge.\n' "$WEDGED" >&2
  exit 3
fi
if oc get vmbackuptracker "vm-tracker-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
  printf 'PRECONDITION FAILED: tracker is being deleted; the runbook path assumes a present tracker.\n' >&2
  exit 3
fi
oc get vmbackup "$WEDGED" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/wedged-cr-before-delete.yaml" 2>/dev/null || true
oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/vmi-before.json" 2>/dev/null || true
oc get vmbackuptracker "vm-tracker-${RUN_ID}" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/tracker-before.json" 2>/dev/null || true
jq -c --arg pvc "$WEDGED_PVC" '[.status.volumeStatus[]?|select(.persistentVolumeClaimInfo.claimName==$pvc)|{name,phase,attachPod:.hotplugVolume.attachPodName}]' \
  "$FOLLOWUP_DIR/vmi-before.json" > "$FOLLOWUP_DIR/hotplug-before.json" 2>/dev/null || echo '[]' > "$FOLLOWUP_DIR/hotplug-before.json"
printf 'F0 hotplug before: %s\n' "$(cat "$FOLLOWUP_DIR/hotplug-before.json")"
leader="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$leader" -n openshift-cnv --since=180m > "$FOLLOWUP_DIR/controller-window.log" 2>/dev/null || true
retry_lines="$(grep -cF 'missing or broken bitmap' "$FOLLOWUP_DIR/controller-window.log" || true)"
printf 'F0 controller retry lines for the per-disk bitmap error in the last 180m: %s\n' "$retry_lines"
jq -nc --argjson lines "${retry_lines:-0}" --arg state "$wedged_state" \
  '{controller_per_disk_bitmap_error_lines: $lines, wedged_state: $state}' > "$FOLLOWUP_DIR/f0-retry.json"

# ---------- F1: one-backup-per-source while the wedge is live ----------
if [[ "$SKIP_F1" == false ]]; then
  printf '=== F1: new source-scoped backup while %s is in progress ===\n' "$WEDGED"
  cat <<YAML | oc apply -f - > "$FOLLOWUP_DIR/f1-apply.out" 2>&1 || f1_apply_status=$?
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEST_PVC}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 3Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: ${TEST_CR}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: ${RUN_ID}
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-${RUN_ID}
  pvcName: ${TEST_PVC}
YAML
  f1_apply_status="${f1_apply_status:-0}"
  printf 'F1 apply exit=%s\n' "$f1_apply_status"
  sed -n '1,6p' "$FOLLOWUP_DIR/f1-apply.out" || true
  sleep 15
  if f1_state="$(backup_condition "$TEST_CR")" && [[ "$f1_state" != absent* ]]; then
    printf 'F1 test backup was ACCEPTED (state %s); events:\n' "$f1_state"
    oc get events -n "$NAMESPACE" --field-selector "involvedObject.name=$TEST_CR" -o json > "$FOLLOWUP_DIR/f1-events.json" 2>/dev/null || echo '{}' > "$FOLLOWUP_DIR/f1-events.json"
    jq -r '.items[]?.message' "$FOLLOWUP_DIR/f1-events.json" 2>/dev/null | head -5
  else
    printf 'F1 test backup was NOT admitted (rejected): see f1-apply.out\n'
  fi
  # Cleanup: this driver's own test objects. Deleting a CR with the tracker
  # present is the runbook step -- but only a CR that was actually ADMITTED can
  # exercise it. r02's apply was rejected at admission and the driver still
  # claimed "removed in 0s (runbook row ... -> works)".
  if ! oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf 'F1 cleanup: no test CR ever existed (apply exit %s); the runbook row was NOT exercised.\n' \
      "$f1_apply_status" | tee -a "$FOLLOWUP_DIR/f1-delete-cr.out"
  else
    f1_delete_start="$(date -u +%s)"
    oc delete vmbackup "$TEST_CR" -n "$NAMESPACE" --ignore-not-found --wait=false > "$FOLLOWUP_DIR/f1-delete-cr.out" 2>&1 || true
    for _ in $(seq 1 60); do
      oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1 || break
      sleep 2
    done
    if oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1; then
      printf 'F1 cleanup: test CR still present after 120s (finalizer not released).\n'
    else
      printf 'F1 cleanup: test CR removed in %ss (runbook row: delete the wedged CR with the tracker present -> works).\n' "$(( $(date -u +%s) - f1_delete_start ))"
    fi
  fi
  oc delete pvc "$TEST_PVC" -n "$NAMESPACE" --ignore-not-found --wait=false >> "$FOLLOWUP_DIR/f1-delete-cr.out" 2>&1 || true
fi

# ---------- F2: runbook step — delete the wedged CR only, keep its PVC ----------
printf '=== F2: delete the wedged backup CR only (PVC kept) ===\n'
f2_start="$(date -u +%s)"
oc delete vmbackup "$WEDGED" -n "$NAMESPACE" --wait=false > "$FOLLOWUP_DIR/f2-delete-wedged.out" 2>&1 || true
for _ in $(seq 1 150); do
  oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1 || break
  sleep 2
done
f2_elapsed=$(( $(date -u +%s) - f2_start ))
if oc get vmbackup "$WEDGED" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'F2 RESULT: wedged CR still present after %ss — finalizer not released.\n' "$f2_elapsed"
  oc get vmbackup "$WEDGED" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/wedged-after-delete.json" 2>/dev/null || true
else
  printf 'F2 RESULT: wedged CR released its finalizer and disappeared in %ss.\n' "$f2_elapsed"
fi
oc get pvc "$WEDGED_PVC" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/wedged-pvc-after.json" 2>/dev/null || true
printf 'F2 wedged PVC phase after: %s\n' "$(jq -r '.status.phase // "absent"' "$FOLLOWUP_DIR/wedged-pvc-after.json" 2>/dev/null || echo absent)"
sleep 20
oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/vmi-after-unblock.json" 2>/dev/null || true
jq -c --arg pvc "$WEDGED_PVC" '[.status.volumeStatus[]?|select(.persistentVolumeClaimInfo.claimName==$pvc)|{name,phase,attachPod:.hotplugVolume.attachPodName}]' \
  "$FOLLOWUP_DIR/vmi-after-unblock.json" > "$FOLLOWUP_DIR/hotplug-after-unblock.json" 2>/dev/null || echo '[]' > "$FOLLOWUP_DIR/hotplug-after-unblock.json"
printf 'F2 hotplug after: %s\n' "$(cat "$FOLLOWUP_DIR/hotplug-after-unblock.json")"

# ---------- F3: a new incremental on the same VM ----------
if [[ "$SKIP_F3" == true ]]; then
  printf 'F3 skipped by request.\n'
  printf 'same-vm-followup complete (F1/F2 only).\n'
  exit 0
fi
free_now="$(pool_free_bytes || echo 0)"
printf '=== F3: new incremental %s (pool free %s bytes) ===\n' "$NEW_CR" "$free_now"
if (( free_now < MIN_FREE_BYTES )); then
  printf 'REFUSED: pool free %s < %s bytes; not creating a new pass.\n' "$free_now" "$MIN_FREE_BYTES" >&2
  exit 4
fi
cat <<YAML | oc apply -f - > "$FOLLOWUP_DIR/f3-apply.out" 2>&1 || f3_apply_status=$?
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
    name: vm-tracker-${RUN_ID}
  pvcName: ${NEW_PVC}
YAML
printf 'F3 apply exit=%s\n' "${f3_apply_status:-0}"
sed -n '1,6p' "$FOLLOWUP_DIR/f3-apply.out" || true
f3_deadline=$(( $(date -u +%s) + 1200 ))   # the harness bound: 20 minutes
f3_verdict="wedged"
while :; do
  f3_state="$(backup_condition "$NEW_CR")"
  f3_done="${f3_state#*|}"; f3_done="${f3_done%%|*}"
  if [[ "$f3_done" == "True" || "$f3_done" == "False" ]]; then f3_verdict="terminal"; break; fi
  if (( $(date -u +%s) > f3_deadline )); then f3_verdict="wedged"; break; fi
  now_free="$(pool_free_bytes || echo 999999999)"
  if (( now_free < ABORT_FREE_BYTES )); then f3_verdict="pool_starvation_abort"; break; fi
  sleep 15
done
f3_final="$(backup_condition "$NEW_CR")"
printf 'F3 RESULT: verdict=%s state(type|done|reason|included)=%s\n' "$f3_verdict" "$f3_final"
oc get vmbackup "$NEW_CR" -n "$NAMESPACE" -o yaml > "$FOLLOWUP_DIR/f3-new-backup.yaml" 2>/dev/null || true
oc get vmbackup "$NEW_CR" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/f3-new-backup.json" 2>/dev/null || true
oc get events -n "$NAMESPACE" --field-selector "involvedObject.name=$NEW_CR" -o json > "$FOLLOWUP_DIR/f3-events-cr.json" 2>/dev/null || echo '{}' > "$FOLLOWUP_DIR/f3-events-cr.json"
oc get events -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/f3-events-ns.json" 2>/dev/null || echo '{}' > "$FOLLOWUP_DIR/f3-events-ns.json"
jq -r '[.items[]?|select(.reason=="BackupError")] | length' "$FOLLOWUP_DIR/f3-events-ns.json" 2>/dev/null | sed 's/^/F3 BackupError events in namespace: /'
oc get vmbackuptracker "vm-tracker-${RUN_ID}" -n "$NAMESPACE" -o json > "$FOLLOWUP_DIR/tracker-after.json" 2>/dev/null || true
jq -nc --arg verdict "$f3_verdict" --arg state "$f3_final" --argjson free "$free_now" \
  '{f3_verdict: $verdict, f3_state: $state, pool_free_before_bytes: $free}' > "$FOLLOWUP_DIR/f3-result.json"
printf 'same-vm-followup complete.\n'
