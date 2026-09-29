#!/usr/bin/env bash
# Reproduces scenario 10-node-io-hog-during-copy.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"

echo "TODO: resolve the current virt-launcher pod name and hosting (HPP) node in ${NAMESPACE}" >&2
# virt_launcher_pod=$(oc get pod -n "${NAMESPACE}" -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.name}')
# node_name=$(oc get pod "${virt_launcher_pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')

echo "TODO: poll virt-launcher compute container logs for the deterministic 'Backup started' condition" >&2
# oc logs -f -n "${NAMESPACE}" "${virt_launcher_pod}" -c compute \
#   | grep -m1 "Backup started"

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

krknctl run node-io-hog \
  --namespace "${NAMESPACE}" \
  --node-selector "kubernetes.io/hostname=${node_name}" \
  --chaos-duration 30 \
  --kubeconfig "${KUBECONFIG_PATH}"
