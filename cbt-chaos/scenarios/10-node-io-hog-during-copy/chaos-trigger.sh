#!/usr/bin/env bash
# Reproduces scenario 10-node-io-hog-during-copy.
# Resolve the HPP/virt-launcher node before starting krknctl and use its native
# trigger-command against the exact "Backup started" compute-log marker. This
# is the coarse node-wide comparison for scenario 06, not a replacement for it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="${TARGET_BACKUP:-full}"
chaos_set_run_names
chaos_require_tools
chaos_require_krknctl
NODE_NAME="${NODE_NAME:-$(chaos_resolve_node)}"
CHAOS_DURATION="${CHAOS_DURATION:-30}"
NODE_SELECTOR_KEY="${NODE_SELECTOR_KEY:-kubernetes.io/hostname}"
trigger_command="$(chaos_backup_started_trigger "$NAMESPACE" "$VM_NAME" "$TARGET_BACKUP_NAME")"
printf '[scenario-10] applying node IO hog to %s after %s live-copy starts\n' \
  "$NODE_NAME" "$TARGET_BACKUP_NAME" >&2

krknctl run node-io-hog \
  --namespace "$NAMESPACE" \
  --node-selector "${NODE_SELECTOR_KEY}=${NODE_NAME}" \
  --chaos-duration "$CHAOS_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
