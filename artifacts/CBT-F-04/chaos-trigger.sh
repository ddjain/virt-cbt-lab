#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# --- Workload-env hardening (added after run 20261015-cbtf04-r02) --------------
# That run's launch sourced a checkout-wide .env wholesale, leaking
# GUEST_BASE_FILE_COUNT=1000 / 15-20 MiB sizing over the spec's 8 x 1024 MiB
# (trigger/exit-statuses.json: abort_cause). The spec-documented launch env is
# RUN_ID (required) plus KUBECONFIG_PATH only. If the inherited environment
# carries any non-spec workload value, abort before any mutation (exit 3).
if [[ "${GUEST_BASE_FILE_COUNT}" != "8" \
   || "${GUEST_FILE_SIZE_MIN_MIB}" != "1024" \
   || "${GUEST_FILE_SIZE_MAX_MIB}" != "1024" \
   || "${MANIFEST_VARIANT}" != "large-odf" \
   || "${VM_OS}" != "rhel9" \
   || "${GUEST_INCREMENTAL_FILE_COUNT:-2}" != "2" \
   || "${GUEST_INCREMENTAL_PASSES:-1}" != "1" ]]; then
  printf 'Refusing to run: workload env differs from the spec-documented values (possible .env leak).\n' >&2
  printf 'Expected: GUEST_BASE_FILE_COUNT=8 GUEST_FILE_SIZE_MIN_MIB=1024 GUEST_FILE_SIZE_MAX_MIB=1024 MANIFEST_VARIANT=large-odf VM_OS=rhel9 GUEST_INCREMENTAL_FILE_COUNT=2 GUEST_INCREMENTAL_PASSES=1\n' >&2
  printf 'Effective: GUEST_BASE_FILE_COUNT=%s GUEST_FILE_SIZE_MIN_MIB=%s GUEST_FILE_SIZE_MAX_MIB=%s MANIFEST_VARIANT=%s VM_OS=%s GUEST_INCREMENTAL_FILE_COUNT=%s GUEST_INCREMENTAL_PASSES=%s\n' \
    "$GUEST_BASE_FILE_COUNT" "$GUEST_FILE_SIZE_MIN_MIB" "$GUEST_FILE_SIZE_MAX_MIB" "$MANIFEST_VARIANT" "$VM_OS" "${GUEST_INCREMENTAL_FILE_COUNT:-<unset>}" "${GUEST_INCREMENTAL_PASSES:-<unset>}" >&2
  printf 'Launch with a clean environment: only RUN_ID and KUBECONFIG_PATH set.\n' >&2
  exit 3
fi
# Incidental GUEST_* extras this script does not pin must not reach the make
# children either (r02 also leaked GUEST_INCREMENTAL_FILE_COUNT/PASSES).
unset GUEST_INCREMENTAL_FILE_COUNT GUEST_INCREMENTAL_PASSES

# --- Incremental-pass sizing pin (added after run 20261015-cbtf04-r03) ---------
# A clean launch env does not close the checkout Makefile's -include .env
# path: that run leaked GUEST_INCREMENTAL_FILE_COUNT=1000 from .env into the
# incremental plan despite the clean-env launch, causing guest ENOSPC
# (attempt-1) and destination ENOSPC (retry-3). Make command-line assignments
# override anything an included .env sets, so both make invocations pin these
# on argv; the values are also assigned here for the guard's default checks.
GUEST_INCREMENTAL_FILE_COUNT="2"
GUEST_INCREMENTAL_PASSES="1"

# --- Incremental stage-outcome recording (added after run 20261015-cbtf04-r02) -
# That run's abort killed the trigger before any stage outcome reached disk,
# leaving run.json stale and forcing a human-approved repair (ledger.jsonl
# run_json_repaired). Record each stage outcome as it happens so an abort at
# any point leaves a durable per-stage record next to the trigger artifacts.
record_stage() {
  local stage="$1" status="$2"
  local out="${EXIT_STATUS_FILE:-$SCRIPT_DIR/runs/$RUN_ID/trigger/stage-outcomes.jsonl}"
  mkdir -p "$(dirname "$out")"
  printf '{"stage": "%s", "status": "%s", "utc": "%s"}\n' \
    "$stage" "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out"
}
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
record_stage make_e2e_full started
observer_pid=$!

if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  NAMESPACE="$NAMESPACE" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi
record_stage make_e2e_full "exited:$e2e_status"

if [[ ! -e "$SIGNAL_FILE" ]]; then
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
observer_pid=""
record_stage observer "exited:$observer_status"

if ((e2e_status != 0)); then
  exit "$e2e_status"
fi
if [[ ! -e "$SIGNAL_FILE" ]]; then
  exit "$observer_status"
fi

# --- Leg-3 dirty-block churn (matrix leg 20261015-cbtf04: deliberate) ----------
# Between the full checkpoint and the incremental pass, write a known volume
# of guest data and delete it. CBT tracks blocks written since the
# checkpoint, not live data, so the incremental should copy the PEAK dirty
# volume (~churn bytes + pass mutation), not the logical delta. This
# reproduces run r03's accidental finding under deliberate, controlled
# conditions with a correctly sized destination. Churn size and destination
# size are make-argv pins (never exported env) so checkout .env cannot
# override them.
CHURN_BYTES_GIB="${CHURN_BYTES_GIB:-60}"
INCREMENTAL_PVC_SIZE="${INCREMENTAL_PVC_SIZE:-100Gi}"
if [[ -n "$DIRTY_BLOCK_CHURN" ]]; then
  record_stage dirty_block_churn started
  printf 'Dirty-block churn: writing %s GiB then deleting it in the guest\n' "$CHURN_BYTES_GIB"
  churn_out="$("$SCRIPT_DIR/guest-churn.sh" "$RUN_ID" "$CHURN_BYTES_GIB" \
    "$SCRIPT_DIR/runs/$RUN_ID/trigger/churn-record.json" 2>&1)"
  churn_status=$?
  printf '%s\n' "$churn_out"
  record_stage dirty_block_churn "exited:$churn_status"
  if ((churn_status != 0)); then
    printf 'Dirty-block churn failed; not proceeding to the incremental.\n' >&2
    exit "$churn_status"
  fi
fi

record_stage make_e2e_incremental started
if make e2e TYPE=incremental VM="$VM_NAME" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  INCREMENTAL_PVC_SIZE="$INCREMENTAL_PVC_SIZE" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  followup_status=0
else
  followup_status=$?
fi
record_stage make_e2e_incremental "exited:$followup_status"
if ((observer_status != 0)); then
  exit "$observer_status"
fi
exit "$followup_status"
