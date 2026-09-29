#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="clean-all"

workflow_step "1/3 Delete demo namespace resources"
workflow_action "oc delete namespace $NAMESPACE --ignore-not-found=true --wait=true --timeout=10m"
oc_cmd delete namespace "$NAMESPACE" --ignore-not-found=true --wait=true --timeout=10m
workflow_success "Namespace $NAMESPACE deletion completed"

workflow_step "2/3 Wait for demo persistent volumes to be reclaimed"
workflow_action "Poll PV claim references for namespace $NAMESPACE (up to 2 minutes)"
remaining_pv_names=
for ((attempt = 1; attempt <= 60; attempt++)); do
  remaining_pv_names="$(oc_cmd get pv -o "jsonpath={range .items[?(@.spec.claimRef.namespace==\"$NAMESPACE\")]}{.metadata.name}{\",\"}{end}")"
  if [[ -z "$remaining_pv_names" ]]; then
    break
  fi
  if (( attempt == 1 || attempt % 10 == 0 )); then
    workflow_action "PV reclamation pending: ${remaining_pv_names//$'\n'/, } (poll $attempt/60)"
  fi
  sleep 2
done
if [[ -n "$remaining_pv_names" ]]; then
  printf '[clean-all] Persistent volumes are not reclaimed yet: %s\n' "${remaining_pv_names//$'\n'/, }" >&2
  exit 1
fi
workflow_success "All demo PVs are reclaimed"

workflow_step "3/3 Remove only the workflow-managed guest key"
workflow_action "Check ownership marker $GUEST_KEY.vm-cbt-managed before deleting key files"
marker="$GUEST_KEY.vm-cbt-managed"
if [[ -f "$marker" ]]; then
  # The marker prevents cleanup from deleting a key supplied by the user.
  rm -f "$GUEST_KEY" "$GUEST_KEY.pub" "$marker"
  rmdir "$(dirname "$GUEST_KEY")" 2>/dev/null || true
  workflow_success "Removed workflow-managed guest key"
else
  workflow_success "No workflow-managed key found; existing key files preserved"
fi
printf '[clean-all] Demo cleanup complete; shared KubeVirt and storage resources were left intact.\n' >&2
