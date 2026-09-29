#!/usr/bin/env bash
# Reproduces scenario 01-virt-launcher-pod-kill-during-copy.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:?set to the VirtualMachineBackup name to target, e.g. hello-full or hello-incremental}"

echo "TODO: resolve the current virt-launcher pod name for the VMI in ${NAMESPACE}" >&2
# virt_launcher_pod=$(oc get pod -n "${NAMESPACE}" -l kubevirt.io=virt-launcher -o jsonpath='{.items[0].metadata.name}')

echo "TODO: poll virt-launcher compute container logs for the deterministic 'Backup started' condition" >&2
# oc logs -f -n "${NAMESPACE}" "${virt_launcher_pod}" -c compute \
#   | grep -m1 "Backup started"

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

krknctl run pod-scenarios \
  --namespace "${NAMESPACE}" \
  --name-pattern virt-launcher-vm-cbt-demo- \
  --disruption-count 1 \
  --kubeconfig "${KUBECONFIG_PATH}"
