#!/usr/bin/env bash
# CBT-I-08: stop only the compute (backup execution) container inside the
# VM's launcher during the active incremental copy (Jira: "Verify
# container-level interruption during an incremental copy and compare it
# with complete launcher-pod interruption").
#
# Design (source-verified against krkn container_scenario_plugin.py):
#  - krkn container-scenarios with --action 1. CRITICAL semantics: krkn
#    builds `kill_action = "kill " + str(action)` and runs it via bash -c
#    in the container, so "--action 1" = SIGTERM to PID 1
#    (virt-launcher-monitor), NOT "signal 1". PID-1 exit terminates the
#    launcher pod (restartPolicy Never) -> VMI dies -> virt-controller
#    recreates it (the Jira's "Automatic VM recovery").
#  - Targeting: --label-selector "vm.kubevirt.io/name=vm-<RUN_ID>" (label
#    live-verified on launcher pods) uniquely selects the run's launcher;
#    --container-name compute; --namespace vm-cbt-demo.
#  - Injection window: krkn native k8s trigger on the p01 vmbackup's
#    Progressing condition (I-06-proven pattern), 2s poll.
#  - krkn's own recovery check expects the killed CONTAINER to become ready
#    again, but the launcher pod terminates (restartPolicy Never) and is
#    REPLACED by a new pod; krkn may therefore exit 1 ("unrecovered") —
#    NON-AUTHORITATIVE for this scenario; recovery is judged from cluster
#    state (new launcher Running, VMI Running).
#  - Expected: p01 fails cleanly mid-copy (or completes if the copy beat
#    the kill — documented either way); tracker behavior recorded (hold vs
#    I-02-style CheckpointRedefinitionFailed clearing); VM auto-recovers;
#    fresh p02 chains correctly; FULL artifact verified bit-exact via the
#    direct full-only restore verifier (I-05/I-06 pattern).
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
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
RETRY_BACKUP_NAME="vm-incremental-${RUN_ID}-p02"
RETRY_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p02"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-08/runs/$RUN_ID"
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
# I-04 capacity guard: HostPath pool free space (default variant writes there).
POOL_FREE_KIB="$(oc debug node/d38-h18-000-r660 --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 400 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB < 400GiB floor) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'I08 run %s: compute-container SIGTERM-to-PID1 during incremental copy (variant %s, pool free %s KiB).\n' \
  "$RUN_ID" "$MANIFEST_VARIANT" "$POOL_FREE_KIB" >&2

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

# --- Assert the run's launcher is Running before arming ----------------------
launcher_pod_before() {
  oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
    --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
LP_BEFORE="$(launcher_pod_before)"
if [[ -z "$LP_BEFORE" ]]; then
  printf 'No Running launcher pod for %s — aborting.\n' "$VM_NAME" >&2
  exit 2
fi
printf 'Launcher pod before chaos: %s.\n' "$LP_BEFORE" >&2

# --- Stage 2: krkn container-scenarios (native trigger) + incremental stage --
# --action 1 => bash -c "kill 1" => SIGTERM to virt-launcher-monitor (PID 1)
# inside the compute container. krkn recovery check may report unrecovered
# (pod terminates, restartPolicy Never) — exit code non-authoritative.
krkn_log="$EVIDENCE_DIR/krkn-container-scenarios.log"
krknctl run container-scenarios \
  --namespace "$NAMESPACE" \
  --label-selector "vm.kubevirt.io/name=$VM_NAME" \
  --container-name compute \
  --action 1 \
  --disruption-count 1 \
  --expected-recovery-time 300 \
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
printf 'krkn container-scenarios armed (pid=%s); trigger gate: %s Progressing; target: compute container of %s (SIGTERM to PID 1).\n' \
  "$krkn_pid" "$INCR_BACKUP_NAME" "$LP_BEFORE" >&2
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
# Wait for krkn to finish (kill + its recovery model).
krkn_status=0
if wait "$krkn_pid"; then
  krkn_status=0
else
  krkn_status=$?
fi
printf 'krkn exit status: %d (log: %s) — NON-AUTHORITATIVE for this scenario (restartPolicy=Never launchers do not restart their containers; recovery is judged from cluster state).\n' \
  "$krkn_status" "$krkn_log" >&2

# --- Evidence: kill timestamp, p01 terminal state, launcher replacement -----
kill_ts="$(grep -oE 'Killing container .*' "$krkn_log" | head -1)"
printf 'KRKN KILL LINE: %s\n' "${kill_ts:-not-found}" >&2
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/incremental-backup-p01.yaml" 2>/dev/null || true
p01_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
p01_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
p01_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
p01_cp="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'P01 TERMINAL STATE: Done=%s reason=%s type=%s checkpoint=%s\n' \
  "${p01_done:-unknown}" "${p01_reason:-unknown}" "${p01_type:-unknown}" "${p01_cp:-none}" >&2
LP_AFTER="$(launcher_pod_before)"
printf 'Launcher pod after chaos: %s (before: %s).\n' "${LP_AFTER:-none}" "$LP_BEFORE" >&2
launcher_replaced="$([[ -n "$LP_AFTER" && "$LP_AFTER" != "$LP_BEFORE" ]] && echo yes || echo no)"
# VMI recovery timeline (poll up to 5 min for Running).
vmi_phase=""; vmi_recovered_at=""
for ((i = 0; i < 60; i++)); do
  vmi_phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  printf '%s vmi.phase=%s launcher=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${vmi_phase:-gone}" "${LP_AFTER:-none}" | tee -a "$EVIDENCE_DIR/vmi-recovery-timeline.txt" >&2
  if [[ "$vmi_phase" == "Running" && "$launcher_replaced" == "yes" ]]; then
    vmi_recovered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    break
  fi
  # refresh launcher identity (replacement may appear late)
  LP_AFTER="$(launcher_pod_before)"
  [[ -n "$LP_AFTER" && "$LP_AFTER" != "$LP_BEFORE" ]] && launcher_replaced=yes
  sleep 5
done
printf 'VM RECOVERY: phase=%s launcher_replaced=%s recovered_at=%s.\n' \
  "${vmi_phase:-gone}" "$launcher_replaced" "${vmi_recovered_at:-never}" >&2
# Tracker: poll for 2 minutes (hold vs clearing semantics).
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
# CheckpointRedefinitionFailed events (I-02 clearing semantics).
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
  | grep -iE 'CheckpointRedefinition|tracker' \
  >"$EVIDENCE_DIR/tracker-events.txt" || true

# --- Recovery: fresh p02 at API level on the recovered VM --------------------
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
recovery_result="FAIL (p02 did not reach Done in 20m)"
if oc wait "vmbackup/$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
    --for=condition=Done --timeout=20m 2>/dev/null; then
  retry_type="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}')"
  retry_cp="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}')"
  retry_reason="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
  if [[ "$retry_type" == "Incremental" ]]; then
    recovery_result="PASS (p02 Incremental chained, checkpoint ${retry_cp:-?}, reason=${retry_reason:-?})"
  else
    recovery_result="FINDING (p02 type=$retry_type — checkpoint-recovery full conversion; reason=${retry_reason:-?}; document against tracker clearing)"
  fi
  oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
else
  oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
fi
printf 'CHECK post-chaos-same-vm-retry: %s\n' "$recovery_result" >&2

# --- Verdict checks ----------------------------------------------------------
verdict_notes=()
# (a) fail-cleanly or completed-before-kill (either terminal outcome is clean;
# a hang is not)
if [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  clean_outcome="PASS (p01 COMPLETED before the kill landed — copy beat the signal; window documented)"
elif [[ "$p01_done" == "True" && -n "$p01_reason" ]]; then
  clean_outcome="PASS (clean failure: Done=True reason=$p01_reason)"
elif [[ -z "$p01_done" ]]; then
  clean_outcome="FAIL (p01 never reached a terminal state — hang)"
else
  clean_outcome="FAIL (p01 Done=${p01_done} without explicit reason)"
fi
printf 'CHECK fail-or-complete-cleanly: %s\n' "$clean_outcome" >&2
verdict_notes+=("fail-or-complete-cleanly:$clean_outcome")
# (b) tracker semantics (hold vs documented clearing)
if [[ "$tracker_final_cp" == "$full_checkpoint" ]]; then
  tracker_check="PASS (tracker holds FULL checkpoint — Jira expectation 'remain on previous valid checkpoint')"
elif [[ -z "$tracker_final_cp" ]]; then
  tracker_check="DIVERGENCE (tracker CLEARED — I-02 CheckpointRedefinitionFailed semantics; Jira expected hold; document events)"
else
  tracker_check="FINDING (tracker=${tracker_final_cp} vs full=$full_checkpoint)"
fi
printf 'CHECK tracker-state: %s\n' "$tracker_check" >&2
verdict_notes+=("tracker-state:$tracker_check")
# (c) VM auto-recovery
if [[ "$vmi_phase" == "Running" && "$launcher_replaced" == "yes" ]]; then
  vm_recovery="PASS (VMI Running on replacement launcher $LP_AFTER at ${vmi_recovered_at:-?})"
else
  vm_recovery="FAIL (vmi=$vmi_phase launcher_replaced=$launcher_replaced)"
fi
printf 'CHECK vm-auto-recovery: %s\n' "$vm_recovery" >&2
verdict_notes+=("vm-auto-recovery:$vm_recovery")
# (d) post-chaos same-VM retry (p02)
printf 'CHECK recovery-backup: %s\n' "$recovery_result" >&2
verdict_notes+=("recovery-backup:$recovery_result")
# (e) type sanity for p01 if it completed
if [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  if [[ "$p01_type" == "Incremental" ]]; then
    type_check="PASS (completed pass stayed Incremental)"
  else
    type_check="FINDING (completed pass type=$p01_type)"
  fi
  printf 'CHECK no-silent-full-conversion: %s\n' "$type_check" >&2
  verdict_notes+=("no-silent-full-conversion:$type_check")
fi
printf 'I08 VERDICT NOTES: %s\n' "${verdict_notes[*]}" >&2
printf 'Scenario complete: container-level interruption evidence collected (kill line, p01 outcome, launcher replacement, VMI recovery, tracker semantics, p02 recovery).\n' >&2
printf 'NEXT: run the direct full-only restore verifier (chaos-trigger-restore-full-only.sh pattern) to prove FULL bit-exact.\n' >&2
exit 0
