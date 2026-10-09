#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUN_ID="${RUN_ID:?set RUN_ID to a unique lowercase workflow run id}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="${VM_OS:-rhel9}"
MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-1024}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-1024}"
TRIGGER_TIMEOUT_SECONDS=1800
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
[[ -n "$KUBECONFIG_PATH" ]] || { printf 'KUBECONFIG_PATH or KUBECONFIG is required\n' >&2; exit 2; }

VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
SIGNAL_FILE="$(mktemp)"
observer_pid=""
command -v oc >/dev/null || { printf 'oc is required\n' >&2; exit 2; }
command -v krknctl >/dev/null || { printf 'krknctl is required\n' >&2; exit 2; }
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }
export KUBECONFIG="$KUBECONFIG_PATH"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists in this checkout\n' "$RUN_ID" >&2
  exit 1
fi
for resource in "vm/$VM_NAME" "vmbackup/$FULL_BACKUP_NAME" "vmbackuptracker/vm-tracker-$RUN_ID"; do
  if [[ -n "$(oc get "$resource" -n "$NAMESPACE" --ignore-not-found -o name)" ]]; then
    printf 'Resource %s already exists in namespace %s\n' "$resource" "$NAMESPACE" >&2
    exit 1
  fi
done

cleanup() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
  rm -f "$SIGNAL_FILE"
}
trap cleanup EXIT INT TERM

observe_copy_and_disrupt() {
  local deadline=$((SECONDS + TRIGGER_TIMEOUT_SECONDS))
  local launcher leader signal_line backup_json
  while ((SECONDS < deadline)); do

    launcher="$(oc get pod -n "$NAMESPACE" \
      -l "vm.kubevirt.io/name=$VM_NAME" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | sed -n '1p' || true)"
    if [[ -n "$launcher" ]]; then
      if signal_line="$(set +o pipefail; \
        oc logs --timestamps --follow -n "$NAMESPACE" "$launcher" -c compute 2>/dev/null | \
          grep -F -m1 '"msg":"Backup started"')" &&
         [[ "$signal_line" == *"\"backupName\":\"$FULL_BACKUP_NAME\""* ]]; then
        backup_json="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
          -o json --ignore-not-found 2>/dev/null || true)"
        if [[ -z "$backup_json" ]] || ! jq -e '
          all((.status.conditions // [])[]?; .type != "Done" or .status != "True")
        ' <<<"$backup_json" >/dev/null; then
          printf 'Full backup is already terminal or unavailable; refusing late injection.\n' >&2
          return 5
        fi
        printf 'Active-copy signal: %s in launcher %s\n' "$signal_line" "$launcher"
        leader="$(oc get lease virt-controller -n openshift-cnv \
          -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
        [[ "$leader" =~ ^virt-controller-[a-z0-9-]+$ ]] || {
          printf 'Lease holder is not a valid virt-controller pod: %s\n' "$leader" >&2
          return 3
        }
        : > "$SIGNAL_FILE"
        oc get pod "$leader" -n openshift-cnv -o json | jq -e \
          '.status.phase == "Running" and .metadata.labels["kubevirt.io"] == "virt-controller"' >/dev/null
        printf 'Deleting current controller leader through Krkn: %s\n' "$leader"
        krknctl run pod-scenarios \
          --kubeconfig "$KUBECONFIG_PATH" \
          --krkn-kubeconfig /home/krkn/.kube/config \
          --namespace openshift-cnv \
          --name-pattern "^${leader}$" \
          --disruption-count 1 \
          --execution serial \
          --kill-timeout 180 \
          --expected-recovery-time 120
        return 0
      fi
    fi
    sleep 1
  done
  printf 'Timed out waiting for exact active-copy signal for %s\n' "$FULL_BACKUP_NAME" >&2
  return 4
}

cd "$ROOT_DIR"
observe_copy_and_disrupt &
observer_pid=$!

if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  NAMESPACE="$NAMESPACE" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
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

if ((e2e_status != 0)); then
  exit "$e2e_status"
fi
if [[ ! -e "$SIGNAL_FILE" ]]; then
  exit "$observer_status"
fi
if make e2e TYPE=incremental VM="$VM_NAME" KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  followup_status=0
else
  followup_status=$?
fi
if ((observer_status != 0)); then
  exit "$observer_status"
fi
exit "$followup_status"
