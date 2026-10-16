#!/usr/bin/env bash
# CBT-F-09: node-io-hog on the HostPath CBT storage pool disk of the VM's
# node, gated on the active-copy compound condition via krknctl's native
# command trigger. Deterministic placement: the cbt-demo-hpp pool exists only
# on d38-h18-000-r660, so a default-variant VM always runs there; the trigger
# fail-closes if the VM lands elsewhere.
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
for command in oc jq make tee krknctl kubectl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
# Force-set (not :-): the execution host's .env pre-exports VM_OS=rhel9 and
# MANIFEST_VARIANT=large-odf (Ceph RBD). The RBD data path leaves the VM's
# node entirely, so node-local I/O contention cannot exercise it; the Jira's
# "CBT storage filesystem on the worker node" is the HostPath pool disk.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
# The only node with the cbt-demo-hpp backing disk; also where every campaign
# VM is scheduled (launcher constraints measured on this cluster).
HOG_NODE="d38-h18-000-r660"
HOG_NAMESPACE="hog-ns-${RUN_ID}"
# Parent directory of the pool PV: exists on every node, hosts the /dev/sdb
# filesystem that backs both the VM root disk and the backup destination.
HOG_MOUNT_PATH="/mnt/local-storage/cbt-demo-local-pool"
HOG_DURATION=90       # per the Jira issue
HOG_WORKERS=8         # parallel stress-ng hdd writers
HOG_WRITE_BYTES=2g    # per worker; 8 x 2g = 16g of ~1.2t free (<1.4% fill)
HOG_BLOCK_SIZE=1m
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-09/runs/$RUN_ID"

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
  unexpected_observer_content="$(find "$EVIDENCE_DIR/observer" -mindepth 1 \
    \( -name trigger.log -o -name krknctl.log \) -print -quit)"
  if [[ -n "$unexpected_observer_content" ]]; then
    printf 'Run ID %s observer already contains run artifacts; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Run ID %s evidence path is not a directory; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
if oc get namespace "$HOG_NAMESPACE" >/dev/null 2>&1; then
  printf 'Hog namespace %s already exists; refusing to reuse it.\n' "$HOG_NAMESPACE" >&2
  exit 1
fi
# Pre-run topology guards: the pool backing pod must be Running on HOG_NODE.
pool_pod="$(oc get pods -n openshift-cnv -o name | grep -E '^pod/hpp-pool-cbt-demo-pool-')"
if [[ -z "$pool_pod" ]]; then
  printf 'Expected a Running hpp-pool-cbt-demo-pool pod in openshift-cnv; found none. Refusing to proceed.\n' >&2
  exit 1
fi
pool_pod_node="$(oc get pod "${pool_pod#pod/}" -n openshift-cnv -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
if [[ -z "$pool_pod_node" ]]; then
  printf 'Could not resolve the HostPath pool pod node; refusing to proceed.\n' >&2
  exit 1
fi
if [[ "$pool_pod_node" != "$HOG_NODE" ]]; then
  printf 'HostPath pool pod runs on %s, expected %s; refusing to proceed.\n' "$pool_pod_node" "$HOG_NODE" >&2
  exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

kubectl create namespace "$HOG_NAMESPACE"
hog_ns_created=true
cleanup_hog_ns() {
  if [[ "${hog_ns_created:-}" == true ]]; then
    kubectl delete namespace "$HOG_NAMESPACE" --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup_hog_ns EXIT INT TERM

# Active-copy compound condition: vmbackup Progressing=True AND Done not yet
# True. Single-quoted JSONPath inside the command substitution (harness
# learning 2026-10-13); exact expanded string validated with bash -c before
# this run.
printf -v trigger_command \
  'test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Progressing")].status}'"'"' 2>/dev/null)" = True && test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Done")].status}'"'"' 2>/dev/null)" != True' \
  "$FULL_BACKUP_NAME" "$NAMESPACE" "$FULL_BACKUP_NAME" "$NAMESPACE"

krknctl_log="$EVIDENCE_DIR/krknctl.log"
krknctl run node-io-hog \
  --namespace "$HOG_NAMESPACE" \
  --node-selector "kubernetes.io/hostname=${HOG_NODE}" \
  --node-mount-path "$HOG_MOUNT_PATH" \
  --chaos-duration "$HOG_DURATION" \
  --io-workers "$HOG_WORKERS" \
  --io-write-bytes "$HOG_WRITE_BYTES" \
  --io-block-size "$HOG_BLOCK_SIZE" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval 3 \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krknctl_log" 2>&1 &
krknctl_pid=$!
printf 'krknctl node-io-hog started (pid=%s): node=%s path=%s duration=%ss workers=%s.\n' \
  "$krknctl_pid" "$HOG_NODE" "$HOG_MOUNT_PATH" "$HOG_DURATION" "$HOG_WORKERS" >&2

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

# Placement guard: verify the VM actually ran on the hog node (the backup is
# already terminal by now; a mismatch invalidates the run, not the product).
vmi_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
printf 'VM %s ran on node %s (hog node %s).\n' "$VM_NAME" "${vmi_node:-unavailable}" "$HOG_NODE" >&2
if [[ "$vmi_node" != "$HOG_NODE" ]]; then
  printf 'PLACEMENT MISMATCH: VM node %s != hog node %s; run is harness-invalid.\n' \
    "$vmi_node" "$HOG_NODE" >&2
  wait "$krknctl_pid" || true
  exit 3
fi

if wait "$krknctl_pid"; then
  krknctl_status=0
else
  krknctl_status=$?
fi
printf 'E2E exit status: %d; krknctl trigger/injection status: %d (log: %s)\n' \
  "$e2e_status" "$krknctl_status" "$krknctl_log" >&2

# Preserve hog-pod evidence before namespace cleanup.
oc get pods -n "$HOG_NAMESPACE" -o yaml >"$EVIDENCE_DIR/hog-pods.yaml" 2>/dev/null || true
oc logs -n "$HOG_NAMESPACE" -l app=krkn-hog --all-containers=true \
  >"$EVIDENCE_DIR/hog-pod.log" 2>/dev/null || true

oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true
oc get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup-pvc.yaml" 2>/dev/null || true

if ((e2e_status != 0)); then
  if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    recovery_status=0
  else
    recovery_status=$?
  fi
  printf 'Full-stage exit status: %d; same-VM recovery status: %d; krknctl status: %d\n' \
    "$e2e_status" "$recovery_status" "$krknctl_status" >&2
  if ((recovery_status != 0)); then exit "$recovery_status"; fi
  if ((krknctl_status != 0)); then exit "$krknctl_status"; fi
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
if ((krknctl_status != 0)); then
  printf 'Harness warning: krknctl returned %d despite completed hog lifecycle.\n' "$krknctl_status" >&2
  exit "$krknctl_status"
fi
