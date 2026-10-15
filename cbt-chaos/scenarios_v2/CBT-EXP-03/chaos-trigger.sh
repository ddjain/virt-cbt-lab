#!/usr/bin/env bash
# EXP-3 (adaptive): REPEATED virt-controller leader deletions at the
# completion boundary of a full backup — targets the stale-reconcile race
# hypothesized from source (execute() full-UpdateStatus from informer cache
# can overwrite a just-written terminal condition; cleanupVMIState persists
# BEFORE resolveCompletion's Done condition) and from the campaign's
# cross-run observation (transient "Backup has failed: VMI backup status
# was lost" warning event at the success instant on 4/5 runs).
#
# Differences from CBT-F-13 (single kill at the same boundary, PASS):
# - 3 legs in one lifecycle? No — 3 independent legs (fresh VM each) so the
#   race either reproduces or is excluded at n=3.
# - Kill timing JITTERED around the boundary: each leg polls the backup at
#   1 s and deletes the leader within a distinct offset window after the
#   backup leaves Progressing (the VMI-state-cleanup -> Done gap).
# - Primary measurement: whether the failure signal is an EVENT-ONLY
#   transient (misleading signal) or a CONDITION FLIP (terminal state
#   overwritten: Done/reason changes after first observation) — the latter
#   is a reportable product defect.
# Each leg: full backup -> kill at boundary+jitter -> record every condition
# transition + event with timestamps -> incremental + restore verification
# (chain integrity under a raced completion).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc jq make tee; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CONTROLLER_NS="openshift-cnv"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-03/runs/$RUN_ID"
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

# Jitter offsets (seconds after Progressing clears, the cleanup->Done gap).
# The window itself is ~1-2 s wide; the offsets shift WHERE in the gap the
# leader dies. F-13 precedent: leader resolved from the virt-controller lease.
LEGS=(0 1 2)
leg=0
leader_killed=0

resolve_leader() {
  local holder
  holder="$(oc get lease virt-controller -n "$CONTROLLER_NS" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  holder="${holder%%_*}"
  printf '%s' "$holder"
}

# Watcher: poll the backup at 1 s; when Progressing flips to not-True (the
# completion boundary opens), sleep the leg's offset, then delete the leader.
kill_at_boundary() {
  local offset="$1" progress reason deadline killed progressing_seen=''
  deadline=$(( $(date -u +%s) + 1800 ))
  while :; do
    # Target the VMI-state-cleanup phase directly: Progressing=True with
    # reason "detaching backup target pvc" (watch-stream-verified distinct
    # pre-Done phase, r01 lesson). Fall back to the Progressing flip.
    progress="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
    reason="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"
    if [[ "$reason" == detaching* ]]; then break; fi
    if [[ "${progressing_seen:-}" == true && "$progress" != True ]]; then break; fi
    [[ "$progress" == True ]] && progressing_seen=true
    if (( $(date -u +%s) > deadline )); then
      printf 'Watcher timeout waiting for completion boundary.\n' >&2
      return 9
    fi
    sleep 1
  done
  # Boundary opened: record time, jitter, kill leader.
  sleep "$offset"
  local leader; leader="$(resolve_leader)"
  if [[ -z "$leader" ]]; then
    printf 'Could not resolve controller leader at boundary+offset=%s.\n' "$offset" >&2
    return 8
  fi
  printf 'UTC action request: delete virt-controller leader %s at %s (boundary+%ss, backup %s).\n' \
    "$leader" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$offset" "$FULL_BACKUP_NAME" >&2
  if oc delete pod "$leader" -n "$CONTROLLER_NS" --wait=false; then
    killed=1
  else
    killed=0
  fi
  printf '%s\n' "$killed"
}

capture_final_state() {
  # Full condition/event timeline for the race analysis.
  oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/leg${leg}-final-backup.yaml" 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    >"$EVIDENCE_DIR/leg${leg}-events.txt" 2>/dev/null || true
  oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/leg${leg}-tracker.yaml" 2>/dev/null || true
}

# --- Legs: fresh VM each; watcher armed before each e2e call -------------
BASE_RUN_ID="$RUN_ID"
for offset in "${LEGS[@]}"; do
  leg=$((leg + 1))
  RUN_ID="${BASE_RUN_ID}-l${leg}"
  VM_NAME="vm-${RUN_ID}"
  TRACKER_NAME="vm-tracker-${RUN_ID}"
  FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
  if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
    printf 'Leg run ID %s already exists locally; refusing.\n' "$RUN_ID" >&2; exit 1
  fi
  printf '=== LEG %d: kill at boundary+%ss (fresh lifecycle %s) ===\n' "$leg" "$offset" "$RUN_ID" >&2
  kill_at_boundary "$offset" >"$EVIDENCE_DIR/leg${leg}-kill-result.txt" 2>>"$EVIDENCE_DIR/trigger.log" &
  watcher_pid=$!
  if make e2e TYPE=full NAME="$RUN_ID" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
    GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    full_status=0
  else
    full_status=$?
  fi
  wait "$watcher_pid" || true
  kill_result="$(tail -1 "$EVIDENCE_DIR/leg${leg}-kill-result.txt" 2>/dev/null || echo 0)"
  if [[ "$kill_result" != 1 ]]; then
    printf 'Leg %d: leader kill did NOT execute (kill_result=%s) — harness-invalid leg; aborting run.\n' \
      "$leg" "$kill_result" >&2
    exit 7
  fi
  leader_killed=$((leader_killed + 1))
  # Incremental + restore verification on the same VM (chain integrity).
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    incr_status=0
  else
    incr_status=$?
  fi
  printf 'Leg %d: incremental status=%d\n' "$leg" "$incr_status" >&2
  if ((full_status != 0 || incr_status != 0)); then
    printf 'Leg %d failed (full=%d incr=%d); preserving evidence, stopping legs.\n' \
      "$leg" "$full_status" "$incr_status" >&2
    exit 6
  fi
done
printf 'Experiment complete: %d legs, leader killed in %d.\n' "${#LEGS[@]}" "$leader_killed" >&2
printf 'Classify per report: event-only transient vs condition flip per leg; chain+restore verified by e2e.\n' >&2
exit 0
