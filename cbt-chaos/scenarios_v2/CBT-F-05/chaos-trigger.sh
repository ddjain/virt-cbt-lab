#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

: "${RUN_ID:?Set a unique RUN_ID for this full-backup lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

VM_NAME="vm-${RUN_ID}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-1024}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-1024}"
export NAMESPACE

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
  local deadline=$((SECONDS + 3600)) pod pod_uid node handler handler_uid baseline_tree
  local baseline_tracker tracker_output
  while ((SECONDS < deadline)); do
    pod="$(oc get pods -n "$NAMESPACE" \
      -l "vm.kubevirt.io/name=${VM_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      if baseline_tree="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
        virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree 2>/dev/null)"; then
        baseline_tracker="$(oc get vmbackuptracker "vm-tracker-${RUN_ID}" \
          -n "$NAMESPACE" --ignore-not-found -o name)"
        tracker_output="$(oc get vmbackuptracker "vm-tracker-${RUN_ID}" \
          -n "$NAMESPACE" --ignore-not-found -o yaml 2>/dev/null || true)"
        printf 'Pre-copy launcher=%s\nPre-copy tracker=%s\nPre-copy tracker state:\n%s\nPre-copy checkpoint tree:\n%s\n' \
          "$pod" "${baseline_tracker:-absent}" "$tracker_output" "$baseline_tree" >&2
        if signal_line="$(
          set +o pipefail
          oc logs --timestamps --follow -n "$NAMESPACE" "$pod" -c compute 2>/dev/null |
            grep -F -m1 'Backup started'
        )"; then
          signal_timestamp="${signal_line%% *}"
          pod_uid="$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
          node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
          [[ -n "$node" ]] || { printf 'VMI node is unavailable after copy signal.\n' >&2; return 1; }
          handler="$(oc get pods -n openshift-cnv \
            -l kubevirt.io=virt-handler \
            --field-selector "spec.nodeName=${node}" \
            -o jsonpath='{.items[0].metadata.name}')"
          [[ -n "$handler" ]] || { printf 'No virt-handler pod found on node %s.\n' "$node" >&2; return 1; }
          handler_uid="$(oc get pod "$handler" -n openshift-cnv -o jsonpath='{.metadata.uid}')"
          printf 'Active-copy signal=%s from launcher %s (UID %s); target virt-handler %s (UID %s) on node %s.\n' \
            "$signal_timestamp" "$pod" "$pod_uid" "$handler" "$handler_uid" "$node" >&2
          : > "$SIGNAL_FILE"
          krknctl run pod-scenarios \
            --namespace openshift-cnv \
            --node-names "$node" \
            --name-pattern "^${handler}$" \
            --disruption-count 1 \
            --execution serial \
            --kill-timeout 180 \
            --expected-recovery-time 120 \
            --kubeconfig "$KUBECONFIG_PATH" \
            --krkn-kubeconfig /home/krkn/.kube/config
          return
        fi
      fi
    fi
    sleep 1
  done
  printf 'Timed out waiting for the launcher and exact Backup started signal.\n' >&2
  return 1
}
 

observe_copy_then_disrupt &
observer_pid=$!

if make e2e TYPE=full NAME="$RUN_ID" \
  NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi

if [[ -e "$SIGNAL_FILE" ]]; then
  signal_observed=true
else
  signal_observed=false
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
observer_pid=

printf 'E2E exit status: %d; event observer/Krkn exit status: %d\n' \
  "$e2e_status" "$observer_status" >&2
if ((e2e_status != 0)); then
  exit "$e2e_status"
fi
if [[ "$signal_observed" != true ]]; then
  if ((observer_status != 0)); then exit "$observer_status"; fi
  exit 1
fi
if make e2e TYPE=incremental VM="$VM_NAME" KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  followup_status=0
else
  followup_status=$?
fi
if ((observer_status != 0)); then
  exit "$observer_status"
fi
exit "$followup_status"
