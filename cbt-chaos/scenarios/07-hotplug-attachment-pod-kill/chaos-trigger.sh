#!/usr/bin/env bash
# Reproduces scenario 07-hotplug-attachment-pod-kill.
# Start this trigger before `make e2e NAME="$RUN_NAME"`; it injects as soon
# as this run's non-Running hotplug attachment pod appears.
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_PVC="${TARGET_PVC:-vm-backup-pvc-${RUN_NAME}}"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
[[ -r "$KUBECONFIG_PATH" ]] || { printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2; exit 2; }
export KUBECONFIG="$KUBECONFIG_PATH"
for command_name in oc krknctl jq sleep; do
  command -v "$command_name" >/dev/null 2>&1 ||
    { printf '%s is required\n' "$command_name" >&2; exit 2; }
done

POLL_INTERVAL="${POLL_INTERVAL:-0.1}"
TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-1200}"
attachment_pod() {
  oc get pod -n "$NAMESPACE" -o json 2>/dev/null |
    jq -r --arg pvc "$TARGET_PVC" '
      .items[]?
      | select((.metadata.name // "") | startswith("hp-volume-"))
      | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))
      | select((.status.phase // "") != "Running")
      | .metadata.name' |
    awk 'NF { print; exit }'
}

start_time=$SECONDS
while (( SECONDS - start_time < TRIGGER_TIMEOUT )); do
  pod="$(attachment_pod || true)"
  if [[ -n "$pod" ]]; then
    printf '[scenario-07] condition satisfied: %s exists for PVC %s\n' "$pod" "$TARGET_PVC" >&2
    break
  fi
  sleep "$POLL_INTERVAL"
done

if (( SECONDS - start_time >= TRIGGER_TIMEOUT )); then
  printf '[scenario-07] timed out waiting for a hotplug attachment pod for %s\n' "$TARGET_PVC" >&2
  exit 1
fi

krknctl run pod-scenarios \
  --namespace "$NAMESPACE" \
  --name-pattern "^${pod}$" \
  --disruption-count 1 \
  --kubeconfig "$KUBECONFIG_PATH"
