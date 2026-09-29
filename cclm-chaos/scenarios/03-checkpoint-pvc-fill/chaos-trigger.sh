#!/usr/bin/env bash
# Reproduces scenario 03-checkpoint-pvc-fill.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:?set to the VirtualMachineBackup name to target}"

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

persistent_state_pvc=$(oc get pvc -n "${NAMESPACE}" -o name | grep persistent-state-for-vm-cbt-demo | sed 's#^persistentvolumeclaim/##')

until [ "$(oc get vmbackup "${TARGET_BACKUP_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" = "True" ]; do sleep 1; done

krknctl run pvc-scenarios \
  --namespace "${NAMESPACE}" \
  --pvc-name "${persistent_state_pvc}" \
  --fill-percentage 95 \
  --duration 60 \
  --kubeconfig "${KUBECONFIG_PATH}"
