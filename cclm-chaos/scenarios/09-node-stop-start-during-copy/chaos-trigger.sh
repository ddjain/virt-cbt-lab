#!/usr/bin/env bash
# Reproduces scenario 09-node-stop-start-during-copy.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"

echo "TODO: resolve the current virt-launcher pod name and hosting node in ${NAMESPACE}" >&2
# virt_launcher_pod=$(oc get pod -n "${NAMESPACE}" -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.name}')
# node_name=$(oc get pod "${virt_launcher_pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')

echo "TODO: poll virt-launcher compute container logs for the deterministic 'Backup started' condition" >&2
# oc logs -f -n "${NAMESPACE}" "${virt_launcher_pod}" -c compute \
#   | grep -m1 "Backup started"

# NEEDS VALIDATION: this scenario requires real bare-metal BMC/IPMI credentials for the target node
# (<target-host> is confirmed BareMetal platform, so --cloud-type bm is required, which in turn requires
# --bmc-user/--bmc-password/--bmc-address). Do not hardcode credentials here — source them from your
# secrets-management process at run time.
KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"
BMC_USER="${BMC_USER:?set to the IPMI/BMC username for the target node, from your secrets store}"
BMC_PASSWORD="${BMC_PASSWORD:?set to the IPMI/BMC password for the target node, from your secrets store}"
BMC_ADDRESS="${BMC_ADDRESS:?set to the IPMI/BMC address for the target node, from your secrets store}"

krknctl run node-scenarios \
  --action node_stop_start_scenario \
  --node-name "${node_name}" \
  --cloud-type bm \
  --bmc-user "${BMC_USER}" \
  --bmc-password "${BMC_PASSWORD}" \
  --bmc-address "${BMC_ADDRESS}" \
  --kubeconfig "${KUBECONFIG_PATH}"
