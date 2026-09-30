#!/usr/bin/env bash
# Reproduces scenario 08-guest-network-filter-during-mutation.
# Start before E2E. The native trigger waits for the full backup's terminal
# Done=True state; the workflow then immediately enters the post-full guest
# mutation step, so ingress TCP/22 is filtered during the guest_ssh retry
# budget without pretending this is a backup-copy disruption.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="full"
chaos_set_run_names
chaos_require_tools
chaos_require_krknctl

CHAOS_DURATION="${CHAOS_DURATION:-30}"
trigger_command="$(chaos_backup_done_trigger "$NAMESPACE" "$TARGET_BACKUP_NAME")"
printf '[scenario-08] filtering ingress TCP/22 on %s after %s reaches Done=True\n' \
  "$VM_NAME" "$TARGET_BACKUP_NAME" >&2

krknctl run vmi-network-filter \
  --namespace "$NAMESPACE" \
  --vmi-name "$VM_NAME" \
  --ingress true \
  --egress false \
  --ports 22 \
  --protocols tcp \
  --chaos-duration "$CHAOS_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
