#!/usr/bin/env bash
set -euo pipefail
# Print the density funnel. Default: one fleet view of every managed VM in
# the namespace — per-VM rows grouped by pool (batch), including VMs created
# outside any pool by `make e2e`. POOL=<pool> restricts the output to one
# pool. Read-only; takes no lock. All state comes from the cluster.
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/density-lib.sh
source "$ROOT_DIR/scripts/density-lib.sh"

WORKFLOW_NAME="density-status"

pool="${POOL:-}"

if [[ -n "$pool" ]]; then
  # One named pool: fail if it has no VMs.
  vms_json="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_POOL_KEY=$pool" -o json 2>/dev/null || true)"
  count="$(jq '.items | length' <<<"$vms_json")"
  if ((count == 0)); then
    printf 'Pool %s has no VMs in namespace %s.\n' "$pool" "$NAMESPACE" >&2
    exit 1
  fi
  density_print_funnel "$pool" "$vms_json"
  exit 0
fi

# Fleet view: every managed VM, grouped by pool; un-pooled managed VMs
# (created by make e2e directly) form their own group.
vms_json="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_SELECTOR" -o json 2>/dev/null || true)"
total="$(jq '.items | length' <<<"$vms_json")"
if ((total == 0)); then
  printf 'No virt-cbt-lab managed VMs in namespace %s; run make density-setup or make e2e first.\n' \
    "$NAMESPACE" >&2
  exit 0
fi

printf 'Namespace: %s  (%s managed VMs total)\n' "$NAMESPACE" "$total"
declare -i printed=0
while IFS=$'\t' read -r gpool; do
  if [[ "$gpool" == "(none)" ]]; then
    group_vms="$(jq '[.items[] | select((.metadata.labels["virt-cbt-lab/pool"] // "") == "")]' <<<"$vms_json")"
    label="no pool (make e2e)"
  else
    group_vms="$(jq --arg p "$gpool" '[.items[] | select(.metadata.labels["virt-cbt-lab/pool"] == $p)]' <<<"$vms_json")"
    label="$gpool"
  fi
  density_print_funnel "$label" "{\"items\": $group_vms}"
  printed+=1
done < <(jq -r '
  .items
  | group_by(.metadata.labels["virt-cbt-lab/pool"] // "(none)")
  | .[]
  | (.[0].metadata.labels["virt-cbt-lab/pool"] // "(none)")
' <<<"$vms_json")
