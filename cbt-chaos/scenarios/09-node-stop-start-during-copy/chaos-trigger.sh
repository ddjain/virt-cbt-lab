#!/usr/bin/env bash
# Reproduces scenario 09-node-stop-start-during-copy.
# Resolve the VM's current node before starting krknctl, then use the native
# live-copy log trigger. This script deliberately requires BMC values at run
# time; credentials are never stored in the repository or printed.
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
BMC_USER="${BMC_USER:?set BMC_USER from the approved secrets store}"
BMC_PASSWORD="${BMC_PASSWORD:?set BMC_PASSWORD from the approved secrets store}"
BMC_ADDRESS="${BMC_ADDRESS:?set BMC_ADDRESS from the approved secrets store}"
NODE_TIMEOUT="${NODE_TIMEOUT:-180}"
NODE_SELECTOR_KEY="${NODE_SELECTOR_KEY:-kubernetes.io/hostname}"
NODE_DURATION="${NODE_DURATION:-120}"
trigger_command="$(chaos_backup_started_trigger "$NAMESPACE" "$VM_NAME" "$TARGET_BACKUP_NAME")"
printf '[scenario-09] node-stop/start target resolved for VM %s; node=%s; BMC values supplied via environment\n' \
  "$VM_NAME" "$NODE_NAME" >&2

krknctl run node-scenarios \
  --action node_stop_start_scenario \
  --label-selector "${NODE_SELECTOR_KEY}=${NODE_NAME}" \
  --cloud-type bm \
  --bmc-user "$BMC_USER" \
  --bmc-password "$BMC_PASSWORD" \
  --bmc-address "$BMC_ADDRESS" \
  --timeout "$NODE_TIMEOUT" \
  --duration "$NODE_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
