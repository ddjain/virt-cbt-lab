#!/usr/bin/env bash
# Reproduces scenario 05-virt-controller-pod-kill-post-done with a native
# krknctl trigger. The original script launched krknctl only after observing
# Done=True, so its measured 5-11s startup delay let the incremental backup and
# sometimes the entire run finish before the controller replica was killed.
# Starting krknctl before E2E absorbs that cost and makes the first Done=True
# observation the trigger boundary itself; timeout now fails instead of silently
# skipping chaos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../trigger-common.sh
source "$SCRIPT_DIR/../trigger-common.sh"

RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-openshift-cnv}"
TARGET_BACKUP="${TARGET_BACKUP:-full}"
chaos_set_run_names
chaos_require_tools
chaos_require_krknctl
trigger_command="$(chaos_backup_done_trigger "$NAMESPACE" "$TARGET_BACKUP_NAME")"
printf '[scenario-05-v2] waiting natively for %s Done=True before killing one virt-controller replica\n' \
  "$TARGET_BACKUP_NAME" >&2

krknctl run pod-scenarios \
  --namespace "$CONTROLLER_NAMESPACE" \
  --pod-label kubevirt.io=virt-controller \
  --disruption-count 1 \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
