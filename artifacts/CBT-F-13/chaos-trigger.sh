#!/usr/bin/env bash
# CBT-F-13: delete the CURRENT virt-controller leader pod during the
# backup's copy-to-cleanup transition (copy completing, hotplug attachment
# pod still present, final status not yet recorded). The leader is resolved
# from the openshift-cnv virt-controller Lease at condition satisfaction
# (never hard-coded). Expected: takeover replica completes volume cleanup
# and updates the tracker exactly once; no orphaned attachment pod, no
# duplicate checkpoint, backup chain restores.
#
# krknctl's pod-scenarios cannot express "delete the pod named by a lease at
# condition-satisfaction time" (same CLI limitation as F-12's target field,
# bug #4 in cbt-chaos/krknctl-bugs.md), so the identical pod-deletion action
# is applied directly with oc (grace 0). The sub-second cleanup window
# (measured in F-12 r05: Done + VolumeUnMounted + attachment-pod delete all
# land in the same second) makes poll-based sub-phase gating impossible; the
# trigger gates on the superset boundary (backup pre-Done AND attachment pod
# present) at 1s cadence and records the exact landing instant from events.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"

: "${RUN_ID:?Set a unique RUN_ID for this full-backup lifecycle}"
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
# deterministic placement and measured baseline as F-07/F-09/F-10/F-12.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
CONTROLLER_NS="openshift-cnv"
CONTROLLER_LEASE="virt-controller"
HOG_NODE="d38-h18-000-r660"  # expected VM node (placement guard only)
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-13/runs/$RUN_ID"

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  # Observer subagents pre-create runs/<RUN_ID>/observer/ before the launch.
  # Reuse is safe only if nothing but observer output exists there.
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

# Record the pre-run lease state for before/after comparison.
pre_leader="$(oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" \
  -o jsonpath='{.spec.holderIdentity}')"
printf 'Pre-run virt-controller leader: %s\n' "$pre_leader" >&2

resolve_leader() {
  oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" \
    -o jsonpath='{.spec.holderIdentity}'
}

watch_and_inject() {
  local deadline=$((SECONDS + TRIGGERS_TIMEOUT)) leader hp_pod
  while ((SECONDS < deadline)); do
    # Backup exists, is not yet Done, and its hotplug attachment pod is still
    # present (cleanup has not completed). Existence probe first: "Done !=
    # True" on a MISSING object is vacuously true (F-11 r02 lesson).
    if [[ "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.metadata.name}' 2>/dev/null)" == "$FULL_BACKUP_NAME" ]] \
       && test "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True \
       && hp_pod="$(oc get pods -n "$NAMESPACE" -o name \
        2>/dev/null | grep -E "/hp-volume-" | head -1)" \
       && [[ -n "$hp_pod" ]]; then
      leader="$(resolve_leader)"
      if [[ -z "$leader" ]]; then
        printf 'Lease has no holder at satisfaction time; aborting injection.\n' >&2
        return 1
      fi
      if [[ "$leader" != "$pre_leader" ]]; then
        printf 'Leader rotated pre-injection (%s -> %s); refusing to kill the new leader. Re-run the scenario.\n' \
          "$pre_leader" "$leader" >&2
        return 1
      fi
      injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'Transition signal observed (backup %s pre-Done, attachment pod %s present); deleting controller leader %s.\n' \
        "$FULL_BACKUP_NAME" "$hp_pod" "$leader" >&2
      printf 'UTC action request: delete leader pod %s at %s (backup %s pre-terminal, cleanup pending).\n' \
        "$leader" "$injection_requested_utc" "$FULL_BACKUP_NAME" >&2
      # Same action a krkn pod-scenario performs; grace 0 for immediacy.
      if oc delete pod "$leader" -n "$CONTROLLER_NS" \
          --grace-period=0 --force --wait=false \
          >"$EVIDENCE_DIR/injection.log" 2>&1; then
        printf 'Leader pod deletion issued at %s.\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
        return 0
      fi
      printf 'Leader pod deletion failed.\n' >&2
      return 1
    fi
    sleep 1
  done
  printf 'Timed out waiting for the transition window.\n' >&2
  return 1
}

watch_and_inject &
watcher_pid=$!
printf 'Controller-leader deletion watcher started (pid=%s): pre-resolved leader %s.\n' \
  "$watcher_pid" "$pre_leader" >&2

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
  e2e_status=0
else
  e2e_status=$?
fi

# Placement guard (informational for this controller-plane scenario).
vmi_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
printf 'VM %s ran on node %s (expected %s).\n' "$VM_NAME" "${vmi_node:-unavailable}" "$HOG_NODE" >&2

if wait "$watcher_pid"; then
  injection_status=0
else
  injection_status=$?
fi
printf 'E2E exit status: %d; injection watcher status: %d\n' \
  "$e2e_status" "$injection_status" >&2

post_leader="$(oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" \
  -o jsonpath='{.spec.holderIdentity}')"
printf 'Post-run virt-controller leader: %s (pre-run: %s)\n' "$post_leader" "$pre_leader" >&2
oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" -o yaml \
  >"$EVIDENCE_DIR/controller-lease.yaml" 2>/dev/null || true
oc get pods -n "$CONTROLLER_NS" -l kubevirt.io=virt-controller -o wide \
  >"$EVIDENCE_DIR/controller-pods.txt" 2>/dev/null || true

oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true
oc get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup-pvc.yaml" 2>/dev/null || true

# Post-Done cleanup verification: no leftover hp-volume attachment pod for
# this namespace after the backup is terminal (5-minute grace via retry).
cleanup_check_retries=30
leftover_hp=""
if [[ "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" == True ]]; then
  for ((i = 0; i < cleanup_check_retries; i++)); do
    leftover_hp="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null | grep -E "/hp-volume-" | head -1 || true)"
    if [[ -z "$leftover_hp" ]]; then break; fi
    sleep 10
  done
fi
if [[ -n "$leftover_hp" ]]; then
  printf 'CLEANUP CHECK: attachment pod %s still present after backup Done — potential orphan.\n' \
    "$leftover_hp" >&2
  oc get pod "$leftover_hp" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/leftover-attachment-pod.yaml" 2>/dev/null || true
else
  printf 'CLEANUP CHECK: no leftover hp-volume attachment pod after backup Done.\n' >&2
fi

if ((e2e_status != 0)); then
  if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    recovery_status=0
  else
    recovery_status=$?
  fi
  printf 'Full-stage exit status: %d; same-VM recovery status: %d; injection status: %d\n' \
    "$e2e_status" "$recovery_status" "$injection_status" >&2
  if ((recovery_status != 0)); then exit "$recovery_status"; fi
  if ((injection_status != 0)); then exit "$injection_status"; fi
  exit 0
fi

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

printf 'Follow-up incremental passes completed (%s).\n' "$planned_passes" >&2
exit 0
