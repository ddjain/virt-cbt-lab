#!/usr/bin/env bash
# Reproduces scenario 03-checkpoint-pvc-fill.
# Resolve the per-VMI persistent-state PVC before starting krknctl, then use a
# native trigger-command so PVC filling begins when the target backup reports
# Progressing=True. The checkpoint PVC is resolved from the target pod rather
# than guessed from its generated suffix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="${TARGET_BACKUP:-full}"
chaos_set_run_names
TARGET_PVC="${TARGET_PVC:-}"
chaos_require_tools
chaos_require_krknctl
if [[ -z "$TARGET_PVC" ]]; then
  TARGET_PVC="$(chaos_resolve_checkpoint_pvc)"
fi
FILL_PERCENTAGE="${FILL_PERCENTAGE:-95}"
FILL_DURATION="${FILL_DURATION:-60}"
trigger_command="$(chaos_backup_progressing_trigger "$NAMESPACE" "$TARGET_BACKUP_NAME")"
printf '[scenario-03] targeting checkpoint PVC %s for %s backup\n' \
  "$TARGET_PVC" "$TARGET_BACKUP" >&2

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
