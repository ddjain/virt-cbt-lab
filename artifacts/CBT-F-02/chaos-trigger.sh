#!/usr/bin/env bash
set -euo pipefail

# CBT-F-02: Stop only the backup execution container during a full backup.
#
# Fresh event-driven implementation (supersedes the previous oc-exec and
# krkn-native-v1 triggers; both proved ineffective or unvalidated).
#
# Injection mechanism (all live-validated on cloud05, OCP 4.22 / KubeVirt):
#   * krknctl container-scenarios (Krkn) performs the disruption itself:
#     `pod exec ... bash -c "kill <ACTION>"` inside the `compute` container.
#   * ACTION=1 (SIGTERM): virt-launcher-monitor (PID 1) traps SIGTERM and
#     gracefully stops, CRI-O terminates the compute container, and KubeVirt
#     replaces the launcher pod. LIVE-VALIDATED.
#   * ACTION=9 must NOT be used from inside the container: the Linux kernel
#     silently drops signals to a PID-namespace init even when SIGKILL is
#     unblocked; `kill -9 1` returns success but never disrupts. This is the
#     root cause of every prior CBT-F-02 BLOCKED verdict ("action requested,
#     no disruption observed").
#
# Injection window (event-driven, no sleeps):
#   * Krkn TRIGGERS wait for the exact active-copy boundary before chaos:
#     a single command trigger that runs `oc exec ... virsh backup-dumpxml
#     <domain>` inside the krkn-hub container. It exits 0 only while a
#     libvirt backup job is actually running inside the compute container -
#     the data-plane proof of the active copy (the launcher's "Backup
#     started" log line precedes/announces exactly this state; both
#     boundaries were observed within ~0.2s of each other on live runs).
#     Before the copy starts and after it ends the command exits nonzero.
#   * on-timeout=fail: if the window never opens, Krkn exits nonzero
#     without injecting. No out-of-window disruption is possible.
#
# Blast radius: exactly one `compute` container in the launcher pod selected
# by namespace + vm.kubevirt.io/name=<vm> (unique per lifecycle) +
# --disruption-count 1. No pod delete, no node action.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCENARIO_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-02"

RUN_ID="${RUN_ID:?set a unique chaos artifact RUN_ID (e.g. 20261010-cbtf02-<tag>)}"
NAME="${NAME:?set a unique lifecycle NAME (e.g. 20261010-rhel-f02-<tag>)}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="${VM_OS:-rhel9}"
MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}"
# Guest workload sizing: repository defaults (8 baseline files, 4–12 MiB each)
# passed explicitly to make so the checkout's .env cannot silently override
# them (see run_full_workflow).
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-4}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-12}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved host-local kubeconfig path}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

valid_dns_name() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && ((${#1} <= 40))
}
if ! valid_dns_name "$RUN_ID" || ! valid_dns_name "$NAME" || [[ "$RUN_ID" == "$NAME" ]]; then
  printf 'RUN_ID and NAME must be distinct DNS-1123 names (max 40 chars).\n' >&2
  exit 2
fi
if ! [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || ((${#NAMESPACE} > 63)); then
  printf 'NAMESPACE must be a DNS-1123 label.\n' >&2
  exit 2
fi
for command in oc jq make krknctl date; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 2
  fi
done
if [[ ! -r "$KUBECONFIG_PATH" ]]; then
  printf 'KUBECONFIG_PATH is not readable: %s\n' "$KUBECONFIG_PATH" >&2
  exit 2
fi

# Krkn runs in its own container with the kubeconfig mounted read-only at
# /home/krkn/.kube/config (its default search path). The trigger-command and
# the k8s trigger both run inside that container, so they must use the
# in-container kubeconfig path and in-container `oc`, both of which the image
# ships (/usr/sbin/oc) and which were live-validated.
KUBECONFIG_MOUNT_SOURCE="$(mktemp -d)/config"
cp -- "$KUBECONFIG_PATH" "$KUBECONFIG_MOUNT_SOURCE"
chmod 444 "$KUBECONFIG_MOUNT_SOURCE"
KUBECONFIG_MOUNT_DIR="$(dirname "$KUBECONFIG_MOUNT_SOURCE")"
cleanup_kubeconfig_mount() {
  rm -rf -- "$KUBECONFIG_MOUNT_DIR"
}
trap cleanup_kubeconfig_mount EXIT INT TERM

VM_NAME="vm-${NAME}"
BACKUP_NAME="vm-backup-${NAME}"
TRACKER_NAME="vm-tracker-${NAME}"
BACKUP_PVC_NAME="vm-backup-pvc-${NAME}"
LABEL_SELECTOR="vm.kubevirt.io/name=${VM_NAME}"
LIBVIRT_DOMAIN="${NAMESPACE}_${VM_NAME}"
ARTIFACT_DIR="$SCENARIO_DIR/runs/$RUN_ID"

if [[ -e "$ARTIFACT_DIR" ]]; then
  # The read-only observer arms its watches before the trigger starts and
  # creates runs/<RUN_ID>/observer/ first. Allow that exact case only: a
  # pre-existing directory whose sole entry is the observer/ subtree. Any
  # other pre-existing content remains a fail-closed RUN_ID collision.
  existing_entries=()
  while IFS= read -r -d '' entry; do
    existing_entries+=("$entry")
  done < <(find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print0)
  if ! { ((${#existing_entries[@]} == 1)) \
      && [[ "${existing_entries[0]}" == "$ARTIFACT_DIR/observer" ]] \
      && [[ -d "${existing_entries[0]}" ]]; }; then
    printf 'Artifact directory already exists: %s\nUse a new RUN_ID.\n' "$ARTIFACT_DIR" >&2
    exit 2
  fi
fi
if [[ -e "$ROOT_DIR/runs/$NAME" ]]; then
  printf 'Lifecycle directory already exists: %s\nUse a new NAME.\n' "$ROOT_DIR/runs/$NAME" >&2
  exit 2
fi
mkdir -p -- "$ARTIFACT_DIR"

# Refuse to touch a lifecycle whose cluster resources already exist: the
# scenario must create the VM and its full backup itself so the injection
# window is unambiguous.
for resource in "vm/$VM_NAME" "vmbackup/$BACKUP_NAME" \
  "vmbackuptracker/$TRACKER_NAME" "pvc/$BACKUP_PVC_NAME"; do
  if oc get "$resource" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf 'Resource already exists: %s -n %s\nUse a new NAME.\n' "$resource" "$NAMESPACE" >&2
    exit 2
  fi
done
for permission in "get vmbackups.backup.kubevirt.io" "get virtualmachineinstances.kubevirt.io" \
  "create pods/exec" "get pods" "get vmbackuptrackers.backup.kubevirt.io"; do
  read -r perm_verb perm_resource <<<"$permission"
  if [[ "$(oc auth can-i "$perm_verb" "$perm_resource" -n "$NAMESPACE" 2>/dev/null)" != yes ]]; then
    printf 'Missing RBAC permission: %s -n %s\n' "$permission" "$NAMESPACE" >&2
    exit 2
  fi
done

E2E_LOG="$ARTIFACT_DIR/e2e.log"
E2E_STATUS_FILE="$ARTIFACT_DIR/e2e.status"
KRKN_LOG="$ARTIFACT_DIR/krkn.log"
ACTION_REQUEST_FILE="$ARTIFACT_DIR/action-request.json"
ACTION_RESULT_FILE="$ARTIFACT_DIR/action-result.json"
PRE_CHAOS_FILE="$ARTIFACT_DIR/pre-chaos-state.json"
STATUS_FILE="$ARTIFACT_DIR/statuses.json"
for path in "$E2E_LOG" "$E2E_STATUS_FILE" "$KRKN_LOG" \
  "$ACTION_REQUEST_FILE" "$ACTION_RESULT_FILE" "$PRE_CHAOS_FILE" "$STATUS_FILE"; do
  if [[ -e "$path" ]]; then
    printf 'Refusing to overwrite existing artifact: %s\nUse a new RUN_ID.\n' "$path" >&2
    exit 2
  fi
done

log() {
  printf '[%s] [cbt-f-02] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$ARTIFACT_DIR/trigger.log" >&2
}

write_statuses() {
  local e2e_status="$1" krkn_status="$2" action_requested="$3" injection_in_window="$4"
  jq -n \
    --arg scenario_id CBT-F-02 --arg run_id "$RUN_ID" --arg name "$NAME" \
    --arg namespace "$NAMESPACE" --arg mechanism "krknctl container-scenarios (SIGTERM to compute)" \
    --arg e2e_status "$e2e_status" --arg krkn_status "$krkn_status" \
    --arg action_requested "$action_requested" --arg injection_in_window "$injection_in_window" \
    --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
    '{scenario_id:$scenario_id,run_id:$run_id,lifecycle_name:$name,namespace:$namespace,
      mechanism:$mechanism,
      e2e_status:($e2e_status|tonumber),krkn_status:($krkn_status|tonumber),
      action_requested:($action_requested == "true"),injection_in_window:($injection_in_window == "true"),
      completed_at_utc:$completed_at}' > "$STATUS_FILE"
}

run_full_workflow() {
  local status tmp_status
  # Guest workload sizing is passed explicitly as make command-line arguments:
  # make reads the checkout's .env (-include .env), whose assignments silently
  # override environment-prefix variables, so a bare `VM_OS=... make e2e` would
  # inherit the .env workload values instead of the repo defaults below.
  if make e2e TYPE=full NAME="$NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    status=0
  else
    status=$?
  fi
  tmp_status="${E2E_STATUS_FILE}.tmp.$$"
  printf '%s\n' "$status" > "$tmp_status"
  mv -- "$tmp_status" "$E2E_STATUS_FILE"
}

capture_pre_chaos_state() {
  # Read-only snapshot of the run's own resources right before arming Krkn.
  # The VM/backup do not exist yet at this point (created by the e2e below);
  # this records the baseline that the post-run verification compares against.
  jq -n \
    --arg run_id "$RUN_ID" --arg name "$NAME" --arg namespace "$NAMESPACE" \
    --arg vm_name "$VM_NAME" --arg backup_name "$BACKUP_NAME" \
    --arg tracker_name "$TRACKER_NAME" --arg pvc_name "$BACKUP_PVC_NAME" \
    --arg label_selector "$LABEL_SELECTOR" --arg libvirt_domain "$LIBVIRT_DOMAIN" \
    --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
    '{run_id:$run_id,lifecycle_name:$name,namespace:$namespace,
      vm_name:$vm_name,backup_name:$backup_name,tracker_name:$tracker_name,
      backup_pvc_name:$pvc_name,label_selector:$label_selector,
      libvirt_domain:$libvirt_domain,
      expected_preconditions:{
        tracker_latest_checkpoint:"empty (first full backup of this lifecycle)",
        vm_backup_objects_for_selector:"none (backup applied by e2e vm-backup stage)"},
      captured_at_utc:$captured_at}' > "$PRE_CHAOS_FILE"
}

# Krkn trigger-command: runs inside the krkn-hub container every
# TRIGGERS_INTERVAL seconds. Chaos begins only when this single command
# trigger is satisfied:
#   * oc exec into the run's launcher pod compute container runs
#     `virsh backup-dumpxml <domain>`: exit 0 only while the libvirt backup
#     job is actively copying. Any other state (no job, pod not scheduled,
#     exec failure) exits nonzero.
# The command is deliberately self-contained: it re-resolves the launcher pod
# by the run-scoped label on every poll so it cannot pin a stale pod.
TRIGGER_CMD='ns="'"$NAMESPACE"'"; vm="'"$VM_NAME"'"; dom="'"$LIBVIRT_DOMAIN"'"; pod=$(oc get pods -n "$ns" -l "vm.kubevirt.io/name=$vm" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null) && [ -n "$pod" ] && oc exec -n "$ns" "$pod" -c compute -- virsh backup-dumpxml "$dom" >/dev/null 2>&1'

log "Starting CBT-F-02: run_id=$RUN_ID lifecycle=$NAME namespace=$NAMESPACE"
log "Target: compute container of launcher selected by $LABEL_SELECTOR (disruption-count 1, action SIGTERM=1)"
log "Injection window: krkn trigger waits for the active libvirt backup job (virsh backup-dumpxml exit 0); on-timeout=fail"

capture_pre_chaos_state

# Start the lifecycle first so Krkn's triggers can watch the window open.
# Expected e2e outcome: FAIL (exit != 0) because the disrupted full backup
# terminates with Done=True / reason "Backup has failed: ..." and vm-backup.sh
# exits nonzero on a terminal-failure reason. A zero e2e exit here means the
# disruption did not take effect and the run must be judged INVALID.
run_full_workflow > "$E2E_LOG" 2>&1 &
e2e_pid=$!

# Give the VM setup stage a moment to start; Krkn's trigger timeout budget
# (TRIGGERS_TIMEOUT_SECONDS) spans VM creation + backup start, so it is set
# generously below. Krkn only injects after BOTH trigger conditions hold.
TRIGGERS_TIMEOUT_SECONDS="${TRIGGERS_TIMEOUT_SECONDS:-3600}"
TRIGGERS_INTERVAL_SECONDS="${TRIGGERS_INTERVAL_SECONDS:-3}"
EXPECTED_RECOVERY_TIME_SECONDS="${EXPECTED_RECOVERY_TIME_SECONDS:-300}"

krkn_started_at="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
jq -n \
  --arg scenario_id CBT-F-02 --arg run_id "$RUN_ID" --arg name "$NAME" \
  --arg namespace "$NAMESPACE" --arg vm_name "$VM_NAME" \
  --arg backup_name "$BACKUP_NAME" --arg label_selector "$LABEL_SELECTOR" \
  --arg container compute --arg action "1 (SIGTERM to PID 1: virt-launcher-monitor)" \
  --argjson disruption_count 1 \
  --argjson expected_recovery_time "$EXPECTED_RECOVERY_TIME_SECONDS" \
  --argjson triggers_timeout "$TRIGGERS_TIMEOUT_SECONDS" \
  --argjson triggers_interval "$TRIGGERS_INTERVAL_SECONDS" \
  --arg triggers_on_timeout fail \
  --arg trigger_description "virsh backup-dumpxml exits 0 (active libvirt backup job in compute)" \
  --arg krkn_started_at "$krkn_started_at" \
  '{scenario_id:$scenario_id,run_id:$run_id,lifecycle_name:$name,namespace:$namespace,
    target:{vm_name:$vm_name,label_selector:$label_selector,container:$container},
    backup:{name:$backup_name},
    action:{mechanism:"krknctl container-scenarios",signal:$action,disruption_count:$disruption_count,
      expected_recovery_time_seconds:$expected_recovery_time},
    trigger:{mode:"all_of",timeout_seconds:$triggers_timeout,interval_seconds:$triggers_interval,
      on_timeout:$triggers_on_timeout,description:$trigger_description},
    krkn_started_at_utc:$krkn_started_at}' > "$ACTION_REQUEST_FILE"

krkn_status=125
if krknctl run container-scenarios \
  --kubeconfig "$KUBECONFIG_MOUNT_SOURCE" \
  --namespace "$NAMESPACE" \
  --label-selector "$LABEL_SELECTOR" \
  --container-name compute \
  --action 1 \
  --disruption-count 1 \
  --expected-recovery-time "$EXPECTED_RECOVERY_TIME_SECONDS" \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-mode all_of \
  --triggers-timeout "$TRIGGERS_TIMEOUT_SECONDS" \
  --triggers-interval "$TRIGGERS_INTERVAL_SECONDS" \
  --triggers-on-timeout fail \
  > "$KRKN_LOG" 2>&1; then
  krkn_status=0
else
  krkn_status=$?
fi

jq -n \
  --arg krkn_started_at "$krkn_started_at" \
  --arg action_completed_at "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
  --argjson krkn_status "$krkn_status" \
  '{krkn_started_at_utc:$krkn_started_at,action_completed_at_utc:$action_completed_at,
    krkn_status:$krkn_status,action_request_recorded:true}' > "$ACTION_RESULT_FILE"

# Wait for the e2e pipeline to settle (it may fail fast on the disrupted
# backup or run to its own timeout on the oc wait).
e2e_wait_deadline=$((SECONDS + 2400))
while [[ ! -s "$E2E_STATUS_FILE" ]]; do
  if ! kill -0 "$e2e_pid" 2>/dev/null; then
    log 'The E2E process exited without recording its status.'
    break
  fi
  if ((SECONDS >= e2e_wait_deadline)); then
    log 'Timed out waiting for the E2E pipeline to settle; terminating it.'
    kill "$e2e_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
if [[ -s "$E2E_STATUS_FILE" ]]; then
  e2e_status="$(cat "$E2E_STATUS_FILE")"
else
  e2e_status=125
fi
wait "$e2e_pid" 2>/dev/null || true

# Post-run read-only evidence collection for the scenario verdict. Preserve
# everything before any later recovery stage touches the resources.
collect_post_evidence() {
  local out_dir="$ARTIFACT_DIR/post-evidence"
  mkdir -p -- "$out_dir"
  oc get pod -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o json > "$out_dir/pods.json" 2>/dev/null || true
  oc get vmbackup "$BACKUP_NAME" -n "$NAMESPACE" -o json > "$out_dir/vmbackup.json" 2>/dev/null || true
  oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$out_dir/tracker.json" 2>/dev/null || true
  oc get vm "$VM_NAME" -n "$NAMESPACE" -o json > "$out_dir/vm.json" 2>/dev/null || true
  oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json > "$out_dir/vmi.json" 2>/dev/null || true
  oc get pvc "$BACKUP_PVC_NAME" -n "$NAMESPACE" -o json > "$out_dir/backup-pvc.json" 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp > "$out_dir/events.txt" 2>/dev/null || true
  local pod
  pod="$(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    oc logs -n "$NAMESPACE" "$pod" -c compute > "$out_dir/launcher-compute.log" 2>/dev/null || true
    oc exec -n "$NAMESPACE" "$pod" -c compute -- \
      virsh checkpoint-list "$LIBVIRT_DOMAIN" --tree > "$out_dir/checkpoint-tree-after.txt" 2>/dev/null || true
  fi
}
collect_post_evidence

# Quick triage summary to stderr; the durable verdicts live in the artifact
# files and the scenario report.
log "Krkn exit=$krkn_status; E2E exit=$e2e_status"
if ((krkn_status == 0)) && ((e2e_status != 0)); then
  log 'Disruption delivered in-window (krkn PASS) and the full backup failed as expected (e2e nonzero).'
  log 'Verify the terminal reason, tracker, and recovery before judging the scenario: see post-evidence/.'
  injection_in_window=true
elif ((krkn_status == 0)) && ((e2e_status == 0)); then
  log 'INVALID: krkn reported PASS but the e2e full backup completed successfully; disruption was not effective.'
  injection_in_window=false
else
  log 'No in-window injection: krkn exited nonzero (trigger timeout or scenario failure); the backup lifecycle was not disrupted.'
  injection_in_window=false
fi

write_statuses "$e2e_status" "$krkn_status" true "$injection_in_window"

if ((krkn_status != 0)); then exit "$krkn_status"; fi
exit "$e2e_status"
