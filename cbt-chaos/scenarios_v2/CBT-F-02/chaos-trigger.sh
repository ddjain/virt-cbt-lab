#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NAME="${NAME:?set a unique NAME/run ID}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="${VM_OS:-rhel9}"
MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}"
GUEST_BASE_FILE_COUNT=8
GUEST_FILE_SIZE_MIN_MIB=1024
GUEST_FILE_SIZE_MAX_MIB=1024
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved host-local kubeconfig path}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

if [[ ! "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || ((${#NAME} > 40)); then
  printf 'NAME must be a lowercase DNS-safe run ID of at most 40 characters.\n' >&2
  exit 2
fi
if [[ ! "$NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  printf 'NAMESPACE must be a lowercase DNS namespace.\n' >&2
  exit 2
fi
for command in oc krknctl make jq; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '%s is required.\n' "$command" >&2
    exit 127
  }
done

VM_NAME="vm-${NAME}"
BACKUP_NAME="vm-backup-${NAME}"
LABEL_SELECTOR="vm.kubevirt.io/name=${VM_NAME}"
if [[ -e "$ROOT_DIR/runs/$NAME" ]]; then
  printf 'Run ID %s already exists in this checkout; refusing to reuse it.\n' "$NAME" >&2
  exit 1
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$NAME"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$NAME" "$NAMESPACE" >&2
  exit 1
fi

SIGNAL_FILE="$(mktemp)"
observer_pid=""
cleanup() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
  rm -f "$SIGNAL_FILE"
}
trap cleanup EXIT INT TERM

observe_copy_then_disrupt() {
  local deadline=$((SECONDS + 3600)) pod signal_line backup_json pod_uid
  while ((SECONDS < deadline)); do
    pod="$(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      if signal_line="$(set +o pipefail; \
        oc logs --timestamps --follow -n "$NAMESPACE" "$pod" -c compute 2>/dev/null | \
          grep -F -m1 '"msg":"Backup started"')" &&
          [[ "$signal_line" == *"\"backupName\":\"$BACKUP_NAME\""* ]]; then
        backup_json="$(oc get vmbackup "$BACKUP_NAME" -n "$NAMESPACE" \
          -o json --ignore-not-found 2>/dev/null || true)"
        if [[ -z "$backup_json" ]] || ! jq -e '
          all((.status.conditions // [])[]?; .type != "Done" or .status != "True")
        ' <<<"$backup_json" >/dev/null; then
          printf 'The full backup is already terminal or unavailable; refusing late injection.\n' >&2
          return 1
        fi
        pod_uid="$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
        printf 'Active-copy signal for %s observed in launcher %s (UID %s).\n' \
          "$BACKUP_NAME" "$pod" "$pod_uid" >&2
        : > "$SIGNAL_FILE"
        krknctl run container-scenarios \
          --namespace "$NAMESPACE" \
          --label-selector "$LABEL_SELECTOR" \
          --container-name compute \
          --action 9 \
          --disruption-count 1 \
          --expected-recovery-time 60 \
          --kubeconfig "$KUBECONFIG_PATH" \
          --krkn-kubeconfig /home/krkn/.kube/config
        return
      fi
    fi
    sleep 1
  done
  printf 'Timed out waiting for the run launcher and exact Backup started signal.\n' >&2
  return 1
}

cd "$ROOT_DIR"
observe_copy_then_disrupt &
observer_pid=$!

if make e2e TYPE=full NAME="$NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi
if [[ ! -e "$SIGNAL_FILE" ]]; then
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
observer_pid=""
printf 'E2E exit status: %d; observer/Krkn exit status: %d\n' \
  "$e2e_status" "$observer_status" >&2
if ((e2e_status != 0)); then
  exit "$e2e_status"
fi
exit "$observer_status"
