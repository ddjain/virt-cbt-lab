#!/usr/bin/env bash
# Reproduces scenario 05-virt-controller-pod-kill-post-done.
# Start this trigger before `make e2e NAME="$RUN_NAME"`; it injects on the
# first observed terminal Done=True state for this run's full backup.
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-openshift-cnv}"
RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="${TARGET_BACKUP:-full}"
case "$TARGET_BACKUP" in
  full) TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-backup-${RUN_NAME}}" ;;
  incremental) TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-incremental-${RUN_NAME}}" ;;
  *) printf 'TARGET_BACKUP must be full or incremental (got: %s)\n' "$TARGET_BACKUP" >&2; exit 2 ;;
esac

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
[[ -r "$KUBECONFIG_PATH" ]] || { printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2; exit 2; }
export KUBECONFIG="$KUBECONFIG_PATH"
for command_name in oc krknctl sleep; do
  command -v "$command_name" >/dev/null 2>&1 ||
    { printf '%s is required\n' "$command_name" >&2; exit 2; }
done

POLL_INTERVAL="${POLL_INTERVAL:-0.2}"
TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-1200}"
start_time=$SECONDS
while (( SECONDS - start_time < TRIGGER_TIMEOUT )); do
  done_status="$(oc get vmbackup "$TARGET_BACKUP_NAME" -n "$NAMESPACE" \
    -o 'jsonpath={.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
  if [[ "$done_status" == True ]]; then
    printf '[scenario-05] condition satisfied: %s reached Done=True\n' "$TARGET_BACKUP_NAME" >&2
    break
  fi
  sleep "$POLL_INTERVAL"
done

if (( SECONDS - start_time >= TRIGGER_TIMEOUT )); then
  printf '[scenario-05] timed out waiting for %s Done=True\n' "$TARGET_BACKUP_NAME" >&2
  exit 1
fi

krknctl run pod-scenarios \
  --namespace "$CONTROLLER_NAMESPACE" \
  --pod-label kubevirt.io=virt-controller \
  --disruption-count 1 \
  --kubeconfig "$KUBECONFIG_PATH"
