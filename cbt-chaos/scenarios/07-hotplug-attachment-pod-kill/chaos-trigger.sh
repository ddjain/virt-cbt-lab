#!/usr/bin/env bash
# Reproduces scenario 07-hotplug-attachment-pod-kill.
# This is an intentional, measured oc fallback: the hp-volume pod is often
# shorter-lived than krknctl's 5-9s image/startup path, so waiting to launch
# krknctl would miss the exact pre-VolumeMountedToPod boundary. The watch still
# targets only the attachment pod carrying this run's backup PVC and confirms
# that the delete was accepted; the resulting CR/events must be validated by
# the run report.
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
    incremental) TARGET_PVC="$INCREMENTAL_BACKUP_PVC_NAME" ;;
  esac
fi
chaos_require_tools

POLL_INTERVAL="${POLL_INTERVAL:-0.1}"
start_time=$SECONDS
attachment_pod=""
while (( SECONDS - start_time < TRIGGERS_TIMEOUT )); do
  attachment_pod="$(oc get pod -n "$NAMESPACE" -o json 2>/dev/null |
    jq -r --arg pvc "$TARGET_PVC" '
      .items[]?
      | select((.metadata.name // "") | startswith("hp-volume-"))
      | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
      | select((.status.phase // "") != "Running")
      | .metadata.name' |
    awk 'NF { print; exit }' || true)"
  if [[ -n "$attachment_pod" ]]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done

[[ -n "$attachment_pod" ]] || {
  printf '[scenario-07] timed out waiting for an attachment pod for %s\n' "$TARGET_PVC" >&2
  exit 1
}
printf '[scenario-07] deleting %s for PVC %s before it becomes Running\n' \
  "$attachment_pod" "$TARGET_PVC" >&2
oc delete pod "$attachment_pod" -n "$NAMESPACE" --wait=false

for ((attempt = 1; attempt <= 30; attempt++)); do
  if ! oc get pod "$attachment_pod" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf '[scenario-07] delete confirmed for %s\n' "$attachment_pod" >&2
    exit 0
  fi
  sleep 1
done

printf '[scenario-07] attachment pod %s still exists after delete\n' "$attachment_pod" >&2
exit 1
