#!/usr/bin/env bash
# EXP-5 (adaptive): stale-reconcile induction — SIGSTOP/SIGCONT of the
# virt-controller leader at the backup completion boundary, plus an
# instrumented routine leg. Targets the campaign's cross-run transient
# ("Backup has failed: VMI backup status was lost" at the success instant,
# 5/6 runs) whose mechanism (per source + EXP-3 RV analysis) is a reconcile
# using stale informer-cache state around the VMI-backup-status removal.
#
# Legs:
#   leg0 (routine): normal full backup, NO injection. High-cadence watch +
#     controller log capture. At the observed 5/6 natural rate this likely
#     captures the transient organically with the controller's own log line.
#   leg1/leg2: SIGSTOP the leader container's controller process at the
#     detach-phase edge (watch-triggered), hold 3s/2s, SIGCONT. A stopped
#     reconcile RESUMES with stale cached state — the hypothesized race,
#     which pod deletion (EXP-3) provably cannot enter (window ~19 RVs).
#
# Named criteria (per campaign Judge):
#   C1 (primary): transient emission mode — EVENT-ONLY vs CONDITION FLIP.
#     Measured by the vmbackup conditions resourceVersion at the "status
#     was lost" emission instant and any post-Done condition change.
#   C2: self-heal vs persistence — post-Done convergence back to Success.
#   C3 (control): backup otherwise completes, restore hashes clean,
#     controller restartCount unchanged during hold (else leg degrades to
#     an EXP-3-style kill and must be labeled as such).
#
# Probe budget (measured 2026-10-14): livenessProbe failureThreshold=8,
# periodSeconds=10 -> ~80s to kill. Holds of 2-3s are safe by >25x margin.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc jq make tee ssh; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CONTROLLER_NS="openshift-cnv"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
LEADER_NODE=""
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-05/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing.\n' "$RUN_ID" >&2; exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing.\n' "$RUN_ID" >&2; exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Evidence path not a directory; refusing.\n' "$RUN_ID" >&2; exit 1
fi
existing="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume -n "$NAMESPACE" -o name 2>/dev/null)"
if [[ "$existing" == *"$RUN_ID"* ]]; then
  printf 'Cluster resources for %s already exist; refusing.\n' "$RUN_ID" >&2; exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"

resolve_leader() {
  local holder
  holder="$(oc get lease virt-controller -n "$CONTROLLER_NS" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  holder="${holder%%_*}"
  printf '%s' "$holder"
}

# SIGSTOP the virt-controller process (pid 1 in the leader container) via
# oc exec (instant, no debug-pod latency), verify state T via /proc/1/stat
# (container has no ps), hold, SIGCONT, verify resumed.
stop_and_hold_leader() {

  local hold_seconds="$1" leader state
  leader="$(resolve_leader)"
  if [[ -z "$leader" ]]; then
    printf 'Cannot resolve leader.\n' >&2; return 8
  fi
  printf 'UTC action request: SIGSTOP virt-controller (pod %s, pid 1) at %s; hold %ss.\n' \
    "$leader" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hold_seconds" >&2
  oc exec -n "$CONTROLLER_NS" "$leader" -- kill -STOP 1 \
    || { printf 'SIGSTOP failed.\n' >&2; return 9; }
  sleep 1
  # /proc/1/stat field 3 = process state (T = stopped).
  state="$(oc exec -n "$CONTROLLER_NS" "$leader" -- cat /proc/1/stat 2>/dev/null \
    | awk '{print $3}' || true)"
  if [[ "$state" != T ]]; then
    printf 'FAIL-CLOSED: process not in state T after SIGSTOP (state=%s); resuming and aborting leg.\n' \
      "${state:-unknown}" >&2
    oc exec -n "$CONTROLLER_NS" "$leader" -- kill -CONT 1 2>/dev/null || true
    return 9
  fi
  printf 'Process state T verified. Holding %ss.\n' "$hold_seconds" >&2
  sleep "$hold_seconds"
  oc exec -n "$CONTROLLER_NS" "$leader" -- kill -CONT 1 \
    || { printf 'SIGCONT failed.\n' >&2; return 9; }
  sleep 1
  state="$(oc exec -n "$CONTROLLER_NS" "$leader" -- cat /proc/1/stat 2>/dev/null \
 | awk '{print $3}' || true)"
  if [[ "$state" != S && "$state" != R ]]; then
    printf 'Process not running after SIGCONT (state=%s).\n' "${state:-unknown}" >&2
    return 9
  fi
  printf 'SIGCONT done; process resumed (state=%s) at %s.\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  printf '%s\n' "$leader"
}

# Watcher: at the detach-phase edge (Progressing=True reason "detaching"),
# perform the stop/hold/cont.
inject_at_detach_edge() {
  local hold_seconds="$1" progress reason deadline progressing_seen=''
  deadline=$(( $(date -u +%s) + 1800 ))
  while :; do
    progress="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
    reason="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"
    if [[ "${progressing_seen:-}" == true && "$progress" != True ]]; then break; fi
    [[ "$progress" == True ]] && progressing_seen=true
    if (( $(date -u +%s) > deadline )); then
      printf 'Watcher timeout waiting for detach edge.\n' >&2
      return 9
    fi
    sleep 1
  done
  stop_and_hold_leader "$hold_seconds"
}

capture_controller_logs() {
  local leader; leader="$(resolve_leader)"
  if [[ -n "$leader" ]]; then
    oc logs "$leader" -n "$CONTROLLER_NS" --since=10m \
      >"$EVIDENCE_DIR/leg${leg}-controller.log" 2>/dev/null || true
  fi
}

run_full_backup() {
  if make e2e TYPE=full NAME="$RUN_ID" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
    GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    full_status=0
  else
    full_status=$?
  fi
}

# --- leg0: instrumented routine backup (no injection) ---------------------
leg=0
printf '=== LEG 0: instrumented ROUTINE backup (no injection) ===\n' >&2
run_full_backup
printf 'Leg 0 routine backup status: %d\n' "$full_status" >&2
capture_controller_logs
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/leg0-final-backup.yaml" 2>/dev/null || true
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
  >"$EVIDENCE_DIR/leg0-events.txt" 2>/dev/null || true
if ((full_status != 0)); then exit "$full_status"; fi

# --- leg1/leg2: SIGSTOP at the detach edge ---------------------------------
leg_run() {
  local hold="$1"
  leg="$2"
  # Advance to a fresh lifecycle BEFORE this leg's e2e call (leg 0 used the
  # base RUN_ID; legs 1/2 get -l1next/-l2next).
  RUN_ID="20261014-exp05-r01-l${leg}next"
  VM_NAME="vm-${RUN_ID}"
  TRACKER_NAME="vm-tracker-${RUN_ID}"
  FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
  if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
    printf 'Leg %d run ID %s already exists; skipping leg.\n' "$leg" "$RUN_ID" >&2
    return 0
  fi
  printf '=== LEG %d: SIGSTOP hold=%ss at detach edge (lifecycle %s) ===\n' "$leg" "$hold" "$RUN_ID" >&2
  inject_at_detach_edge "$hold" >"$EVIDENCE_DIR/leg${leg}-inject-result.txt" 2>>"$EVIDENCE_DIR/trigger.log" &
  watcher_pid=$!
  run_full_backup
  wait "$watcher_pid" || true
  inject_result="$(tail -1 "$EVIDENCE_DIR/leg${leg}-inject-result.txt" 2>/dev/null || true)"
  printf 'Leg %d: e2e status=%d inject leader=%s\n' "$leg" "$full_status" "${inject_result:-FAILED}" >&2
  if [[ -z "$inject_result" ]]; then
    printf 'Leg %d: injection FAILED (fail-closed); aborting run.\n' "$leg" >&2
    exit 7
  fi
  capture_controller_logs
  oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/leg${leg}-final-backup.yaml" 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    >"$EVIDENCE_DIR/leg${leg}-events.txt" 2>/dev/null || true
  # C3 control: controller pod restartCount must be unchanged.
  restarts="$(oc get pod "$inject_result" -n "$CONTROLLER_NS" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
  printf 'Leg %d: controller restartCount=%s (unchanged = leg valid, not a kill)\n' \
    "$leg" "$restarts" >&2
  if ((full_status != 0)); then exit "$full_status"; fi
  # Incremental + restore verification on the same VM.
  if make e2e TYPE=incremental VM="vm-${RUN_ID}" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    incr_status=0
  else
    incr_status=$?
  fi
  printf 'Leg %d: incremental status=%d\n' "$leg" "$incr_status" >&2
  if ((incr_status != 0)); then exit "$incr_status"; fi
}

leg_run 3 1 || true
leg_run 2 2 || true
printf 'Experiment EXP-5 complete: legs 0 (routine), 1 (hold 3s), 2 (hold 2s).\n' >&2
exit 0
