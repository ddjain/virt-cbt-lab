#!/usr/bin/env bash
set -euo pipefail
# Print one density pool's creation/backup funnel. Read-only; takes no lock.
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/density-lib.sh
source "$ROOT_DIR/scripts/density-lib.sh"

WORKFLOW_NAME="density-status"

pool="${POOL:-}"
if [[ -z "$pool" ]]; then
  pool="$(density_latest_pool)"
fi
pool_file="$(density_pool_file "$pool")"
if [[ ! -f "$pool_file" ]]; then
  printf 'Unknown pool %s (no %s)\n' "$pool" "$pool_file" >&2
  exit 1
fi

status_json="$(density_status_json "$pool")"

os_profile="$(jq -r '.os_profile' <<<"$status_json")"
namespace="$(jq -r '.namespace' <<<"$status_json")"
passes="$(jq -r '.passes' <<<"$status_json")"
total="$(jq -r '.total' <<<"$status_json")"
ready_count="$(jq '[.vms[] | select(.state == "ready")] | length' <<<"$status_json")"

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
