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
    rhel9-light) POOL="rhl-$(date -u +%m%d%H%M%S)" ;;
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
  # Root is ODF (ceph-rbd-virtualization, unpinned), so adopted VMs must use
  # the ODF backup manifests; "default" selects the cbt-demo-hpp ones, whose
  # WaitForFirstConsumer claim cannot bind off d38-h18-000-r660.
  MANIFEST_VARIANT="large-odf"
  public_key=""
fi


# 2026-11-22 — same-namespace golden PVC: root disks are plain PVCs whose
# dataSource is a golden PVC copied into $NAMESPACE (see
# manifests/density/*.yaml). One-time copy through a CDI DataVolume whose
# sourceRef is the DataSource in $GOLDEN_NS (the same clone path vm-setup
# uses). This pays the CDI bridge cost exactly once; the 1000s of per-VM
# roots then clone in-namespace with a plain dataSource (no CDI, no expiring
# clone tokens, no tmp-pvc bridge churn through the single throttled CSI
# provisioner — the 2026-11-22 2000-VM wedge).
# 2026-11-24 — do NOT use a bare PVC with dataSourceRef kind=DataSource: CDI
# has no populator for that kind, so ceph-csi provisions a blank volume that
# Binds normally. Every VM cloned from it boots an all-zero disk (no sshd,
# no guest agent). Idempotent: reuse only a golden whose DataVolume
# Succeeded; a golden PVC without one is refused.
ensure_namespace_golden(){  # $1 = DataSource name in $GOLDEN_NS; $2 = optional same-namespace golden PVC name
  local src="$1" dst="${2:-golden-$VM_OS}" phase
  phase="$(oc_cmd get dv "$dst" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == Succeeded ]]; then
    workflow_success "golden DataVolume $NAMESPACE/$dst already Succeeded (reusing)"
    CLONE_SRC_PVC="$dst"
    return 0
  fi
  if [[ -z "$phase" ]] && oc_cmd get pvc "$dst" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf 'golden copy: PVC %s/%s exists without a DataVolume (likely a blank pre-2026-11-24 copy); delete it and rerun\n' "$NAMESPACE" "$dst" >&2
    return 1
  fi
  workflow_action "copy golden DataSource $GOLDEN_NS/$src -> $NAMESPACE/$dst (one-time CDI DataVolume clone)"
  local src_pvc src_size
  src_pvc="$(oc_cmd get datasource "$src" -n "$GOLDEN_NS" -o jsonpath='{.spec.source.pvc.name}')"
  src_size="$(oc_cmd get pvc "$src_pvc" -n "$GOLDEN_NS" -o jsonpath='{.spec.resources.requests.storage}')"
  cat <<EOF | oc_cmd apply -f - >/dev/null
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: $dst
  namespace: $NAMESPACE
  labels:
    virt-cbt-lab/golden: "true"
  annotations:
    cdi.kubevirt.io/storage.deleteAfterCompletion: "false"
spec:
  sourceRef:
    kind: DataSource
    name: $src
    namespace: $GOLDEN_NS
  storage:
    accessModes: [ReadWriteOnce]
    volumeMode: $( [[ "$VM_OS" == windows ]] && printf Block || printf Filesystem )
    storageClassName: $( [[ "$VM_OS" == windows ]] && printf ocs-storagecluster-ceph-rbd-virtualization || printf ocs-storagecluster-ceph-rbd )
    resources:
      requests:
        storage: $src_size
EOF
  local waited=0
  while :; do
    phase="$(oc_cmd get dv "$dst" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Succeeded ]] && break
    if [[ "$phase" == Failed ]] || (( waited >= 1800 )); then
      printf 'golden copy: DataVolume %s/%s not Succeeded (phase=%s, waited %ss)\n' "$NAMESPACE" "$dst" "${phase:-none}" "$waited" >&2
      return 1
    fi
    sleep 10; waited=$((waited + 10))
  done
  workflow_success "golden DataVolume $NAMESPACE/$dst Succeeded"
  CLONE_SRC_PVC="$dst"
}

GOLDEN_NS="${GOLDEN_NS:-vm-cbt-images}"
CLONE_SRC_PVC=""
case "$VM_OS" in
  rhel9)        GOLDEN_NS=openshift-virtualization-os-images ensure_namespace_golden "${VM_DATA_SOURCE_NAME:-rhel9}" ;;
  rhel9-light)  ensure_namespace_golden "${RHEL_LIGHT_DATA_SOURCE_NAME:-rhel9-light}" "golden-${RHEL_LIGHT_DATA_SOURCE_NAME:-rhel9-light}" ;;
  windows)      ensure_namespace_golden "windows-server-2022" ;;
esac
[[ -n "$CLONE_SRC_PVC" ]] || { printf 'golden copy failed for VM_OS=%s\n' "$VM_OS" >&2; exit 1; }

# Root disk size must be >= the golden PVC's actual capacity (CSI clone
# floor: "new PVC request must be greater than or equal in size to the
# specified PVC data source"). The golden may provision slightly larger
# than its spec request (11Gi actual for a 10Gi request), so always use
# the golden's real capacity.
DISK_SIZE="$(oc_cmd get pvc "$CLONE_SRC_PVC" -n "$NAMESPACE" -o jsonpath='{.status.capacity.storage}')"
workflow_success "root disk size set to golden capacity: $DISK_SIZE"

workflow_step "2/4 Validate pool name is unused"
workflow_success "Pool $POOL has $pool_vm_count VMs; creating $DENSITY_VM_COUNT from index $DENSITY_START_INDEX"

workflow_step "3/4 Launch kube-burner (batched)"
# 2026-11-23 — PVC batch gate: the csi-provisioner sidecar self-throttles at
# kube-api-qps=5 (client-go default; not exposed by the ceph-csi-operator
# Driver CR). One N=1000 PVC flood puts ~100 CreateVolume calls in flight;
# each needs several API calls, so per-clone setup takes minutes, exceeds the
# grpc timeout, and retries amplify the storm (DeadlineExceeded loops, leader
# appears wedged — observed 2026-11-22 on the 2000-VM build). Creating VMs in
# batches of DENSITY_PVC_BATCH (default 100) and waiting for each batch's
# root PVCs to bind keeps concurrent clones low; clones then complete in
# seconds (proven: 2-VM smoke test bound instantly; wave-redrive at 50/batch
# drained 1280 stuck roots in ~25 min once concurrency dropped).
DENSITY_PVC_BATCH="${DENSITY_PVC_BATCH:-100}"
if (( DENSITY_VM_COUNT > DENSITY_PVC_BATCH )); then
  workflow_success "creating in batches of $DENSITY_PVC_BATCH (PVC-bind gated)"
  local_done=0
  while (( local_done < DENSITY_VM_COUNT )); do
    batch=$(( DENSITY_VM_COUNT - local_done )); (( batch > DENSITY_PVC_BATCH )) && batch=$DENSITY_PVC_BATCH
    batch_start=$(( DENSITY_START_INDEX + local_done + 1 ))   # 1-based for message
    batch_index=$(( DENSITY_START_INDEX + local_done ))       # 0-based index for VM numbering
    workflow_action "batch: VMs $batch_start..$(( batch_index + batch )) ($batch VMs)"
    userdata="$(mktemp)"
    jq -n \
      --arg JOB_NAME "density-$POOL-b$local_done" \
      --argjson DENSITY_VM_COUNT "$batch" \
      --argjson DENSITY_QPS "$DENSITY_QPS" \
      --arg NAMESPACE "$NAMESPACE" \
      --arg OBJECT_TEMPLATE "$OBJECT_TEMPLATE" \
      --arg POOL_ID "$POOL" \
      --arg SSH_PUBLIC_KEY "$public_key" \
      --arg DISK_SIZE "$DISK_SIZE" \
      --arg STORAGE_CLASS "$STORAGE_CLASS" \
      --arg MANIFEST_VARIANT "$MANIFEST_VARIANT" \
      --arg CLONE_SRC_PVC "$CLONE_SRC_PVC" \
      --arg OS_PROFILE "$VM_OS" \
      --arg INCREMENTAL_PASSES "$DENSITY_INCREMENTAL_PASSES" \
      --arg MANAGED_BY_KEY "$RUN_LABEL_MANAGED_BY_KEY" \
      --arg MANAGED_BY_VALUE "$RUN_LABEL_MANAGED_BY_VALUE" \
      --arg RUN_ID_KEY "$RUN_LABEL_RUN_ID_KEY" \
      --arg POOL_KEY "$RUN_LABEL_POOL_KEY" \
      --arg START_INDEX "$batch_index" \
      '{JOB_NAME: $JOB_NAME, DENSITY_VM_COUNT: $DENSITY_VM_COUNT,
        DENSITY_QPS: $DENSITY_QPS, NAMESPACE: $NAMESPACE,
        OBJECT_TEMPLATE: $OBJECT_TEMPLATE, POOL_ID: $POOL_ID,
        SSH_PUBLIC_KEY: $SSH_PUBLIC_KEY, DISK_SIZE: $DISK_SIZE,
        STORAGE_CLASS: $STORAGE_CLASS, MANIFEST_VARIANT: $MANIFEST_VARIANT,
        CLONE_SRC_PVC: $CLONE_SRC_PVC,
        OS_PROFILE: $OS_PROFILE,
        INCREMENTAL_PASSES: $INCREMENTAL_PASSES,
        MANAGED_BY_KEY: $MANAGED_BY_KEY, MANAGED_BY_VALUE: $MANAGED_BY_VALUE,
        RUN_ID_KEY: $RUN_ID_KEY, POOL_KEY: $POOL_KEY, START_INDEX: $START_INDEX}' > "$userdata"
    if ! kube-burner init -c "$ROOT_DIR/manifests/density/config.yaml" --user-data "$userdata"; then
      rm -f "$userdata"
      printf 'kube-burner failed for pool %s batch at index %s; created objects remain.\n' \
        "$POOL" "$batch_index" >&2
      exit 1
    fi
    rm -f "$userdata"
    # gate: wait for this batch's root PVCs to bind before the next batch
    batch_unbound=1
    batch_wait=0
    while (( batch_unbound > 0 )); do
      batch_unbound=0
      for i in $(seq 1 $batch); do
        n=$(printf "%04d" $(( batch_index + i )))
        ph="$(oc_cmd get pvc "vm-disk-$POOL-$n" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$ph" != "Bound" ]] && batch_unbound=$((batch_unbound + 1))
      done
      if (( batch_unbound > 0 )); then
        sleep 30; batch_wait=$((batch_wait + 30))
        if (( batch_wait >= 1200 )); then
          printf 'batch at index %s: %s PVC(s) not Bound after 20m; continuing (repair loop will re-drive)\n' \
            "$batch_index" "$batch_unbound" >&2
          break
        fi
      fi
    done
    workflow_success "batch bound (waited ${batch_wait}s)"
    local_done=$(( local_done + batch ))
  done
else
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
    --arg CLONE_SRC_PVC "$CLONE_SRC_PVC" \
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
      CLONE_SRC_PVC: $CLONE_SRC_PVC,
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
fi

workflow_step "4/4 Wait for VM readiness"
density_wait_for_ready "$POOL" "$((DENSITY_START_INDEX + DENSITY_VM_COUNT))" "$DENSITY_WAIT_MINUTES"
workflow_success "Density pool $POOL is ready: $((DENSITY_START_INDEX + DENSITY_VM_COUNT)) VMs (added $DENSITY_VM_COUNT)"
