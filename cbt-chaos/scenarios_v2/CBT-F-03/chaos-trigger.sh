#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
: "${RUN_ID:?Set RUN_ID to a unique workflow run ID}"
export KUBECONFIG_PATH
export KUBECONFIG="$KUBECONFIG_PATH"

if [[ ! "$RUN_ID" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || ((${#RUN_ID} > 40)); then
  printf 'RUN_ID is not a valid workflow run ID: %s\n' "$RUN_ID" >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CONTROLLER_NAMESPACE=openshift-cnv
VM_NAME="vm-${RUN_ID}"
BACKUP_NAME="vm-backup-${RUN_ID}"

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists in this checkout; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if oc get vm,vmbackup,vmbackuptracker,pvc,service,datavolume -n "$NAMESPACE" -o name \
  | grep -F -- "$RUN_ID" >/dev/null; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi

SIGNAL_FILE="$(mktemp)"
observer_pid=""
cleanup() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
  rm -f "$SIGNAL_FILE"
}
trap cleanup EXIT INT TERM

observe_reconcile_then_disrupt() {
  local deadline=$((SECONDS + 3600)) backup_json leader leader_json ready
  while ((SECONDS < deadline)); do
    backup_json="$(oc get vmbackup "$BACKUP_NAME" -n "$NAMESPACE" -o json \
      --ignore-not-found 2>/dev/null || true)"
    if [[ -n "$backup_json" ]] && jq -e '
      (.status.conditions // []) as $conditions |
      any($conditions[]?; .type == "Progressing" and .status == "True") and
      (all($conditions[]?; .type != "Done" or .status != "True"))
    ' <<<"$backup_json" >/dev/null; then
      leader="$(oc get lease virt-controller -n "$CONTROLLER_NAMESPACE" \
        -o jsonpath='{.spec.holderIdentity}')"
      if [[ -z "$leader" ]]; then
        printf 'Backup is progressing but virt-controller Lease has no holder.\n' >&2
        return 1
      fi
      leader_json="$(oc get pod "$leader" -n "$CONTROLLER_NAMESPACE" \
        -o json --ignore-not-found 2>/dev/null || true)"
      if [[ -z "$leader_json" ]] || ! jq -e '
        (.metadata.labels["kubevirt.io"] == "virt-controller") and
        any(.status.conditions[]?; .type == "Ready" and .status == "True")
      ' <<<"$leader_json" >/dev/null; then
        printf 'Lease holder %s was not a Ready virt-controller pod.\n' "$leader" >&2
        return 1
      fi
      ready="$(jq -r '[.status.conditions[]? | select(.type == "Ready" and .status == "True")]
        | length' <<<"$leader_json")"
      printf 'Reconciliation signal observed for %s; leader=%s ready_conditions=%s\n' \
        "$BACKUP_NAME" "$leader" "$ready" >&2
      : > "$SIGNAL_FILE"
      krknctl run pod-scenarios \
        --namespace "$CONTROLLER_NAMESPACE" \
        --name-pattern "^${leader}$" \
        --disruption-count 1 \
        --execution serial \
        --kill-timeout 180 \
        --expected-recovery-time 120 \
        --kubeconfig "$KUBECONFIG_PATH" \
        --krkn-kubeconfig /home/krkn/.kube/config
      return
    fi
    sleep 1
  done
  printf 'Timed out waiting for %s Progressing=True with no Done=True condition.\n' \
    "$BACKUP_NAME" >&2
  return 1
}

observe_reconcile_then_disrupt &
observer_pid=$!

if make e2e TYPE=full NAME="$RUN_ID" KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  full_status=0
else
  full_status=$?
fi

if [[ ! -e "$SIGNAL_FILE" ]]; then
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
observer_pid=""

printf 'Full-stage exit status: %d; observer/Krkn exit status: %d\n' \
  "$full_status" "$observer_status" >&2
if ((observer_status != 0)); then
  exit "$observer_status"
fi
if ((full_status != 0)); then
  exit "$full_status"
fi

# The full-stage result is intentionally incomplete; this is the distinct same-VM
# post-chaos backup and final checkpoint/restore verification required by the issue.
make e2e TYPE=incremental VM="$VM_NAME" KUBECONFIG_PATH="$KUBECONFIG_PATH"
