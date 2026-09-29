#!/usr/bin/env bash
# Reproduces scenario 05-virt-controller-pod-kill-post-done.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-openshift-cnv}"
TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:?set to the VirtualMachineBackup name to watch}"

echo "TODO: poll VirtualMachineBackup Done condition for the first True transition" >&2
# until [ "$(oc get vmbackup "${TARGET_BACKUP_NAME}" -n "${NAMESPACE}" \
#   -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')" = "True" ]; do sleep 0.2; done

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

krknctl run pod-scenarios \
  --namespace "${CONTROLLER_NAMESPACE}" \
  --pod-label kubevirt.io=virt-controller \
  --disruption-count 1 \
  --kubeconfig "${KUBECONFIG_PATH}"
