#!/usr/bin/env bash
# Reproduces scenario 01-virt-launcher-pod-kill-during-copy.
# Start this trigger before `make e2e NAME="$RUN_NAME"`; it injects the moment
# the target VirtualMachineBackup object is created.
#
# History of injection-mechanism attempts (see scenario-spec.md §4 for the
# full writeup) — kept here so this is not re-litigated:
#  1. A polling loop (sleep + repeated oc get pod / oc get vmbackup / oc logs
#     calls) then krknctl. Too slow: ~10s of detection lag from sequential oc
#     round-trips missed the ~5s backup window entirely.
#  2. A single long-lived `oc get -w` watch (near-instant detection) then
#     krknctl. Still too slow: krknctl's own container startup (image pull +
#     signature verification + python init) took 5-9s before it issued the
#     pod delete, which alone exceeds this backend's full backup lifecycle
#     (~5s creation-to-Done) and incremental lifecycle (~3s). Confirmed live
#     (run chaos01-0930-1021): the watch matched correctly, but both full and
#     incremental backups had already reached Done=True before krknctl's kill
#     landed.
#  3. Current: same `oc get -w` watch, but the actual kill is a direct
#     `oc delete pod` (no krknctl) so there is no container-startup cost
#     between detection and the kill. This is the documented, measured
#     justification for falling back to oc per AGENTS.md's "fall back to oc
#     only when documented and justified" rule.
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
export KUBECONFIG="$KUBECONFIG_PATH"
for command_name in oc grep timeout; do
  command -v "$command_name" >/dev/null 2>&1 ||
    { printf '%s is required\n' "$command_name" >&2; exit 2; }
done

TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-1200}"
POD_WAIT_INTERVAL="${POD_WAIT_INTERVAL:-2}"

# Not time-critical: vm-setup can take minutes (image pull, VM boot) before
# the backup step is anywhere near starting, so a plain poll is fine here.
printf '[scenario-01] waiting for the virt-launcher pod for VM %s\n' "$VM_NAME" >&2
pod_name=""
start_time=$SECONDS
while (( SECONDS - start_time < TRIGGER_TIMEOUT )); do
  pod_name="$(oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod_name" ]] && break
  sleep "$POD_WAIT_INTERVAL"
done
[[ -n "$pod_name" ]] || { printf 'Timed out waiting for a virt-launcher pod for VM %s in %s\n' "$VM_NAME" "$NAMESPACE" >&2; exit 2; }
printf '[scenario-01] target pod resolved: %s\n' "$pod_name" >&2

printf '[scenario-01] watching for %s to appear in %s\n' "$TARGET_BACKUP_NAME" "$NAMESPACE" >&2
matched_line="$(timeout "$TRIGGER_TIMEOUT" oc get vmbackup -n "$NAMESPACE" -w --no-headers 2>/dev/null \
  | grep -m1 -E "^${TARGET_BACKUP_NAME}[[:space:]]" || true)"

if [[ -z "$matched_line" ]]; then
  printf '[scenario-01] timed out waiting for %s to appear\n' "$TARGET_BACKUP_NAME" >&2
  exit 1
fi

printf '[scenario-01] condition satisfied: %s\n' "$matched_line" >&2

oc delete pod "$pod_name" -n "$NAMESPACE" --wait=false
printf '[scenario-01] delete issued for %s\n' "$pod_name" >&2
