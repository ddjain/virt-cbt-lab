#!/usr/bin/env bash
# CBT-I-01: delete the VMI after the full backup's checkpoint is recorded
# and before the incremental pass begins. The VM's running strategy
# recreates the instance; CBT must reinitialize and either redefine the
# checkpoint (genuine incremental) or fall back to a full backup — either is
# acceptable if explicit and data-correct; a silent incorrect incremental is
# a failure. The trigger sequences the deletion strictly between the two
# stages (no race: full stage exits first, VMI recreation is awaited, then
# the incremental stage starts).
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
# deterministic placement and measured baseline as F-07/F-09/F-12/F-13.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
VMI_READY_TIMEOUT="${VMI_READY_TIMEOUT:-600}"
HOG_NODE="d38-h18-000-r660"  # expected VM node (placement guard only)
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
VMI_NAME="$VM_NAME"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-01/runs/$RUN_ID"

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
  printf 'Full stage failed (%d); aborting before VMI deletion.\n' "$full_status" >&2
  exit "$full_status"
fi

# Guard: the full backup must be Done with a checkpoint before we restart.
if [[ "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True ]]; then
  printf 'Full backup %s is not Done; aborting before VMI deletion.\n' "$FULL_BACKUP_NAME" >&2
  exit 1
fi

# --- Stage 2: the disruption — delete the VMI between the stages ----------
old_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
old_launcher="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null \
  | grep "virt-launcher-${VMI_NAME}-" | head -1 || true)"
injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'UTC action request: delete VMI %s at %s (full checkpoint recorded, no incremental backup exists).\n' \
  "$VMI_NAME" "$injection_requested_utc" >&2
oc delete vmi "$VMI_NAME" -n "$NAMESPACE" --wait=false \
  >"$EVIDENCE_DIR/injection.log" 2>&1
printf 'VMI deletion issued at %s (old uid %s, old launcher %s).\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${old_uid:-unknown}" "${old_launcher:-unknown}" >&2

# Wait for the VM's running strategy to recreate the instance.
printf 'Waiting for VMI %s to be recreated and Running/Ready.\n' "$VMI_NAME" >&2
deadline=$((SECONDS + VMI_READY_TIMEOUT))
new_uid=""
while ((SECONDS < deadline)); do
  new_uid="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  ready="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ -n "$new_uid" && "$new_uid" != "$old_uid" && "$ready" == True ]]; then
    break
  fi
  sleep 5
done
if [[ -z "$new_uid" || "$new_uid" == "$old_uid" ]]; then
  printf 'VMI %s was not recreated with a new uid within %ss.\n' \
    "$VMI_NAME" "$VMI_READY_TIMEOUT" >&2
  exit 1
fi
new_launcher="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null \
  | grep "virt-launcher-${VMI_NAME}-" | head -1 || true)"
printf 'VMI recreated: new uid %s (old %s), new launcher %s (old %s), Ready at %s.\n' \
  "$new_uid" "$old_uid" "${new_launcher:-unknown}" "${old_launcher:-unknown}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2

vmi_node="$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
printf 'VM %s ran on node %s (expected %s).\n' "$VM_NAME" "${vmi_node:-unavailable}" "$HOG_NODE" >&2

oc get vmi "$VMI_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vmi-recreated.yaml" 2>/dev/null || true
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true

# --- Stage 3: the incremental pass on the restarted VM --------------------
planned_passes="$(jq -r '.incremental_passes_total' "$ROOT_DIR/runs/$RUN_ID/run.json")"
if [[ ! "$planned_passes" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Managed run has invalid incremental pass count: %s\n' "$planned_passes" >&2
  exit 2
fi
followup_status=0
for ((pass = 1; pass <= planned_passes; pass++)); do
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    :
  else
    followup_status=$?
    break
  fi
done
if ((followup_status != 0)); then exit "$followup_status"; fi

# Record the resulting backup type (incremental vs documented full fallback)
# as the primary scenario observation.
incr_name="vm-incremental-${RUN_ID}-p01"
incr_type="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
  -o jsonpath='{.status.type}' 2>/dev/null || true)"
printf 'RESULTING BACKUP TYPE for %s after VMI restart: %s\n' \
  "$incr_name" "${incr_type:-unknown}" >&2
oc get vmbackup "$incr_name" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/incremental-backup.yaml" 2>/dev/null || true

printf 'Follow-up incremental passes completed (%s).\n' "$planned_passes" >&2
exit 0
