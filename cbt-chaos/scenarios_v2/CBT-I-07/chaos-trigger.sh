#!/usr/bin/env bash
# CBT-I-07: stop the qemu guest agent INSIDE the VM before the incremental
# backup (Jira: "Verify the documented best-effort behavior when the guest
# agent cannot freeze and thaw the VM filesystem during backup").
#
# Design:
#  - Full stage normally (baseline + full checkpoint).
#  - PRE-CONDITION chaos (Jira phase): stop qemu-guest-agent in the guest
#    through the workflow's own guest_ssh helper (SSH path, NOT the
#    guest-agent channel — they are independent). Confirm the disconnected
#    state on the VMI (AgentConnected=False) before the backup starts.
#  - Run make e2e TYPE=incremental: the mutation (SSH) must still succeed;
#    the freeze/thaw attempt must fail or be skipped (best-effort); the
#    backup must COMPLETE with a warning rather than fail. Capture the
#    launcher's freeze/thaw lines for p01 vs the full backup as the
#    decisive product observable.
#  - Recovery (Jira): restart the agent, confirm AgentConnected=True.
#  - Clean follow-up backup: fresh p02 PVC+backup at the API level on the
#    same template AFTER the agent is back (I-02/I-05/I-06 pattern),
#    expected Incremental chained to the p01 checkpoint.
#  - The workflow's restore verification (final planned pass) provides the
#    data-correctness checks for full + cumulative p01.
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
for command in oc jq make tee kubectl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
# I-06 harness lesson: unconditional assignment — .env pre-exports must not
# leak the execution host's variant into this scenario.
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
SSH_SERVICE="vm-ssh-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
RETRY_BACKUP_NAME="vm-incremental-${RUN_ID}-p02"
RETRY_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p02"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-07/runs/$RUN_ID"
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
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'I07 run %s: guest-agent stop before incremental (variant %s).\n' \
  "$RUN_ID" "$MANIFEST_VARIANT" >&2

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

# --- Pre-chaos assertion: agent must be CONNECTED before we stop it ----------
agent_cond() {
  oc get vmi "$VM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null || true
}
agent_before="$(agent_cond)"
if [[ "$agent_before" != "True" ]]; then
  printf 'Precondition failed: AgentConnected=%s (expected True) — aborting.\n' \
    "${agent_before:-absent}" >&2
  exit 2
fi
launcher_pod="$(oc get pods -n "$NAMESPACE" -l kubevirt.io=virt-launcher \
  --field-selector status.phase=Running -o json | jq -r --arg vm "$VM_NAME" \
  '.items[] | select(.metadata.name | startswith("virt-launcher-" + $vm)) | .metadata.name' | head -1)"
if [[ -z "$launcher_pod" ]]; then
  printf 'Precondition failed: no Running launcher pod for %s — aborting.\n' "$VM_NAME" >&2
  exit 2
fi
# Baseline: freeze/thaw lines for the FULL backup (agent was up).
oc logs "$launcher_pod" -n "$NAMESPACE" -c compute 2>/dev/null \
  | grep -E '"Freezing VMI|"Thawing VMI|agent poller' \
  >"$EVIDENCE_DIR/launcher-freeze-full.txt" || true
printf 'Agent connected before chaos: %s (launcher %s).\n' "$agent_before" "$launcher_pod" >&2

# --- CHAOS: stop the guest agent from inside the VM ---------------------------
guest_ssh 'sudo systemctl stop qemu-guest-agent' \
  >"$EVIDENCE_DIR/guest-agent-stop.txt" 2>&1
printf 'Guest agent stop command issued (exit 0).\n' >&2
guest_ssh 'systemctl is-active qemu-guest-agent; systemctl show qemu-guest-agent -p ActiveState,SubState' \
  >>"$EVIDENCE_DIR/guest-agent-stop.txt" 2>&1 || true
# Confirm the disconnected state on the VMI (poller cadence; allow 5 min).
agent_stopped_at=""
for ((i = 0; i < 60; i++)); do
  cond="$(agent_cond)"
  printf '%s AgentConnected=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${cond:-absent}" | tee -a "$EVIDENCE_DIR/agent-condition-timeline.txt" >&2
  if [[ "$cond" == "False" ]]; then
    agent_stopped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    break
  fi
  sleep 5
done
if [[ -z "$agent_stopped_at" ]]; then
  printf 'Agent never reached AgentConnected=False within 5 min — aborting (injection unverified).\n' >&2
  exit 2
fi
printf 'INJECTION CONFIRMED: AgentConnected=False at %s.\n' "$agent_stopped_at" >&2

# --- Stage 2: incremental with the agent down --------------------------------
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2

# --- Evidence: p01 terminal state + freeze/thaw during agent-down window -----
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/incremental-backup-p01.yaml" 2>/dev/null || true
p01_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
p01_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
p01_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
p01_cp="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'P01 TERMINAL STATE: Done=%s reason=%s type=%s checkpoint=%s\n' \
  "${p01_done:-unknown}" "${p01_reason:-unknown}" "${p01_type:-unknown}" "${p01_cp:-none}" >&2
# Launcher freeze/thaw lines for p01 (agent down) — decisive observable.
launcher_pod_after="$(oc get pods -n "$NAMESPACE" -l kubevirt.io=virt-launcher \
  --field-selector status.phase=Running -o json | jq -r --arg vm "$VM_NAME" \
  '.items[] | select(.metadata.name | startswith("virt-launcher-" + $vm)) | .metadata.name' | head -1)"
if [[ -n "$launcher_pod_after" ]]; then
  oc logs "$launcher_pod_after" -n "$NAMESPACE" -c compute 2>/dev/null \
    | grep -E '"Freezing VMI|"Thawing VMI|agent poller|freeze|agent' \
    >"$EVIDENCE_DIR/launcher-freeze-p01-agent-down.txt" || true
fi
# Warning events on the backup/VM during the agent-down window.
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
  | grep -iE 'quiesc|freeze|agent|warn' \
  >"$EVIDENCE_DIR/agent-down-events.txt" || true
# Tracker: poll for 2 minutes.
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
vm_phase_after="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
printf 'VM after incremental: phase=%s.\n' "${vm_phase_after:-gone}" >&2

# --- RECOVERY: restart the guest agent ---------------------------------------
guest_ssh 'sudo systemctl start qemu-guest-agent' \
  >"$EVIDENCE_DIR/guest-agent-start.txt" 2>&1
agent_restarted_at=""
for ((i = 0; i < 60; i++)); do
  cond="$(agent_cond)"
  printf '%s AgentConnected=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${cond:-absent}" | tee -a "$EVIDENCE_DIR/agent-condition-timeline.txt" >&2
  if [[ "$cond" == "True" ]]; then
    agent_restarted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    break
  fi
  sleep 5
done
printf 'RECOVERY: AgentConnected=%s at %s (expected True).\n' \
  "$(agent_cond)" "${agent_restarted_at:-never}" >&2

# --- Clean follow-up backup: p02 at API level with the agent back ------------
printf 'Follow-up: applying fresh destination %s + backup %s (template, pass-02 names).\n' \
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
followup_result="FAIL (p02 did not reach Done in 20m)"
if oc wait "vmbackup/$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
    --for=condition=Done --timeout=20m 2>/dev/null; then
  retry_type="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}')"
  retry_cp="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}')"
  retry_reason="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
  if [[ "$retry_type" == "Incremental" && "$retry_reason" == "Successfully completed VirtualMachineBackup" ]]; then
    followup_result="PASS (p02 Incremental, checkpoint ${retry_cp:-?}, clean success)"
  else
    followup_result="FINDING (p02 type=$retry_type reason=${retry_reason:-?})"
  fi
  oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
else
  oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
fi
printf 'CHECK clean-follow-up-backup: %s\n' "$followup_result" >&2

# --- Verdict checks ----------------------------------------------------------
verdict_notes=()
# (a) backup completes (with warning) rather than fails — best-effort contract
if [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  completed_check="PASS (p01 completed successfully with agent down)"
elif [[ "$p01_done" == "True" && -n "$p01_reason" ]]; then
  completed_check="PASS-with-warning (Done=True reason=$p01_reason)"
else
  completed_check="FAIL (p01 failed with agent down: Done=${p01_done:-absent} reason=${p01_reason:-absent} — violates best-effort contract)"
fi
printf 'CHECK backup-completes-best-effort: %s\n' "$completed_check" >&2
verdict_notes+=("backup-completes-best-effort:$completed_check")
# (b) type stays Incremental
if [[ "$p01_type" == "Incremental" ]]; then
  type_check="PASS (type stays Incremental; checkpoint ${p01_cp:-none})"
else
  type_check="FINDING (p01 type=${p01_type:-absent})"
fi
printf 'CHECK no-silent-full-conversion: %s\n' "$type_check" >&2
verdict_notes+=("no-silent-full-conversion:$type_check")
# (c) tracker consistency
if [[ "$tracker_final_cp" == "$p01_cp" && -n "$p01_cp" ]]; then
  tracker_check="PASS (tracker advanced exactly to p01 checkpoint)"
else
  tracker_check="FINDING (tracker=${tracker_final_cp:-<empty>} expected p01=${p01_cp:-none})"
fi
printf 'CHECK tracker-consistency: %s\n' "$tracker_check" >&2
verdict_notes+=("tracker-consistency:$tracker_check")
# (d) agent recovery
agent_final="$(agent_cond)"
if [[ "$agent_final" == "True" ]]; then
  agent_check="PASS (agent reconnected at ${agent_restarted_at:-?})"
else
  agent_check="FAIL (AgentConnected=$agent_final after restart)"
fi
printf 'CHECK agent-recovery: %s\n' "$agent_check" >&2
verdict_notes+=("agent-recovery:$agent_check")
# (e) VM health
vm_health="$([[ "$vm_phase_after" == Running ]] && echo "PASS (VMI Running)" || echo "FAIL (VMI phase=${vm_phase_after:-gone})")"
printf 'CHECK vm-health: %s\n' "$vm_health" >&2
verdict_notes+=("vm-health:$vm_health")
# (f) data correctness — workflow restore verification (stage verdict)
verify_json="$ROOT_DIR/runs/$RUN_ID/fragments/verify.json"
if [[ -f "$verify_json" ]]; then
  verify_verdict="$(jq -r '.verdict // empty' "$verify_json" 2>/dev/null || true)"
  data_check="stage-verification=$verify_verdict (see runs/$RUN_ID/ test-run evidence)"
else
  data_check="stage-verification=absent (run restore verification manually)"
fi
printf 'CHECK data-correctness: %s\n' "$data_check" >&2
verdict_notes+=("data-correctness:$data_check")
printf 'I07 VERDICT NOTES: %s\n' "${verdict_notes[*]}" >&2
printf 'Scenario complete: guest-agent-down backup evidence collected (p01 outcome, freeze/thaw logs, agent timeline, p02 follow-up).\n' >&2
exit 0
