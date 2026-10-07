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
case "$TARGET_BACKUP" in
  full)
    TARGET_PVC="${TARGET_PVC:-vm-backup-pvc-${RUN_NAME}}"
    ;;
  incremental)
    TARGET_PVC="${TARGET_PVC:-$INCREMENTAL_BACKUP_PVC_NAME}"
    ;;
  *)
    printf '[scenario-06] unsupported TARGET_BACKUP=%s (expected full or incremental)\n' \
      "$TARGET_BACKUP" >&2
    exit 2
    ;;
esac
THROTTLE_TYPE="${THROTTLE_TYPE:-both}"
READ_BPS="${READ_BPS:-1}"
WRITE_BPS="${WRITE_BPS:-1}"
READ_IOPS="${READ_IOPS:-1}"
WRITE_IOPS="${WRITE_IOPS:-1}"
THROTTLE_DURATION="${THROTTLE_DURATION:-60s}"
chaos_require_tools
chaos_require_krknctl

trigger_command="$(chaos_backup_started_trigger "$NAMESPACE" "$VM_NAME" "$TARGET_BACKUP_NAME")"
printf '[scenario-06] throttling %s after %s live-copy starts\n' \
  "$TARGET_PVC" "$TARGET_BACKUP_NAME" >&2

krknctl run storage-throttle \
  --namespace "$NAMESPACE" \
  --pvc-name "$TARGET_PVC" \
  --throttle-type "$THROTTLE_TYPE" \
  --read-bps "$READ_BPS" \
  --write-bps "$WRITE_BPS" \
  --read-iops "$READ_IOPS" \
  --write-iops "$WRITE_IOPS" \
  --duration "$THROTTLE_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
