#!/usr/bin/env bash
# Reproduces scenario 04-vmi-restart-between-backups.
# Start this trigger before `make e2e NAME="$RUN_NAME"`; it injects after the
# full checkpoint is visible and before this run's incremental backup exists.
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
VM_NAME="${VM_NAME:-vm-${RUN_NAME}}"
TRACKER_NAME="${TRACKER_NAME:-vm-tracker-${RUN_NAME}}"
INCREMENTAL_BACKUP_NAME="${INCREMENTAL_BACKUP_NAME:-vm-incremental-${RUN_NAME}}"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
[[ -r "$KUBECONFIG_PATH" ]] || { printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2; exit 2; }
export KUBECONFIG="$KUBECONFIG_PATH"
for command_name in oc krknctl sleep; do
  command -v "$command_name" >/dev/null 2>&1 ||
    { printf '%s is required\n' "$command_name" >&2; exit 2; }
done

POLL_INTERVAL="${POLL_INTERVAL:-0.5}"
TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-1200}"
start_time=$SECONDS
while (( SECONDS - start_time < TRIGGER_TIMEOUT )); do
  checkpoint="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
    -o 'jsonpath={.status.latestCheckpoint.name}' 2>/dev/null || true)"
  if [[ -n "$checkpoint" ]] &&
     ! oc get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf '[scenario-04] condition satisfied: tracker %s has checkpoint %s\n' \
      "$TRACKER_NAME" "$checkpoint" >&2
    break
  fi
  sleep "$POLL_INTERVAL"
done

if (( SECONDS - start_time >= TRIGGER_TIMEOUT )); then
  printf '[scenario-04] timed out waiting for full checkpoint before incremental backup\n' >&2
  exit 1
fi

krknctl run kubevirt-outage \
  --namespace "$NAMESPACE" \
  --vm-name "$VM_NAME" \
  --kill-count 1 \
  --kubeconfig "$KUBECONFIG_PATH"
