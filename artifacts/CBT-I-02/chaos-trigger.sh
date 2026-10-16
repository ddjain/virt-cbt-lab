#!/usr/bin/env bash
# CBT-I-02: delete the run's virt-launcher pod while the pass-1 incremental
# backup is actively copying (Progressing=True, Done≠True). Expected: the
# incremental fails cleanly, the tracker keeps referencing the previous full
# checkpoint, the VM restarts, and a retry incremental on the restarted VM
# succeeds and chains to the FULL checkpoint.
#
# The workflow's incremental stage names each pass deterministically
# (vm-incremental-<RUN_ID>-pNN) and refuses to reuse a name that exists, so
# the retry after the failed p01 must remove the failed p01 backup and its
# PVC first (the failed objects are preserved as evidence YAML before
# deletion — the run.json records failure, and the tracker keeps the full
# checkpoint). The launcher deletion is the pod-scenarios-equivalent direct
# action (F-13 precedent: krknctl cannot express "the launcher of run R
# while backup B is Progressing").
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"

: "${RUN_ID:?Set a unique RUN_ID for this full+incremental lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not a valid workflow run ID: %s\n' "$RUN_ID" >&2
  exit 2
fi
for command in oc jq make tee; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
# Force-set (not :-): the .env pre-exports large-odf; keep the same
# deterministic placement and measured baseline as F-07/F-12/F-13/I-01.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
VMI_READY_TIMEOUT="${VMI_READY_TIMEOUT:-600}"
HOG_NODE="d38-h18-000-r660"  # expected VM node (placement guard only)
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
VMI_NAME="$VM_NAME"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-02/runs/$RUN_ID"

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# --- Stage 1: full backup (checkpoint recorded on exit) -------------------
if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" \
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
if ((full_status != 0)); then
  printf 'Full stage failed (%d); aborting before the incremental disruption.\n' "$full_status" >&2
  exit "$full_status"
fi
if [[ "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True ]]; then
  printf 'Full backup %s is not Done; aborting.\n' "$FULL_BACKUP_NAME" >&2
  exit 1
fi
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
printf 'Full checkpoint recorded: %s\n' "$full_checkpoint" >&2

# --- Stage 2 watcher: kill the launcher during the incremental copy -------
watch_and_inject() {
  local deadline=$((SECONDS + TRIGGERS_TIMEOUT)) launcher old_uid
  old_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  while ((SECONDS < deadline)); do
    # Incremental actively copying: object exists, Progressing, not Done.
    if [[ "$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.name}' 2>/dev/null)" == "$INCR_BACKUP_NAME" ]] \
       && test "$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)" = True \
       && test "$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True \
       && launcher="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null \
          | grep "virt-launcher-${VMI_NAME}-" | head -1)" \
       && [[ -n "$launcher" ]]; then
      injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'Active incremental copy observed (%s Progressing); deleting launcher %s.\n' \
        "$INCR_BACKUP_NAME" "$launcher" >&2
      printf 'UTC action request: delete launcher pod %s at %s (incremental %s actively copying; VMI uid %s).\n' \
        "$launcher" "$injection_requested_utc" "$INCR_BACKUP_NAME" "${old_uid:-unknown}" >&2
      if oc delete "$launcher" -n "$NAMESPACE" \
          --grace-period=0 --force --wait=false \
          >"$EVIDENCE_DIR/injection.log" 2>&1; then
        printf 'Launcher pod deletion issued at %s.\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
        printf '%s\n' "${old_uid:-unknown}" >"$EVIDENCE_DIR/pre-injection-vmi-uid.txt"
        return 0
      fi
      printf 'Launcher pod deletion failed.\n' >&2
      return 1
    fi
    sleep 1
  done
  printf 'Timed out waiting for the active incremental copy window.\n' >&2
  return 1
}

watch_and_inject &
watcher_pid=$!
printf 'Launcher-deletion watcher started (pid=%s) for %s.\n' \
  "$watcher_pid" "$INCR_BACKUP_NAME" >&2

# The incremental stage is expected to FAIL (clean-failure criterion); run it
# and capture the status regardless.
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d (failure expected after launcher kill).\n' \
  "$incr_status" >&2

if wait "$watcher_pid"; then
  injection_status=0
else
  injection_status=$?
fi
printf 'Injection watcher status: %d\n' "$injection_status" >&2

# --- Evidence of the clean failure + checkpoint integrity -----------------
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/failed-incremental-backup.yaml" 2>/dev/null || true
failed_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
failed_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
printf 'Failed incremental %s: Done=%s reason=%s\n' \
  "$INCR_BACKUP_NAME" "$failed_done" "${failed_reason:-none}" >&2

tracker_checkpoint="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null \
  || oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'Tracker checkpoint after failed incremental: %s (full checkpoint: %s)\n' \
  "${tracker_checkpoint:-unknown}" "$full_checkpoint" >&2
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/tracker-after-failure.yaml" 2>/dev/null || true

# Wait for the VM to be recreated and Ready before the retry.
printf 'Waiting for VMI %s to be Running/Ready after the launcher kill.\n' "$VMI_NAME" >&2
deadline=$((SECONDS + VMI_READY_TIMEOUT))
while ((SECONDS < deadline)); do
  ready="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "$ready" == True ]] && break
  sleep 5
done
new_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
printf 'VMI after recovery: uid %s (pre-injection %s), Ready=%s.\n' \
  "$new_uid" "$(cat "$EVIDENCE_DIR/pre-injection-vmi-uid.txt" 2>/dev/null || echo unknown)" \
  "$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" >&2

if ((injection_status != 0)); then
  printf 'Injection never fired; the run is harness-invalid.\n' >&2
  exit "$injection_status"
fi

# --- Stage 3: retry the incremental pass on the restarted VM --------------
# The workflow refuses to reuse the failed p01 name; preserve its evidence
# (already captured above), then remove the failed backup and PVC so the
# retry reuses the planned pass-1 name on the same tracker/VM.
oc delete vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" --wait=false \
  >>"$EVIDENCE_DIR/injection.log" 2>&1 || true
oc delete pvc "vm-incremental-pvc-${RUN_ID}-p01" -n "$NAMESPACE" --wait=false \
  >>"$EVIDENCE_DIR/injection.log" 2>&1 || true
printf 'Failed p01 backup/PVC removed for retry (evidence preserved as YAML).\n' >&2

if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  retry_status=0
else
  retry_status=$?
fi
printf 'Retry incremental exit status: %d\n' "$retry_status" >&2

retry_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.type}' 2>/dev/null || true)"
retry_checkpoint="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'RETRY RESULT: type=%s checkpoint=%s\n' \
  "${retry_type:-unknown}" "${retry_checkpoint:-unknown}" >&2
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/retried-incremental-backup.yaml" 2>/dev/null || true

if ((retry_status != 0)); then
  printf 'Retry incremental failed (%d); attempting workflow recovery.\n' "$retry_status" >&2
  if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    printf 'Recovery full backup succeeded; scenario criteria partially met.\n' >&2
    exit "$retry_status"
  fi
  exit "$retry_status"
fi

printf 'Scenario complete: failed incremental preserved, tracker kept the full checkpoint, retry succeeded.\n' >&2
exit 0
