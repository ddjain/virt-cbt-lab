#!/usr/bin/env bash
# Reproduces scenario 02-backup-destination-pvc-fill.
# krknctl starts before the E2E run and uses a native trigger-command that
# watches the virt-launcher log for the target backup's live-copy marker. The
# trigger is log-specific; a Kubernetes resource trigger cannot observe this
# in-container boundary. Use the large profile so krknctl's trigger startup is
# absorbed before the copy and the fill runs during the measured copy window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="${TARGET_BACKUP:-full}"
chaos_set_run_names
TARGET_PVC="${TARGET_PVC:-}"
if [[ -z "$TARGET_PVC" ]]; then
  case "$TARGET_BACKUP" in
    full) TARGET_PVC="vm-backup-pvc-${RUN_NAME}" ;;
    incremental) TARGET_PVC="vm-incremental-pvc-${RUN_NAME}" ;;
  esac
fi
FILL_PERCENTAGE="${FILL_PERCENTAGE:-95}"
FILL_DURATION="${FILL_DURATION:-60}"
chaos_require_tools
chaos_require_krknctl

trigger_command="$(chaos_backup_started_trigger "$NAMESPACE" "$VM_NAME" "$TARGET_BACKUP_NAME")"
printf '[scenario-02] starting native trigger before %s backup; target PVC=%s\n' \
  "$TARGET_BACKUP" "$TARGET_PVC" >&2

krknctl run pvc-scenarios \
  --namespace "$NAMESPACE" \
  --pvc-name "$TARGET_PVC" \
  --fill-percentage "$FILL_PERCENTAGE" \
  --duration "$FILL_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
