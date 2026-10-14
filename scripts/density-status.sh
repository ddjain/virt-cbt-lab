#!/usr/bin/env bash
set -euo pipefail
# Print the density funnel for one pool (POOL=<pool>), the most recently
# created pool, or a namespace-wide overview of all pools plus every other
# managed VM in the namespace. Read-only; takes no lock. All state comes
# from the cluster — no local pool metadata is consulted.
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/density-lib.sh
source "$ROOT_DIR/scripts/density-lib.sh"

WORKFLOW_NAME="density-status"

pool="${POOL:-}"

vm_json_file="$(mktemp)"
trap 'rm -f "$vm_json_file"' EXIT
if ! oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_SELECTOR" -o json \
    >"$vm_json_file" 2>/dev/null; then
  printf '{"items":[]}' >"$vm_json_file"
fi

if [[ -n "$pool" ]]; then
  # One named pool: full funnel (per-VM rows).
  status_json="$(density_status_json "$pool")"
else
  # No POOL: namespace-wide overview. One summary line per pool plus one
  # for managed VMs without a pool label (created by make e2e directly).
  summary="$(jq -r '
    def ready: .status.ready == true;
    (.items | group_by(.metadata.labels["virt-cbt-lab/pool"] // "(none)")[]
      | (.[0].metadata.labels["virt-cbt-lab/pool"] // "(none)") as $p
      | "\($p)\t\(length)\t\([.[] | select(ready)] | length)"
    )
  ' "$vm_json_file")"
  if [[ -z "$summary" ]]; then
    printf 'No virt-cbt-lab managed VMs in namespace %s; run make density-setup or make e2e first.\n' \
      "$NAMESPACE" >&2
    exit 1
  fi
  printf 'Namespace: %s\n\n' "$NAMESPACE"
  printf '%-24s %8s %8s\n' 'POOL' 'TOTAL' 'READY'
  while IFS=$'\t' read -r p total ready; do
    printf '%-24s %8s %8s\n' "$p" "$total" "$ready"
  done <<<"$summary"
  exit 0
fi

os_profile="$(jq -r '.os_profile' <<<"$status_json")"
namespace="$(jq -r '.namespace' <<<"$status_json")"
passes="$(jq -r '.passes' <<<"$status_json")"
total="$(jq -r '.total' <<<"$status_json")"
ready_count="$(jq '[.vms[] | select(.state == "ready")] | length' <<<"$status_json")"

if ((total == 0)); then
  printf 'Pool %s has no VMs in namespace %s.\n' "$pool" "$namespace" >&2
  exit 1
fi

printf 'Pool: %s  OS: %s  Namespace: %s  Incremental passes: %s\n' \
  "$pool" "$os_profile" "$namespace" "$passes"
printf 'TOTAL=%s CREATING=%s CREATED=%s FULL=%s' \
  "$total" "$((total - ready_count))" "$ready_count" \
  "$(jq '[.vms[] | select(.full == "done")] | length' <<<"$status_json")"
for ((pass = 1; pass <= passes; pass++)); do
  printf ' INC%s=%s' "$pass" \
    "$(jq --argjson pass "$pass" '[.vms[] | select(.incrementals[$pass - 1] == "done")] | length' <<<"$status_json")"
done
printf '\n\n'

printf '%-26s %-9s %-8s' 'RUN_ID' 'VM_STATE' 'FULL'
for ((pass = 1; pass <= passes; pass++)); do
  printf ' %-8s' "INC$pass"
done
printf '\n'
while IFS= read -r row; do
  run_id="$(jq -r '.run_id' <<<"$row")"
  vm_state="$(jq -r '.state' <<<"$row")"
  printf '%-26s %-9s %-8s' "$run_id" "$vm_state" "$(jq -r '.full' <<<"$row")"
  for ((pass = 1; pass <= passes; pass++)); do
    printf ' %-8s' "$(jq -r --argjson pass "$pass" '.incrementals[$pass - 1]' <<<"$row")"
  done
  printf '\n'
done < <(jq -c '.vms[]' <<<"$status_json")
