#!/usr/bin/env bash
# CBT-F-10: CPU hog on the VM's node during the active copy. Injection is a
# direct, narrowly scoped kubectl pod (same krkn hog image/mechanism) gated
# on the active-copy compound condition, because krknctl's node-cpu-hog is
# broken in this version (readOnlyRootFilesystem jobfile failure; see r01
# archive). Deterministic placement as in F-09: campaign VMs run on
# d38-h18-000-r660; trigger fail-closes on mismatch.
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
# Force-set (not :-): the .env pre-exports large-odf; keep the same
# deterministic placement and measured baseline as F-07/F-09.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
HOG_NODE="d38-h18-000-r660"
HOG_NAMESPACE="hog-ns-${RUN_ID}"
HOG_DURATION=90      # per the Jira issue
HOG_CPU_PERCENTAGE=60 # per stress-ng worker
HOG_CORES=32          # stress-ng cpu workers (~19-20 CPUs of load on 112)
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-10/runs/$RUN_ID"

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
# Direct injection instead of `krknctl run node-cpu-hog` (r01 finding,
# archived as 20261013-cbtf10-r01-invalid-hog-readonly-fs): krkn's hog pod
# template sets readOnlyRootFilesystem:true and run.sh writes its stress-ng
# jobfile to the container CWD, so the cpu/memory hog branches die instantly
# with "Read-only file system" — only the io branch gets a writable volume.
# Fallback sanctioned when the tool cannot preserve the action: a custom
# condition watcher followed by a direct, narrowly scoped kubectl mutation.
# The workaround was live-validated on the target node (hog-verify-f10):
# copy the image's templates + run.sh to /dev/shm (tmpfs stays writable under
# readOnlyRootFilesystem) and run from there — measured cpu-usage-per-instance
# matches LOAD_PERCENTAGE.
watch_and_inject() {
  local deadline=$((SECONDS + TRIGGERS_TIMEOUT)) backup_json
  while ((SECONDS < deadline)); do
    if test "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)" = True \
       && test "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True; then
      # Re-read to confirm the window is still open at the boundary.
      backup_json="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o json --ignore-not-found 2>/dev/null || true)"
      if [[ -n "$backup_json" ]] && jq -e '
        all((.status.conditions // [])[]?; .type != "Done" or .status != "True")
      ' <<<"$backup_json" >/dev/null; then
        printf 'Active-copy signal observed; creating CPU hog pod on %s (%s workers @ %s%%, %ss).\n' \
          "$HOG_NODE" "$HOG_CORES" "$HOG_CPU_PERCENTAGE" "$HOG_DURATION" >&2
        kubectl run "cpu-hog-${RUN_ID}" \
          --namespace "$HOG_NAMESPACE" \
          --restart=Never \
          --image="quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog" \
          --overrides "{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${HOG_NODE}\"},\"containers\":[{\"name\":\"cpu-hog-${RUN_ID}\",\"image\":\"quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog\",\"command\":[\"bash\",\"-c\",\"cp /stress-ng/*.template /stress-ng/run.sh /dev/shm/ && cd /dev/shm && HOG_TYPE=cpu WORKERS=${HOG_CORES} LOAD_PERCENTAGE=${HOG_CPU_PERCENTAGE} CPU_METHOD=all DURATION=${HOG_DURATION} ./run.sh\"],\"securityContext\":{\"privileged\":true,\"readOnlyRootFilesystem\":true},\"env\":[{\"name\":\"HOG_TYPE\",\"value\":\"cpu\"},{\"name\":\"WORKERS\",\"value\":\"${HOG_CORES}\"},{\"name\":\"LOAD_PERCENTAGE\",\"value\":\"${HOG_CPU_PERCENTAGE}\"},{\"name\":\"DURATION\",\"value\":\"${HOG_DURATION}\"}]}]}}" \
          >/dev/null
        injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'UTC action request: create cpu-hog-%s on node %s at %s (backup %s, Progressing=True Done!=True).\n' \
          "$RUN_ID" "$HOG_NODE" "$injection_requested_utc" "$FULL_BACKUP_NAME" >&2
        return 0
      fi
    fi
    sleep 3
  done
  printf 'Timed out waiting for the active-copy window.\n' >&2
  return 1
}

watch_and_inject &
watcher_pid=$!
printf 'CPU hog injection watcher started (pid=%s): node=%s cores=%s@%s%% duration=%ss.\n' \
  "$watcher_pid" "$HOG_NODE" "$HOG_CORES" "$HOG_CPU_PERCENTAGE" "$HOG_DURATION" >&2

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

# Placement guard: verify the VM actually ran on the hog node.
vmi_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
printf 'VM %s ran on node %s (hog node %s).\n' "$VM_NAME" "${vmi_node:-unavailable}" "$HOG_NODE" >&2
if [[ "$vmi_node" != "$HOG_NODE" ]]; then
  printf 'PLACEMENT MISMATCH: VM node %s != hog node %s; run is harness-invalid.\n' \
    "$vmi_node" "$HOG_NODE" >&2
  wait "$watcher_pid" || true
  exit 3
fi

if wait "$watcher_pid"; then
  injection_status=0
else
  injection_status=$?
fi
# Wait out the hog's own duration so the pod reaches its terminal state
# before evidence capture (stress-ng exits at the timeout; nothing else to wait on).
hog_deadline=$((SECONDS + HOG_DURATION + 60))
while ((SECONDS < hog_deadline)); do
  hog_phase="$(oc get pod "cpu-hog-${RUN_ID}" -n "$HOG_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$hog_phase" == Succeeded || "$hog_phase" == Failed ]] && break
  sleep 5
done
printf 'E2E exit status: %d; injection watcher status: %d\n' \
  "$e2e_status" "$injection_status" >&2

# Preserve hog-pod evidence before namespace cleanup.
oc get pod "cpu-hog-${RUN_ID}" -n "$HOG_NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/hog-pod.yaml" 2>/dev/null || true
oc logs "cpu-hog-${RUN_ID}" -n "$HOG_NAMESPACE" \
  >"$EVIDENCE_DIR/hog-pod.log" 2>/dev/null || true
hog_exit="$(oc get pod "cpu-hog-${RUN_ID}" -n "$HOG_NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
printf 'Hog pod terminal phase=%s exitCode=%s\n' "$hog_phase" "${hog_exit:-unknown}" >&2
if [[ "$hog_phase" != Succeeded || "$hog_exit" != 0 ]]; then
  printf 'CPU hog pod did not complete successfully (phase=%s exit=%s); run is harness-invalid.\n' \
    "$hog_phase" "$hog_exit" >&2
  exit 4
fi

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
