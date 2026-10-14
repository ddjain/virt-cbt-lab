#!/usr/bin/env bash
# CBT-I-07 r01b: CONTINUATION after the r01 trigger's injection-DETECTION bug.
# r01 completed the FULL stage (checkpoint vm-backup-...-11-28-43) and the
# agent stop DID disconnect the agent (launcher: "GuestAgentLifecycle event
# state 2 with reason 2" + "Stopping agent poller ... due to agent
# disconnect" at 11:29:37.92Z), but the trigger polled the VMI condition for
# AgentConnected=False and aborted: on this build the condition is REMOVED
# on disconnect, not set to False. Main then restarted the agent (~11:36Z).
# This continuation re-does the injection with correct detection:
#   (a) stop the agent; confirm via LAUNCHER log "Stopping agent poller ...
#       due to agent disconnect" AND condition absence (both accepted);
#   (b) make e2e TYPE=incremental (the chaos-relevant stage: freeze/thaw
#       must be skipped/fail best-effort; backup must complete);
#   (c) restart the agent; confirm via "Starting agent poller" + condition
#       AgentConnected=True;
#   (d) clean follow-up p02 at API level;
#   (e) all r01 CHECK verdicts.
# Preconditions asserted: full stage intact (run.json + tracker on full
# checkpoint), VMI Running, no p01 objects, no p02 objects.
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
MANIFEST_VARIANT="default"
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
# --- Preconditions (continuation) -------------------------------------------
[[ -f "$ROOT_DIR/runs/$RUN_ID/run.json" ]] || { printf 'run.json missing — full stage not intact.\n' >&2; exit 2; }
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
[[ -n "$full_checkpoint" && "$full_checkpoint" != "null" ]] || { printf 'full checkpoint missing from run.json.\n' >&2; exit 2; }
for obj in "vmbackup/$INCR_BACKUP_NAME" "vmbackup/$RETRY_BACKUP_NAME" "pvc/$RETRY_PVC_NAME"; do
  if oc get "$obj" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf 'Precondition failed: %s already exists — refusing (continuation must start clean).\n' "$obj" >&2
    exit 2
  fi
done
vm_phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$vm_phase" == "Running" ]] || { printf 'Precondition failed: VMI phase=%s (expected Running).\n' "${vm_phase:-gone}" >&2; exit 2; }
tracker_cp="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
[[ "$tracker_cp" == "$full_checkpoint" ]] || { printf 'Precondition failed: tracker=%s expected full=%s.\n' "${tracker_cp:-<empty>}" "$full_checkpoint" >&2; exit 2; }
printf 'I07b run %s continuation: full checkpoint %s intact; VMI Running; tracker consistent.\n' \
  "$RUN_ID" "$full_checkpoint" >&2

agent_cond() {
  oc get vmi "$VM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null || true
}
launcher_pod() {
  oc get pods -n "$NAMESPACE" -l kubevirt.io=virt-launcher \
    --field-selector status.phase=Running -o json | jq -r --arg vm "$VM_NAME" \
    '.items[] | select(.metadata.name | startswith("virt-launcher-" + $vm)) | .metadata.name' | head -1
}
LP="$(launcher_pod)"
[[ -n "$LP" ]] || { printf 'No Running launcher pod — aborting.\n' >&2; exit 2; }
# Agent must be connected at continuation start (Main restarted it after the r01 abort).
agent_before="$(agent_cond)"
[[ "$agent_before" == "True" ]] || { printf 'Precondition failed: AgentConnected=%s (expected True after restart).\n' "${agent_before:-absent}" >&2; exit 2; }
# Baseline freeze/thaw lines for the FULL backup (agent was up; from r01).
oc logs "$LP" -n "$NAMESPACE" -c compute 2>/dev/null \
  | grep -E '"Freezing VMI|"Thawing VMI' \
  >"$EVIDENCE_DIR/launcher-freeze-full.txt" || true
printf 'Continuation preconditions OK (agent True, launcher %s).\n' "$LP" >&2

# --- CHAOS: stop the agent (correct detection: launcher lifecycle line) ------
guest_ssh 'sudo systemctl stop qemu-guest-agent' \
  >"$EVIDENCE_DIR/guest-agent-stop.txt" 2>&1
guest_ssh 'systemctl is-active qemu-guest-agent; systemctl show qemu-guest-agent -p ActiveState,SubState' \
  >>"$EVIDENCE_DIR/guest-agent-stop.txt" 2>&1 || true
stop_marker_seen=""
agent_stopped_at=""
for ((i = 0; i < 60; i++)); do
  cond="$(agent_cond)"
  lifecycle="$(oc logs "$LP" -n "$NAMESPACE" -c compute 2>/dev/null \
    | grep -c 'Stopping agent poller.*due to agent disconnect' || true)"
  printf '%s AgentConnected=%s stop_marker=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${cond:-absent}" "${lifecycle:-0}" | tee -a "$EVIDENCE_DIR/agent-condition-timeline.txt" >&2
  # Disconnected = condition absent/False OR the launcher's disconnect marker (this build REMOVES the condition).
  if [[ ("$cond" == "False" || -z "$cond") && "${lifecycle:-0}" -ge 1 ]] || [[ "$cond" == "False" ]]; then
    # Require the launcher marker when the condition is merely absent, so we
    # never confuse "condition absent on this build" with "agent down".
    if [[ "${lifecycle:-0}" -ge 1 ]]; then
      agent_stopped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      stop_marker_seen="yes"
      break
    fi
  fi
  sleep 5
done
if [[ -z "$agent_stopped_at" ]]; then
  printf 'Agent disconnect not confirmed within 5 min (condition=%s, marker=%s) — aborting.\n' \
    "$(agent_cond)" "${lifecycle:-0}" >&2
  exit 2
fi
printf 'INJECTION CONFIRMED: launcher disconnect marker seen + condition=%s at %s.\n' \
  "$(agent_cond)" "$agent_stopped_at" >&2

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
LP_AFTER="$(launcher_pod)"
if [[ -n "$LP_AFTER" ]]; then
  oc logs "$LP_AFTER" -n "$NAMESPACE" -c compute 2>/dev/null \
    | grep -Ei 'freez|thaw|agent poller|GuestAgentLifecycle|quiesc' \
    >"$EVIDENCE_DIR/launcher-freeze-p01-agent-down.txt" || true
fi
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
  start_marker="$(oc logs "$(launcher_pod)" -n "$NAMESPACE" -c compute 2>/dev/null \
    | grep -c 'Starting agent poller with commands' || true)"
  printf '%s AgentConnected=%s start_marker=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${cond:-absent}" "${start_marker:-0}" | tee -a "$EVIDENCE_DIR/agent-condition-timeline.txt" >&2
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
if [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  completed_check="PASS (p01 completed successfully with agent down)"
elif [[ "$p01_done" == "True" && -n "$p01_reason" ]]; then
  completed_check="PASS-with-warning (Done=True reason=$p01_reason)"
else
  completed_check="FAIL (p01 failed with agent down: Done=${p01_done:-absent} reason=${p01_reason:-absent} — violates best-effort contract)"
fi
printf 'CHECK backup-completes-best-effort: %s\n' "$completed_check" >&2
verdict_notes+=("backup-completes-best-effort:$completed_check")
if [[ "$p01_type" == "Incremental" ]]; then
  type_check="PASS (type stays Incremental; checkpoint ${p01_cp:-none})"
else
  type_check="FINDING (p01 type=${p01_type:-absent})"
fi
printf 'CHECK no-silent-full-conversion: %s\n' "$type_check" >&2
verdict_notes+=("no-silent-full-conversion:$type_check")
if [[ "$tracker_final_cp" == "$p01_cp" && -n "$p01_cp" ]]; then
  tracker_check="PASS (tracker advanced exactly to p01 checkpoint)"
else
  tracker_check="FINDING (tracker=${tracker_final_cp:-<empty>} expected p01=${p01_cp:-none})"
fi
printf 'CHECK tracker-consistency: %s\n' "$tracker_check" >&2
verdict_notes+=("tracker-consistency:$tracker_check")
agent_final="$(agent_cond)"
if [[ "$agent_final" == "True" ]]; then
  agent_check="PASS (agent reconnected at ${agent_restarted_at:-?})"
else
  agent_check="FAIL (AgentConnected=$agent_final after restart)"
fi
printf 'CHECK agent-recovery: %s\n' "$agent_check" >&2
verdict_notes+=("agent-recovery:$agent_check")
vm_health="$([[ "$vm_phase_after" == Running ]] && echo "PASS (VMI Running)" || echo "FAIL (VMI phase=${vm_phase_after:-gone})")"
printf 'CHECK vm-health: %s\n' "$vm_health" >&2
verdict_notes+=("vm-health:$vm_health")
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
