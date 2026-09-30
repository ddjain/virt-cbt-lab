#!/usr/bin/env bash
# Reproduces scenario 06-incremental-copy-storage-throttle.
# Use krknctl's native trigger-command against the virt-launcher compute log;
# this absorbs krknctl startup before the incremental copy and applies the
# reversible PVC throttle only after the exact "Backup started" marker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="${TARGET_BACKUP:-incremental}"
chaos_set_run_names
TARGET_PVC="${TARGET_PVC:-vm-incremental-pvc-${RUN_NAME}}"
THROTTLE_TYPE="${THROTTLE_TYPE:-iops}"
READ_IOPS="${READ_IOPS:-100}"
WRITE_IOPS="${WRITE_IOPS:-5}"
THROTTLE_DURATION="${THROTTLE_DURATION:-30s}"
chaos_require_tools
chaos_require_krknctl

trigger_command="$(chaos_backup_started_trigger "$NAMESPACE" "$VM_NAME" "$TARGET_BACKUP_NAME")"
printf '[scenario-06] throttling %s after %s live-copy starts\n' \
  "$TARGET_PVC" "$TARGET_BACKUP_NAME" >&2

krknctl run storage-throttle \
  --namespace "$NAMESPACE" \
  --pvc-name "$TARGET_PVC" \
  --throttle-type "$THROTTLE_TYPE" \
  --read-iops "$READ_IOPS" \
  --write-iops "$WRITE_IOPS" \
  --duration "$THROTTLE_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
