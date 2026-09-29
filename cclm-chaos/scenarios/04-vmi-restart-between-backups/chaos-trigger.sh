#!/usr/bin/env bash
# Reproduces scenario 04-vmi-restart-between-backups.
# See scenario-spec.md §3/§4 for the injection command and timing condition this implements.
# TODO: fill in once validated against the live cluster (see chaos-plan.md and scenario-spec.md TODOs).
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_NAME="${VM_NAME:-vm-cbt-demo}"
FULL_CHECKPOINT_NAME="${FULL_CHECKPOINT_NAME:?set to the completed full backup checkpoint name}"

echo "TODO: poll VirtualMachineBackupTracker.status.latestCheckpoint.name for the full checkpoint" >&2
# until [ "$(oc get vmbackuptracker hello-tracker -n "${NAMESPACE}" -o jsonpath='{.status.latestCheckpoint.name}')" = "${FULL_CHECKPOINT_NAME}" ]; do sleep 1; done

echo "TODO: confirm no incremental VirtualMachineBackup CR exists yet" >&2
# oc get vmbackup -n "${NAMESPACE}" | grep -q incremental && exit 1 || true

KUBECONFIG_PATH="${KUBECONFIG_PATH:?set to the krknctl-side path/copy of the cluster kubeconfig, e.g. /path/to/cluster/kubeconfig on <target-host>}"

krknctl run kubevirt-outage \
  --namespace "${NAMESPACE}" \
  --vm-name "${VM_NAME}" \
  --kill-count 1 \
  --kubeconfig "${KUBECONFIG_PATH}"
