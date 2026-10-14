#!/usr/bin/env bash
# CBT-I-06: delete the virt-handler pod on the CBT worker node during the
# active incremental copy (Jira: "interruption of the node-level backup
# handler during bitmap copying does not silently change an incremental
# backup into an incorrect full backup").
#
# Design (source-verified against krkn pod_disruption + k8s_trigger):
#  - krknctl pod-scenarios, started BEFORE the incremental stage so image
#    startup is absorbed early; the disruption is gated by krkn's NATIVE
#    k8s trigger on the p01 vmbackup's Progressing condition
#    (status.conditions.0.status == True — index 0 verified live on this
#    build's condition order), 2s poll.
#  - Target: --namespace openshift-cnv --node-names ["d38-h18-000-r660"]
#    --name-pattern 'virt-handler-.*' --force (grace 0, Jira "Immediate").
#    The node is asserted at runtime from the VM's actual placement.
#  - Expected: incremental recovers or fails cleanly; type must stay
#    Incremental (silent full-conversion = FAIL finding); tracker consistent;
#    handler auto-restarts (DaemonSet; krkn checks recovery in 120s).
#  - Post-chaos same-VM retry: fresh p02 PVC+backup at the API level on the
#    same template (I-02/I-05 pattern) to prove the chain survives.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID for this full+incremental lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
if ! valid_run_id "$RUN_ID"; then
  printf 'Invalid RUN_ID format: %s\n' "$RUN_ID" >&2
  exit 2
fi
for command in oc jq make tee kubectl krknctl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="${MANIFEST_VARIANT:-default}"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
RETRY_BACKUP_NAME="vm-incremental-${RUN_ID}-p02"
RETRY_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p02"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-06/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists in this checkout.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
  exit 2
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  printf 'Refusing to run: %s already exists in this checkout.\n' "$EVIDENCE_DIR" >&2
  exit 2
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Refusing to run: resources for %s already exist in %s.\n' "$RUN_ID" "$NAMESPACE" >&2
  exit 2
fi
# DaemonSet health precondition: exactly one Running virt-handler on the CBT node.
HANDLER_POD_BEFORE="$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler \
  --field-selector status.phase=Running -o json | jq -r \
  '.items[] | select(.spec.nodeName == "d38-h18-000-r660") | .metadata.name' | head -1)"
if [[ -z "$HANDLER_POD_BEFORE" ]]; then
  printf 'No Running virt-handler on the CBT node d38-h18-000-r660 — aborting.\n' >&2
  exit 2
fi
printf 'Handler pod before chaos: %s\n' "$HANDLER_POD_BEFORE"
# I-04 capacity guard: HostPath pool free space (default variant writes there).
POOL_FREE_KIB="$(oc debug node/d38-h18-000-r660 --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 400 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB < 400GiB floor) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'I06 run %s: node %s, handler %s, pool free %s KiB.\n' \
  "$RUN_ID" "d38-h18-000-r660" "$HANDLER_POD_BEFORE" "$POOL_FREE_KIB" >&2

# --- Stage 1: full backup (baseline + full checkpoint) -----------------------
full_status=0
if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  full_status=0
else
  full_status=$?
fi
if ((full_status != 0)); then
  printf 'Full stage failed (%d) — aborting scenario.\n' "$full_status" >&2
  exit "$full_status"
fi
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
printf 'Full stage complete (checkpoint: %s).\n' "$full_checkpoint" >&2

# Assert the VM really is on the expected node before arming.
vm_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
if [[ "$vm_node" != "d38-h18-000-r660" ]]; then
  printf 'VM is on node %s (expected d38-h18-000-r660) — handler target mismatch, aborting.\n' "$vm_node" >&2
  exit 2
fi
printf 'VM placement confirmed: %s on %s.\n' "$VM_NAME" "$vm_node" >&2

# --- Stage 2: krkn pod-scenarios (native trigger) + incremental stage --------
# Started before the stage; the k8s trigger gates the kill on the p01
# vmbackup's Progressing condition (copy active). Interval 2s; the copy
# window is 16-21s on this variant.
krkn_log="$EVIDENCE_DIR/krkn-pod-scenarios.log"
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --node-names '["d38-h18-000-r660"]' \
  --name-pattern 'virt-handler-.*' \
  --disruption-count 1 \
  --force=true \
  --expected-recovery-time 120 \
  --trigger-k8s-api-version backup.kubevirt.io/v1alpha1 \
  --trigger-k8s-kind VirtualMachineBackup \
  --trigger-k8s-namespace "$NAMESPACE" \
  --trigger-k8s-name "$INCR_BACKUP_NAME" \
  --trigger-k8s-condition 'status.conditions.0.status == True' \
  --triggers-interval 2 \
  --triggers-timeout 900 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krkn_log" 2>&1 &
krkn_pid=$!
printf 'krkn pod-scenarios armed (pid=%s); trigger gate: %s Progressing.\n' \
  "$krkn_pid" "$INCR_BACKUP_NAME" >&2

if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2

# Wait for krkn to finish (kill + recovery verification).
krkn_status=0
if wait "$krkn_pid"; then
  krkn_status=0
else
  krkn_status=$?
fi
printf 'krkn exit status: %d (log: %s).\n' "$krkn_status" "$krkn_log" >&2

# --- Evidence: p01 terminal state, handler replacement, tracker -------------
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/incremental-backup-p01.yaml" 2>/dev/null || true
p01_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
p01_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
p01_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
p01_cp="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'P01 TERMINAL STATE: Done=%s reason=%s type=%s checkpoint=%s\n' \
  "${p01_done:-unknown}" "${p01_reason:-unknown}" "${p01_type:-unknown}" "${p01_cp:-none}" >&2
HANDLER_POD_AFTER="$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler \
  --field-selector spec.nodeName=d38-h18-000-r660 -o json | jq -r '.items[0].metadata.name')"
printf 'Handler pod after chaos: %s (before: %s).\n' "$HANDLER_POD_AFTER" "$HANDLER_POD_BEFORE" >&2
handler_replaced="$([[ -n "$HANDLER_POD_AFTER" && "$HANDLER_POD_AFTER" != "$HANDLER_POD_BEFORE" ]] && echo yes || echo no)"
vm_node_after="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)"
vm_phase_after="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
printf 'VM after chaos: node=%s phase=%s.\n' "${vm_node_after:-gone}" "${vm_phase_after:-gone}" >&2

# Tracker: poll for 2 minutes (delayed-clearing semantics check).
tracker_observations="$EVIDENCE_DIR/tracker-observations.txt"
: >"$tracker_observations"
for ((i = 0; i <= 24; i++)); do
  cp_now="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
  printf '%s tracker.latestCheckpoint=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${cp_now:-<empty>}" | tee -a "$tracker_observations" >&2
  ((i < 24)) && sleep 5
done
tracker_final_cp="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"

# --- Verdict checks ----------------------------------------------------------
verdict_notes=()
# (a) recover-or-fail-cleanly
if [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  clean_outcome="PASS (p01 completed successfully despite handler kill)"
elif [[ "$p01_done" == "True" && -n "$p01_reason" && "$p01_reason" != "Successfully completed VirtualMachineBackup" ]]; then
  clean_outcome="PASS (clean failure: Done=True reason=$p01_reason)"
else
  clean_outcome="FAIL (p01 never reached a clean terminal state: Done=${p01_done:-absent})"
fi
printf 'CHECK recover-or-fail-cleanly: %s\n' "$clean_outcome" >&2
verdict_notes+=("recover-or-fail-cleanly:$clean_outcome")

# (b) no silent full conversion
if [[ "$p01_type" == "Incremental" ]]; then
  type_check="PASS (type stays Incremental; checkpoint ${p01_cp:-none})"
elif [[ "$p01_type" == "Full" ]]; then
  type_check="FINDING (p01 type=Full — requires checkpoint-recovery explanation; see events/tracker evidence)"
else
  type_check="FAIL (p01 type unreadable: ${p01_type:-absent})"
fi
printf 'CHECK no-silent-full-conversion: %s\n' "$type_check" >&2
verdict_notes+=("no-silent-full-conversion:$type_check")

# (c) tracker consistency
if [[ "$tracker_final_cp" == "$p01_cp" && -n "$p01_cp" ]]; then
  tracker_check="PASS (tracker advanced exactly to p01 checkpoint)"
elif [[ "$incr_status" != "0" && "$tracker_final_cp" == "$full_checkpoint" ]]; then
  tracker_check="PASS (failed pass; tracker holds FULL checkpoint)"
else
  tracker_check="FINDING (tracker=${tracker_final_cp:-<empty>} expected p01=${p01_cp:-none} or full=$full_checkpoint)"
fi
printf 'CHECK tracker-consistency: %s\n' "$tracker_check" >&2
verdict_notes+=("tracker-consistency:$tracker_check")

# (d) handler recovery + VM health
handler_recovery="$([[ "$handler_replaced" == yes ]] && echo "PASS (pod $HANDLER_POD_BEFORE -> $HANDLER_POD_AFTER; DaemonSet recreation)" || echo "FAIL (handler pod unchanged)")"
printf 'CHECK handler-recovery: %s\n' "$handler_recovery" >&2
verdict_notes+=("handler-recovery:$handler_recovery")
vm_health="$([[ "$vm_phase_after" == Running ]] && echo "PASS (VMI Running on $vm_node_after)" || echo "FAIL (VMI phase=$vm_phase_after)")"
printf 'CHECK vm-health: %s\n' "$vm_health" >&2
verdict_notes+=("vm-health:$vm_health")

# (e) post-chaos same-VM retry (only if the first pass failed; a successful
# pass already proves the chain, and the workflow ran its own verification).
recovery_result="not-needed (p01 succeeded; chain verified by stage verification)"
if ((incr_status != 0)) && [[ "$tracker_final_cp" == "$full_checkpoint" ]]; then
  printf 'Recovery: applying fresh destination %s + backup %s (template, pass-02 names).\n' \
    "$RETRY_PVC_NAME" "$RETRY_BACKUP_NAME" >&2
  sed \
    -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
    -e "s|__INCREMENTAL_BACKUP_NAME__|$RETRY_BACKUP_NAME|g" \
    -e "s|__INCREMENTAL_BACKUP_PVC__|$RETRY_PVC_NAME|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
    -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
    -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
    "$(manifest_path incremental-backup)" | oc apply -f - >/dev/null
  if oc wait "vmbackup/$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
      --for=condition=Done --timeout=20m 2>/dev/null; then
    retry_type="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}')"
    retry_cp="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}')"
    if [[ "$retry_type" == "Incremental" ]]; then
      recovery_result="PASS (p02 Incremental, checkpoint ${retry_cp:-?})"
    else
      recovery_result="FINDING (p02 type=$retry_type — full conversion on retry needs explanation)"
    fi
    oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
      >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
  else
    recovery_result="FAIL (p02 did not reach Done in 20m)"
    oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
      >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
  fi
fi
printf 'CHECK post-chaos-same-vm-retry: %s\n' "$recovery_result" >&2
verdict_notes+=("post-chaos-same-vm-retry:$recovery_result")

# --- Summary ----------------------------------------------------------------
printf 'I06 VERDICT NOTES: %s\n' "${verdict_notes[*]}" >&2
printf 'Scenario complete: handler-interruption evidence collected (p01 outcome, handler replacement, tracker, recovery above).\n' >&2
exit 0
