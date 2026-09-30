#!/usr/bin/env bash
# Reproduces scenario 01-virt-launcher-pod-kill-during-copy using krknctl's
# native Kubernetes resource trigger (--trigger-k8s-*), instead of the
# external `oc get -w` + `oc delete pod` fallback in chaos-trigger.sh.
#
# Why this exists: krknctl's own container startup (image pull, cosign
# signature verification, python framework init — the `krkn` core's plugin
# discovery phase) takes ~5-9s before ANY chaos action can happen, including
# trigger evaluation, which only begins after that startup completes. This
# backend's full backup lifecycle (VirtualMachineBackup creation to
# Done=True) is ~5s and its incremental lifecycle is ~3s, so invoking krknctl
# "just in time" (when the backup is about to start) always misses the
# window — confirmed live in chaos-trigger.sh's history (see its header
# comment and scenario-spec.md §4).
#
# The fix: start this script (and therefore krknctl) EARLY — well before
# `make e2e` reaches the backup step, ideally right after the VM is created.
# krknctl's ~8s startup cost is absorbed while vm-setup is still running the
# guest SSH/data steps; by the time the target VirtualMachineBackup is
# actually created, krknctl is already warm and polling its own
# --trigger-k8s-condition (poll interval --triggers-interval, default 0.5s
# here), and fires the pod delete from the SAME already-running process —
# no second container-launch latency. This keeps the entire watch-and-kill
# inside krknctl, unlike chaos-trigger.sh's oc-based fallback.
#
# `K8sTrigger.evaluate()` (krkn/scenario_plugins/triggers/k8s_trigger.py)
# treats a NotFoundError as "condition not yet satisfied" rather than an
# error, so it's safe to target a backup name that doesn't exist yet when
# krknctl starts.
set -euo pipefail

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
RUN_NAME="${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
TARGET_BACKUP="${TARGET_BACKUP:-full}"
VM_NAME="${VM_NAME:-vm-${RUN_NAME}}"
case "$TARGET_BACKUP" in
  full) TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-backup-${RUN_NAME}}" ;;
  incremental) TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-incremental-${RUN_NAME}}" ;;
  *) printf 'TARGET_BACKUP must be full or incremental (got: %s)\n' "$TARGET_BACKUP" >&2; exit 2 ;;
esac

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
[[ -r "$KUBECONFIG_PATH" ]] || { printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2; exit 2; }
command -v krknctl >/dev/null 2>&1 || { printf 'krknctl is required\n' >&2; exit 2; }

# VirtualMachineBackup CRD group/version, confirmed on the live cluster via
# `oc get vmbackup <name> -o jsonpath='{.apiVersion}'`.
TRIGGER_K8S_API_VERSION="${TRIGGER_K8S_API_VERSION:-backup.kubevirt.io/v1alpha1}"
TRIGGER_K8S_KIND="${TRIGGER_K8S_KIND:-VirtualMachineBackup}"
# Trivially true the instant the object exists: metadata.name is always
# populated at creation, so this fires on first successful GET.
TRIGGER_K8S_CONDITION="${TRIGGER_K8S_CONDITION:-metadata.name == ${TARGET_BACKUP_NAME}}"
TRIGGERS_INTERVAL="${TRIGGERS_INTERVAL:-0.5}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1200}"

printf '[scenario-01-v2] starting krknctl now so its startup cost is absorbed\n' >&2
printf '[scenario-01-v2] before %s/%s %s exists; polling every %ss (timeout %ss)\n' \
  "$TRIGGER_K8S_KIND" "$TARGET_BACKUP_NAME" "$NAMESPACE" "$TRIGGERS_INTERVAL" "$TRIGGERS_TIMEOUT" >&2

krknctl run pod-scenarios \
  --namespace "$NAMESPACE" \
  --name-pattern "^virt-launcher-${VM_NAME}-" \
  --disruption-count 1 \
  --trigger-k8s-api-version "$TRIGGER_K8S_API_VERSION" \
  --trigger-k8s-kind "$TRIGGER_K8S_KIND" \
  --trigger-k8s-namespace "$NAMESPACE" \
  --trigger-k8s-name "$TARGET_BACKUP_NAME" \
  --trigger-k8s-condition "$TRIGGER_K8S_CONDITION" \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout skip \
  --kubeconfig "$KUBECONFIG_PATH"
