#!/usr/bin/env bash
# Reproduces scenario 08-guest-network-filter-during-mutation.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_NAME="${VM_NAME:-vm-cbt-demo}"

echo "TODO: hook this into the pipeline immediately before common.sh:guest_ssh runs for the" >&2
echo "      post-full-backup guest mutation step (script-driven condition, not cluster-observable)." >&2

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

krknctl run vmi-network-filter \
  --namespace "${NAMESPACE}" \
  --vmi-name "${VM_NAME}" \
  --ingress true \
  --egress false \
  --ports 22 \
  --protocols tcp \
  --chaos-duration 30 \
  --kubeconfig "${KUBECONFIG_PATH}"
