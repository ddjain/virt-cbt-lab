#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

printf '[clean-all] Deleting namespace %s (VM, disks, services, trackers, backups, and PVCs).\n' "$NAMESPACE" >&2
oc_cmd delete namespace "$NAMESPACE" --ignore-not-found=true --wait=true --timeout=10m

printf '[clean-all] Waiting for demo persistent volumes to be reclaimed.\n' >&2
remaining_pvs=
for ((attempt = 1; attempt <= 60; attempt++)); do
  remaining_pvs="$(oc_cmd get pv -o 'jsonpath={range .items[?(@.spec.claimRef.namespace=="vm-cbt-demo")]}{.metadata.name}{","}{end}')"
  if [[ -z "$remaining_pvs" ]]; then
    break
  fi
  if (( attempt == 1 || attempt % 10 == 0 )); then
    printf '[clean-all] Still waiting for: %s\n' "${remaining_pvs//$'\n'/, }" >&2
  fi
  sleep 2
done
if [[ -n "$remaining_pvs" ]]; then
  printf '[clean-all] Persistent volumes are not reclaimed yet: %s\n' "${remaining_pvs//$'\n'/, }" >&2
  exit 1
fi

printf '[clean-all] Removing the generated guest SSH key at %s if this workflow owns it.\n' "$GUEST_KEY" >&2
marker="$GUEST_KEY.vm-cbt-managed"
if [[ -f "$marker" ]]; then
  rm -f "$GUEST_KEY" "$GUEST_KEY.pub" "$marker"
  rmdir "$(dirname "$GUEST_KEY")" 2>/dev/null || true
  printf 'Removed the workflow-managed guest key.\n'
else
  printf 'No workflow-managed key found; preserving any existing key files.\n'
fi
printf '[clean-all] Demo cleanup complete; shared KubeVirt and storage resources were left intact.\n' >&2
