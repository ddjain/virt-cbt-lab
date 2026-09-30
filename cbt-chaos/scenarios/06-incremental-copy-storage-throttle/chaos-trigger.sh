#!/usr/bin/env bash
# Reproduces scenario 06-incremental-copy-storage-throttle.
# Start this trigger before `make e2e NAME="$RUN_NAME"`; it injects after the
# incremental live-copy start line is visible.
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
VM_NAME="${VM_NAME:-vm-${RUN_NAME}}"
TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-incremental-${RUN_NAME}}"
TARGET_PVC="${TARGET_PVC:-vm-incremental-pvc-${RUN_NAME}}"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
[[ -r "$KUBECONFIG_PATH" ]] || { printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2; exit 2; }
export KUBECONFIG="$KUBECONFIG_PATH"
for command_name in oc krknctl grep sleep; do
  command -v "$command_name" >/dev/null 2>&1 ||
    { printf '%s is required\n' "$command_name" >&2; exit 2; }
done

POLL_INTERVAL="${POLL_INTERVAL:-0.2}"
TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-1200}"

virt_launcher_pod() {
  oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

backup_not_done() {
  [[ "$(oc get vmbackup "$TARGET_BACKUP_NAME" -n "$NAMESPACE" \
    -o 'jsonpath={.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)" != True ]]
}

backup_started() {
  local pod="$1" line logs
  logs="$(oc logs -n "$NAMESPACE" "$pod" -c compute --tail=2000 2>/dev/null || true)"
  while IFS= read -r line; do
    if grep -Fq "$TARGET_BACKUP_NAME" <<<"$line" &&
       grep -Fq 'Backup started' <<<"$line"; then
      return 0
    fi
  done <<<"$logs"
  return 1
}

start_time=$SECONDS
while (( SECONDS - start_time < TRIGGER_TIMEOUT )); do
  pod="$(virt_launcher_pod)"
  if [[ -n "$pod" ]] && backup_not_done && backup_started "$pod"; then
    printf '[scenario-06] condition satisfied: %s started on %s\n' "$TARGET_BACKUP_NAME" "$pod" >&2
    break
  fi
  sleep "$POLL_INTERVAL"
done

if (( SECONDS - start_time >= TRIGGER_TIMEOUT )); then
  printf '[scenario-06] timed out waiting for %s live-copy start\n' "$TARGET_BACKUP_NAME" >&2
  exit 1
fi

krknctl run storage-throttle \
  --namespace "$NAMESPACE" \
  --pvc-name "$TARGET_PVC" \
  --throttle-type iops \
  --write-iops 5 \
  --duration 30s \
  --kubeconfig "$KUBECONFIG_PATH"
