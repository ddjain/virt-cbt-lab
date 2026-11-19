#!/usr/bin/env bash
set -euo pipefail
# Create a density VM pool with kube-burner: N bare VMs (VM + root DV, plus
# an SSH Service for RHEL; a shared OOBE Secret for Windows). No baseline
# workload, tracker, or backups happen here — a VM joins the normal pipeline
# only when adopted via `make e2e EXISTING_VM=vm-<pool>-NNNN`.
# Uses only kube-burner features present in 2.1.1.
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WORKFLOW_NAME="density-setup"

# shellcheck source=scripts/density-lib.sh
source "$ROOT_DIR/scripts/density-lib.sh"

DENSITY_VM_COUNT="${DENSITY_VM_COUNT:-}"
DENSITY_INCREMENTAL_PASSES="${DENSITY_INCREMENTAL_PASSES:-4}"
DENSITY_QPS="${DENSITY_QPS:-10}"
DENSITY_WAIT_MINUTES="${DENSITY_WAIT_MINUTES:-240}"
POOL="${POOL:-}"
# Extend an existing pool: new VMs are numbered START+1..START+COUNT. START must
# equal the pool's current VM count; 0 (default) requires an unused pool.
DENSITY_START_INDEX="${DENSITY_START_INDEX:-0}"

case "$VM_OS" in
  rhel9|rhel9-light|windows) ;;
  *)
    printf 'density-setup supports VM_OS=rhel9, rhel9-light or windows (got: %s)\n' "$VM_OS" >&2
    exit 1
    ;;
esac
if ! [[ "$DENSITY_VM_COUNT" =~ ^[1-9][0-9]{0,3}$ ]]; then
  printf 'DENSITY_VM_COUNT is required and must be an integer from 1 to 9999 (got: %s).\n' \
    "${DENSITY_VM_COUNT:-<unset>}" >&2
  exit 1
fi
if ! [[ "$DENSITY_INCREMENTAL_PASSES" =~ ^[1-9][0-9]?$ ]]; then
  printf 'DENSITY_INCREMENTAL_PASSES must be an integer from 1 to 99 (got: %s).\n' "$DENSITY_INCREMENTAL_PASSES" >&2
  exit 1
fi
if ! [[ "$DENSITY_START_INDEX" =~ ^[0-9]{1,4}$ ]] || (( DENSITY_START_INDEX + DENSITY_VM_COUNT > 9999 )); then
  printf 'DENSITY_START_INDEX must be an integer with START+COUNT <= 9999 (got: %s).\n' "$DENSITY_START_INDEX" >&2
  exit 1
fi
validate_positive_integer DENSITY_QPS "$DENSITY_QPS"
validate_positive_integer DENSITY_WAIT_MINUTES "$DENSITY_WAIT_MINUTES"
if [[ -z "$POOL" ]]; then
  # OS-prefixed timestamp: names read vm-<os>-<ts>-NNNN, unique across runs.
  case "$VM_OS" in
    rhel9) POOL="rhel-$(date -u +%m%d%H%M%S)" ;;
    windows) POOL="win-$(date -u +%m%d%H%M%S)" ;;
    *) POOL="d$(date -u +%m%d%H%M%S)" ;;
  esac
fi
if ! valid_pool_id "$POOL"; then
  printf 'POOL must be lowercase alphanumeric with internal hyphens and at most 20 characters (got: %s).\n' "$POOL" >&2
  exit 1
fi
pool_vm_count="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_POOL_KEY=$POOL" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
if (( DENSITY_START_INDEX == 0 )); then
  if (( pool_vm_count > 0 )); then
    printf 'Pool %s already has VMs in namespace %s; choose another POOL.\n' \
      "$POOL" "$NAMESPACE" >&2
    exit 1
  fi
elif (( pool_vm_count != DENSITY_START_INDEX )); then
  printf 'Pool %s has %s VMs but DENSITY_START_INDEX=%s; they must match to extend without name collisions.\n' \
    "$POOL" "$pool_vm_count" "$DENSITY_START_INDEX" >&2
  exit 1
fi

if [[ "$VM_OS" == rhel9 || "$VM_OS" == rhel9-light ]]; then
  public_key="$(ensure_guest_key)"
  OBJECT_TEMPLATE="$ROOT_DIR/manifests/density/rhel-vm.yaml"
  DISK_SIZE="$LARGE_MANIFEST_DISK_SIZE"
  case "$MANIFEST_VARIANT" in
    odf|large-odf) STORAGE_CLASS="ocs-storagecluster-ceph-rbd" ;;
    *) STORAGE_CLASS="cbt-demo-hpp" ;;
  esac
  # ROOT_SC: optional override for the root-disk StorageClass (e.g. replica-1
  # cbt-scale-pool for scale-test fleets; test data only, zero durability).
  STORAGE_CLASS="${ROOT_SC:-$STORAGE_CLASS}"
else
  # shellcheck source=scripts/windows-oobe-secret.sh
  source "$ROOT_DIR/scripts/windows-oobe-secret.sh"
  if (( DENSITY_START_INDEX == 0 )); then
    create_windows_oobe_secret "windows-oobe-$POOL" "$RUN_LABEL_POOL_KEY" "$POOL"
  fi # extending: keep the pool secret existing VMs reference
  OBJECT_TEMPLATE="$ROOT_DIR/manifests/density/windows-vm.yaml"
  DISK_SIZE="40Gi"
  STORAGE_CLASS="ocs-storagecluster-ceph-rbd-virtualization"
  # ROOT_SC: same optional override as the RHEL branch (replica-1 scale pool).
  STORAGE_CLASS="${ROOT_SC:-$STORAGE_CLASS}"
  MANIFEST_VARIANT="default"
  public_key=""
fi

workflow_step "2/4 Validate pool name is unused"
workflow_success "Pool $POOL has $pool_vm_count VMs; creating $DENSITY_VM_COUNT from index $DENSITY_START_INDEX"

workflow_step "3/4 Launch kube-burner"
userdata="$(mktemp)"
trap 'rm -f "$userdata"' EXIT
jq -n \
  --arg JOB_NAME "density-$POOL" \
  --argjson DENSITY_VM_COUNT "$DENSITY_VM_COUNT" \
  --argjson DENSITY_QPS "$DENSITY_QPS" \
  --arg NAMESPACE "$NAMESPACE" \
  --arg OBJECT_TEMPLATE "$OBJECT_TEMPLATE" \
  --arg POOL_ID "$POOL" \
  --arg SSH_PUBLIC_KEY "$public_key" \
  --arg DISK_SIZE "$DISK_SIZE" \
  --arg STORAGE_CLASS "$STORAGE_CLASS" \
  --arg MANIFEST_VARIANT "$MANIFEST_VARIANT" \
  --arg DATA_SOURCE_NAME "${VM_DATA_SOURCE_NAME:-rhel9}" \
  --arg DATA_SOURCE_NAMESPACE "${VM_DATA_SOURCE_NAMESPACE:-openshift-virtualization-os-images}" \
  --arg OS_PROFILE "$VM_OS" \
  --arg INCREMENTAL_PASSES "$DENSITY_INCREMENTAL_PASSES" \
  --arg MANAGED_BY_KEY "$RUN_LABEL_MANAGED_BY_KEY" \
  --arg MANAGED_BY_VALUE "$RUN_LABEL_MANAGED_BY_VALUE" \
  --arg RUN_ID_KEY "$RUN_LABEL_RUN_ID_KEY" \
  --arg POOL_KEY "$RUN_LABEL_POOL_KEY" \
  --arg START_INDEX "$DENSITY_START_INDEX" \
  '{JOB_NAME: $JOB_NAME, DENSITY_VM_COUNT: $DENSITY_VM_COUNT,
    DENSITY_QPS: $DENSITY_QPS, NAMESPACE: $NAMESPACE,
    OBJECT_TEMPLATE: $OBJECT_TEMPLATE, POOL_ID: $POOL_ID,
    SSH_PUBLIC_KEY: $SSH_PUBLIC_KEY, DISK_SIZE: $DISK_SIZE,
    STORAGE_CLASS: $STORAGE_CLASS, MANIFEST_VARIANT: $MANIFEST_VARIANT,
    DATA_SOURCE_NAME: $DATA_SOURCE_NAME, DATA_SOURCE_NAMESPACE: $DATA_SOURCE_NAMESPACE,
    OS_PROFILE: $OS_PROFILE,
    INCREMENTAL_PASSES: $INCREMENTAL_PASSES,
    MANAGED_BY_KEY: $MANAGED_BY_KEY, MANAGED_BY_VALUE: $MANAGED_BY_VALUE,
    RUN_ID_KEY: $RUN_ID_KEY, POOL_KEY: $POOL_KEY, START_INDEX: $START_INDEX}' > "$userdata"
workflow_action "kube-burner init -c manifests/density/config.yaml (job density-$POOL, $DENSITY_VM_COUNT VM(s))"
if ! (
  kube-burner init -c "$ROOT_DIR/manifests/density/config.yaml" --user-data "$userdata"
); then
  printf 'kube-burner failed for pool %s; created objects (if any) remain for make density-status POOL=%s.\n' \
    "$POOL" "$POOL" >&2
  exit 1
fi

workflow_step "4/4 Wait for VM readiness"
density_wait_for_ready "$POOL" "$((DENSITY_START_INDEX + DENSITY_VM_COUNT))" "$DENSITY_WAIT_MINUTES"
workflow_success "Density pool $POOL is ready: $((DENSITY_START_INDEX + DENSITY_VM_COUNT)) VMs (added $DENSITY_VM_COUNT)"
