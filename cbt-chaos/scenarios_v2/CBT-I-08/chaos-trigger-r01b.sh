#!/usr/bin/env bash
# CBT-I-08 r01b: CONTINUATION after r01's injection-WINDOW miss.
# r01 evidence: kill VALID (compute SIGTERM-to-PID1 in wpttr at 13:01:34.308Z)
# but it landed in p01's Initializing/PVC-attach phase — the krkn gate
# `status.conditions.0.status == True` matches conditions[0]=Initializing at
# creation; the backup only BEGAN at 13:01:49.66Z on the replacement launcher.
# The Jira window ("during the active incremental copy") was NOT satisfied.
# r01 DID capture the recovery path (checkpoint redefined on the new launcher,
# p01 chained, p02 chained) — r01b now needs the in-copy kill only.
#
# r01b design (fresh VM/run — cleaner than continuing, since r01's lifecycle
# is complete and its artifacts are closed):
#   - full stage normally (new RUN_ID).
#   - Gate fix: use krkn --trigger-command with an oc query that resolves the
#     Progressing condition BY TYPE (not index):
#       oc get vmbackup <p01> -o jsonpath
#         '{.status.conditions[?(@.type=="Progressing")].status}' == True
#     (command trigger: shell command, chaos starts when it exits 0; source-
#     verified command_trigger.py: subprocess.run(shell=True), expected_rc=0.)
#   - Everything else identical to r01 (SIGTERM-to-PID1 via --action 1,
#     vm.kubevirt.io/name=<VM> label targeting, compute container).
#   - Expected THIS time: kill lands between Progressing=True and Done —
#     i.e. "Backup begin called" .. "Backup has been completed successfully"
#     on the SAME launcher; p01 fails cleanly (or completes if copy beats
#     the kill — 2s poll + ~1s exec latency vs 16-30s copy).
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
POOL_FREE_KIB="$(oc debug node/d38-h18-000-r660 --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 400 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB < 400GiB floor) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'I08b run %s: in-copy compute-container kill via type-matched gate (variant %s).\n' \
  "$RUN_ID" "$MANIFEST_VARIANT" >&2

# --- Stage 1: full backup ----------------------------------------------------
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

launcher_pod_now() {
  oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
    --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
LP_BEFORE="$(launcher_pod_now)"
[[ -n "$LP_BEFORE" ]] || { printf 'No Running launcher pod — aborting.\n' >&2; exit 2; }
printf 'Launcher pod before chaos: %s.\n' "$LP_BEFORE" >&2

# --- Stage 2: krkn with COMMAND trigger gated on Progressing BY TYPE --------
# command trigger (source-verified): shell command; chaos starts when rc==0.
# Gate: Progressing condition (by type) == True — the ACTIVE COPY phase.
gate_cmd="oc get vmbackup $INCR_BACKUP_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}' | grep -q True"
krkn_log="$EVIDENCE_DIR/krkn-container-scenarios.log"
krknctl run container-scenarios \
  --namespace "$NAMESPACE" \
  --label-selector "vm.kubevirt.io/name=$VM_NAME" \
  --container-name compute \
  --action 1 \
  --disruption-count 1 \
  --expected-recovery-time 300 \
  --trigger-command "$gate_cmd" \
  --triggers-interval 2 \
  --triggers-timeout 900 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krkn_log" 2>&1 &
krkn_pid=$!
printf 'krkn container-scenarios armed (pid=%s); COMMAND gate on %s Progressing-by-type; target: compute of %s.\n' \
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
krkn_status=0
if wait "$krkn_pid"; then
  krkn_status=0
else
  krkn_status=$?
fi
printf 'krkn exit status: %d (log: %s) — NON-AUTHORITATIVE (restartPolicy=Never launchers do not restart containers).\n' \
  "$krkn_status" "$krkn_log" >&2

# --- Evidence ----------------------------------------------------------------
kill_line="$(grep -oE 'Killing container .*' "$krkn_log" | head -1)"
printf 'KRKN KILL LINE: %s\n' "${kill_line:-not-found}" >&2
# Copy window from the workflow-captured launcher log (same launcher unless killed).
launcher_log="$ROOT_DIR/runs/$RUN_ID/logs/virt-launcher.log"
begin_ts="$(grep -oE '"timestamp":"[^"]*","msg":"Backup begin called"' "$launcher_log" 2>/dev/null | head -1 || true)"
printf 'BACKUP BEGIN LINE: %s\n' "${begin_ts:-not-found}" >&2
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/incremental-backup-p01.yaml" 2>/dev/null || true
p01_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
p01_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
p01_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
p01_cp="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'P01 TERMINAL STATE: Done=%s reason=%s type=%s checkpoint=%s\n' \
  "${p01_done:-unknown}" "${p01_reason:-unknown}" "${p01_type:-unknown}" "${p01_cp:-none}" >&2
LP_AFTER="$(launcher_pod_now)"
printf 'Launcher pod after chaos: %s (before: %s).\n' "${LP_AFTER:-none}" "$LP_BEFORE" >&2
launcher_replaced="$([[ -n "$LP_AFTER" && "$LP_AFTER" != "$LP_BEFORE" ]] && echo yes || echo no)"
vmi_phase=""; vmi_recovered_at=""
for ((i = 0; i < 60; i++)); do
  vmi_phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  printf '%s vmi.phase=%s launcher=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${vmi_phase:-gone}" "${LP_AFTER:-none}" | tee -a "$EVIDENCE_DIR/vmi-recovery-timeline.txt" >&2
  if [[ "$vmi_phase" == "Running" && "$launcher_replaced" == "yes" ]]; then
    vmi_recovered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    break
  fi
  LP_AFTER="$(launcher_pod_now)"
  [[ -n "$LP_AFTER" && "$LP_AFTER" != "$LP_BEFORE" ]] && launcher_replaced=yes
  sleep 5
done
printf 'VM RECOVERY: phase=%s launcher_replaced=%s recovered_at=%s.\n' \
  "${vmi_phase:-gone}" "$launcher_replaced" "${vmi_recovered_at:-never}" >&2
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
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
  | grep -iE 'CheckpointRedefinition|tracker' \
  >"$EVIDENCE_DIR/tracker-events.txt" || true

# --- Recovery: fresh p02 at API level ----------------------------------------
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
    recovery_result="FINDING (p02 type=$retry_type — checkpoint-recovery conversion; reason=${retry_reason:-?})"
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
if [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  clean_outcome="PASS (p01 completed; copy beat the kill — window documented)"
elif [[ "$p01_done" == "True" && -n "$p01_reason" ]]; then
  clean_outcome="PASS (terminal with explicit reason: $p01_reason)"
elif [[ -z "$p01_done" ]]; then
  clean_outcome="FAIL (p01 never reached a terminal state — hang)"
else
  clean_outcome="FAIL (p01 Done=${p01_done} without explicit reason)"
fi
printf 'CHECK fail-or-complete-cleanly: %s\n' "$clean_outcome" >&2
verdict_notes+=("fail-or-complete-cleanly:$clean_outcome")
# Window check: kill timestamp vs Progressing window (from krkn log ts + launcher log)
kill_ts="$(grep -oE '^2026[^ ]+ [0-9:,]+ \[INFO\] Killing container' "$krkn_log" | head -1 | awk '{print $1" "$2}')"
prog_first="$(grep -oE 'Progressing' "$launcher_log" 2>/dev/null | head -1 || true)"
printf 'WINDOW CHECK: kill_at=%s (must fall between Backup-begin and Backup-completed on the SAME launcher).\n' \
  "${kill_ts:-unknown}" >&2
verdict_notes+=("window:kill_at=${kill_ts:-unknown}")
if [[ "$tracker_final_cp" == "$full_checkpoint" ]]; then
  tracker_check="PASS (tracker holds FULL checkpoint — Jira expectation)"
elif [[ "$tracker_final_cp" == "$p01_cp" && -n "$p01_cp" ]]; then
  tracker_check="PASS (tracker advanced to completed p01 checkpoint)"
elif [[ -z "$tracker_final_cp" ]]; then
  tracker_check="DIVERGENCE (tracker CLEARED — I-02 semantics; Jira expected hold)"
else
  tracker_check="FINDING (tracker=${tracker_final_cp})"
fi
printf 'CHECK tracker-state: %s\n' "$tracker_check" >&2
verdict_notes+=("tracker-state:$tracker_check")
if [[ "$vmi_phase" == "Running" && "$launcher_replaced" == "yes" ]]; then
  vm_recovery="PASS (VMI Running on replacement $LP_AFTER at ${vmi_recovered_at:-?})"
else
  vm_recovery="FAIL (vmi=$vmi_phase launcher_replaced=$launcher_replaced)"
fi
printf 'CHECK vm-auto-recovery: %s\n' "$vm_recovery" >&2
verdict_notes+=("vm-auto-recovery:$vm_recovery")
printf 'CHECK recovery-backup: %s\n' "$recovery_result" >&2
verdict_notes+=("recovery-backup:$recovery_result")
if [[ "$p01_done" == "True" && "$p01_type" == "Incremental" ]]; then
  printf 'CHECK no-silent-full-conversion: PASS (type stays Incremental)\n' >&2
  verdict_notes+=("no-silent-full-conversion:PASS")
fi
printf 'I08B VERDICT NOTES: %s\n' "${verdict_notes[*]}" >&2
printf 'Scenario complete: in-copy container-kill evidence collected.\n' >&2
exit 0
