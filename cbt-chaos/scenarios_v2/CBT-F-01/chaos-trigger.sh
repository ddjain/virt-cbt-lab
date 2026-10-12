#!/usr/bin/env bash
set -euo pipefail
# Use a scoped direct oc delete: Krkn startup exceeds this short copy window.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
export KUBECONFIG_PATH
export KUBECONFIG="$KUBECONFIG_PATH"

RUN_ID="${RUN_ID:-20261010-cbt-f-01-r03}"
VM_NAME="vm-${RUN_ID}"
NAMESPACE=vm-cbt-demo
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists in this checkout; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
SIGNAL_FILE="$(mktemp)"
observer_pid=

cleanup_observer() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
  rm -f "$SIGNAL_FILE"
}
trap cleanup_observer EXIT INT TERM

observe_copy_then_disrupt() {
  local deadline=$((SECONDS + 3600)) pod pod_uid baseline_tree existing_tracker
  local baseline_captured=false
  while ((SECONDS < deadline)); do
    pod="$(oc get pods -n "$NAMESPACE" \
      -l "vm.kubevirt.io/name=${VM_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      if [[ "$baseline_captured" == false ]] &&
         baseline_tree="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
           virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree 2>/dev/null)"; then
        existing_tracker="$(oc get vmbackuptracker "vm-tracker-${RUN_ID}" \
          -n "$NAMESPACE" --ignore-not-found -o name)"
        if [[ -n "$existing_tracker" ]]; then
          printf 'Tracker already exists before this run; refusing to inject.\n' >&2
          return 1
        fi
        printf 'Pre-backup tracker: absent\nPre-backup checkpoint tree:\n%s\n' \
          "$baseline_tree" >&2
        baseline_captured=true
      fi
      if [[ "$baseline_captured" == true ]] &&
         (set +o pipefail
          oc logs --follow -n "$NAMESPACE" "$pod" -c compute 2>/dev/null |
            grep -F -m1 'Backup started'); then
        pod_uid="$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
        printf 'Active-copy signal from launcher pod %s (UID %s)\n' \
          "$pod" "$pod_uid" >&2
        : > "$SIGNAL_FILE"
        oc delete pod "$pod" -n "$NAMESPACE" --wait=false
        return
      fi
    fi
    sleep 1
  done
  printf 'Timed out waiting for the pre-backup baseline and active-copy log signal.\n' >&2
  return 1
}

observe_copy_then_disrupt &
observer_pid=$!

e2e_args=(TYPE=full NAME="$RUN_ID" KUBECONFIG_PATH="$KUBECONFIG_PATH")
if [[ -n "${VM_OS:-}" ]]; then e2e_args+=("VM_OS=$VM_OS"); fi
if [[ -n "${GUEST_BASE_FILE_COUNT:-}" ]]; then e2e_args+=("GUEST_BASE_FILE_COUNT=$GUEST_BASE_FILE_COUNT"); fi
if [[ -n "${GUEST_FILE_SIZE_MIN_MIB:-}" ]]; then e2e_args+=("GUEST_FILE_SIZE_MIN_MIB=$GUEST_FILE_SIZE_MIN_MIB"); fi
if [[ -n "${GUEST_FILE_SIZE_MAX_MIB:-}" ]]; then e2e_args+=("GUEST_FILE_SIZE_MAX_MIB=$GUEST_FILE_SIZE_MAX_MIB"); fi
if [[ -n "${GUEST_EXEC_POLL_INTERVAL:-}" ]]; then e2e_args+=("GUEST_EXEC_POLL_INTERVAL=$GUEST_EXEC_POLL_INTERVAL"); fi
if [[ -n "${GUEST_EXEC_POLL_ATTEMPTS:-}" ]]; then e2e_args+=("GUEST_EXEC_POLL_ATTEMPTS=$GUEST_EXEC_POLL_ATTEMPTS"); fi
if make e2e "${e2e_args[@]}"; then
  e2e_status=0
else
  e2e_status=$?
fi

if [[ ! -e "$SIGNAL_FILE" ]]; then
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
observer_pid=
trap - EXIT INT TERM
rm -f "$SIGNAL_FILE"

printf 'E2E exit status: %d; event observer/Krkn exit status: %d\n' \
  "$e2e_status" "$observer_status" >&2
if ((observer_status != 0)); then
  exit "$observer_status"
fi
if ((e2e_status == 0)); then
  printf 'The full backup succeeded; CBT-F-01 expected interruption to fail it.\n' >&2
  exit 1
fi
exit "$e2e_status"
