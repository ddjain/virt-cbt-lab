#!/usr/bin/env bash
# Reproduces scenario 07-hotplug-attachment-pod-kill.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"

echo "TODO: poll for an hp-volume-* attachment pod that exists but is not yet Running" >&2
# until oc get pod -n "${NAMESPACE}" -o name | grep -q '^pod/hp-volume-'; do sleep 0.5; done

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

krknctl run pod-scenarios \
  --namespace "${NAMESPACE}" \
  --name-pattern hp-volume- \
  --disruption-count 1 \
  --kubeconfig "${KUBECONFIG_PATH}"
