#!/usr/bin/env bash
# Shared, read-only trigger construction for the numbered CBT chaos scenarios.
# Individual scenario scripts remain the executable source of truth for the
# disruption command and its target-specific safety checks.
set -euo pipefail

chaos_set_run_names() {
  : "${RUN_NAME:?set RUN_NAME to the exact make e2e NAME value}"
  NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
  VM_NAME="${VM_NAME:-vm-${RUN_NAME}}"
  TARGET_BACKUP="${TARGET_BACKUP:-full}"
  case "$TARGET_BACKUP" in
    full) TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-backup-${RUN_NAME}}" ;;
    incremental) TARGET_BACKUP_NAME="${TARGET_BACKUP_NAME:-vm-incremental-${RUN_NAME}}" ;;
    *)
      printf 'TARGET_BACKUP must be full or incremental (got: %s)\n' "$TARGET_BACKUP" >&2
      exit 2
      ;;
  esac
  KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/config}}"
  TRIGGERS_INTERVAL="${TRIGGERS_INTERVAL:-0.5}"
  TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1200}"
}

chaos_require_tools() {
  [[ -r "$KUBECONFIG_PATH" ]] || {
    printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2
    exit 2
  }
  export KUBECONFIG="$KUBECONFIG_PATH"
  for command_name in oc jq awk sleep; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf '%s is required\n' "$command_name" >&2
      exit 2
    }
  done
}

chaos_require_krknctl() {
  command -v krknctl >/dev/null 2>&1 || {
    printf 'krknctl is required\n' >&2
    exit 2
  }
}

chaos_wait_for_vm_pod() {
  local start_time=$SECONDS pod_name=""
  local timeout_seconds="${1:-$TRIGGERS_TIMEOUT}"
  while (( SECONDS - start_time < timeout_seconds )); do
    pod_name="$(oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod_name" ]]; then
      printf '%s\n' "$pod_name"
      return 0
    fi
    sleep 2
  done
  printf 'Timed out waiting for a virt-launcher pod for %s in %s\n' \
    "$VM_NAME" "$NAMESPACE" >&2
  return 1
}

chaos_resolve_node() {
  local pod_name
  pod_name="$(chaos_wait_for_vm_pod)"
  oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}'
  printf '\n'
}

chaos_resolve_checkpoint_pvc() {
  local start_time=$SECONDS pod_name="" pvc_name=""
  while (( SECONDS - start_time < TRIGGERS_TIMEOUT )); do
    pod_name="$(chaos_wait_for_vm_pod 10 2>/dev/null || true)"
    if [[ -n "$pod_name" ]]; then
      pvc_name="$(oc get pod "$pod_name" -n "$NAMESPACE" -o json 2>/dev/null |
        jq -r '.spec.volumes[]?.persistentVolumeClaim.claimName // empty' |
        awk '/^persistent-state-for-/{print; exit}' || true)"
      if [[ -n "$pvc_name" ]]; then
        printf '%s\n' "$pvc_name"
        return 0
      fi
    fi
    sleep 1
  done
  printf 'Could not resolve the CBT persistent-state PVC from a virt-launcher pod for %s\n' \
    "$VM_NAME" >&2
  return 1
}

# These functions emit shell snippets consumed by krknctl's native
# --trigger-command mechanism. They are evaluated inside the krkn container,
# after its startup cost has been absorbed, and return 0 only at the intended
# Kubernetes-observable lifecycle boundary.
chaos_backup_done_trigger() {
  local namespace="$1" backup_name="$2"
  printf -v namespace_q '%q' "$namespace"
  printf -v backup_q '%q' "$backup_name"
  printf 'test "$(oc get vmbackup %s -n %s -o '\''jsonpath={.status.conditions[?(@.type=="Done")].status}'\'' 2>/dev/null)" = True' \
    "$backup_q" "$namespace_q"
}

chaos_backup_progressing_trigger() {
  local namespace="$1" backup_name="$2"
  printf -v namespace_q '%q' "$namespace"
  printf -v backup_q '%q' "$backup_name"
  printf 'test "$(oc get vmbackup %s -n %s -o '\''jsonpath={.status.conditions[?(@.type=="Progressing")].status}'\'' 2>/dev/null)" = True' \
    "$backup_q" "$namespace_q"
}

chaos_backup_started_trigger() {
  local namespace="$1" vm_name="$2" backup_name="$3"
  printf -v namespace_q '%q' "$namespace"
  printf -v vm_q '%q' "$vm_name"
  printf -v backup_q '%q' "$backup_name"
  printf 'pod=$(oc get pod -n %s -l vm.kubevirt.io/name=%s -o '\''jsonpath={.items[0].metadata.name}'\'' 2>/dev/null); test -n "$pod" && test "$(oc get vmbackup %s -n %s -o '\''jsonpath={.status.conditions[?(@.type=="Done")].status}'\'' 2>/dev/null)" != True && oc logs -n %s "$pod" -c compute --tail=2000 2>/dev/null | grep -F -- %s | grep -F -- '\''Backup started'\''' \
    "$namespace_q" "$vm_q" "$backup_q" "$namespace_q" "$namespace_q" "$backup_q"
}

chaos_tracker_checkpoint_trigger() {
  local namespace="$1" tracker_name="$2" incremental_name="$3"
  printf -v namespace_q '%q' "$namespace"
  printf -v tracker_q '%q' "$tracker_name"
  printf -v incremental_q '%q' "$incremental_name"
  printf 'checkpoint=$(oc get vmbackuptracker %s -n %s -o '\''jsonpath={.status.latestCheckpoint.name}'\'' 2>/dev/null); test -n "$checkpoint" && ! oc get vmbackup %s -n %s >/dev/null 2>&1' \
    "$tracker_q" "$namespace_q" "$incremental_q" "$namespace_q"
}


