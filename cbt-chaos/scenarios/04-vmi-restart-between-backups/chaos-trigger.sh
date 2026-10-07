#!/usr/bin/env bash
# Reproduces scenario 04-vmi-restart-between-backups.
# krknctl starts before the E2E run and waits natively for the full checkpoint
# to reach the tracker while the incremental backup object is still absent.
# This absorbs krknctl startup before the narrow between-backups window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_NAME="${VM_NAME:-vm-${RUN_NAME}}"
TRACKER_NAME="${TRACKER_NAME:-vm-tracker-${RUN_NAME}}"
INCREMENTAL_PASS="${INCREMENTAL_PASS:-1}"
if ! [[ "$INCREMENTAL_PASS" =~ ^[1-9][0-9]*$ ]] || ((INCREMENTAL_PASS > 99)); then
  printf 'INCREMENTAL_PASS must be between 1 and 99 (got: %s)\n' "$INCREMENTAL_PASS" >&2
  exit 2
fi
printf -v incremental_pass_suffix '%02d' "$INCREMENTAL_PASS"
INCREMENTAL_BACKUP_NAME="${INCREMENTAL_BACKUP_NAME:-vm-incremental-${RUN_NAME}-p${incremental_pass_suffix}}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
TRIGGERS_INTERVAL="${TRIGGERS_INTERVAL:-0.5}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1200}"
chaos_require_tools
chaos_require_krknctl

trigger_command="$(chaos_tracker_checkpoint_trigger "$NAMESPACE" "$TRACKER_NAME" "$INCREMENTAL_BACKUP_NAME")"
printf '[scenario-04] waiting for tracker %s before restarting %s\n' \
  "$TRACKER_NAME" "$VM_NAME" >&2

krknctl run kubevirt-outage \
  --namespace "$NAMESPACE" \
  --vm-name "$VM_NAME" \
  --kill-count 1 \
  --timeout "${RECOVERY_TIMEOUT:-120}" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
