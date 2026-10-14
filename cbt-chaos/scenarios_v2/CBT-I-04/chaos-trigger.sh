#!/usr/bin/env bash
# CBT-I-04 (variant 2, r03): DIRECT synchronous-write I/O hog on the HostPath
# CBT storage pool disk during the ACTIVE INCREMENTAL COPY.
# r02 (krknctl node-io-hog) had a VALID injection but NO observable slowdown
# (p01 = 18s, inside the 16-21s baseline): source-verified root cause — the
# krkn hog image's io path (run.sh -> io-hog.conf.template) uses stress-ng's
# default hdd options (buffered writes, no sync), and krknctl exposes no flag
# to change them (verified: krknctl run node-io-hog --help; krkn_lib
# hog_pod.j2 only plumbs block-size/write-bytes/workers/duration). Buffered
# 1m writes are page-cache absorbed and never contend the disk queue.
# Variant 2 replaces the hog pod only: same node, same path, same 3s gated
# active-copy condition, but stress-ng --hdd-opts dsync (O_DSYNC per-write
# synchronous writes) via a direct, narrowly scoped kubectl pod
# (F-10 sanctioned fallback pattern). Expected per the Jira: the incremental
# takes longer than the ~15-20s baseline but still completes as an Incremental
# with correct changed data.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID for this full+incremental lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not a valid workflow run ID: %s\n' "$RUN_ID" >&2
  exit 2
fi
for command in oc jq make tee kubectl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
# Force-set (not :-): the execution host's .env pre-exports VM_OS=rhel9 and
# MANIFEST_VARIANT=large-odf (Ceph RBD). The RBD data path leaves the VM's
# node entirely, so node-local I/O contention cannot exercise it; the Jira's
# "CBT storage filesystem on the worker node" is the HostPath pool disk.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
HOG_NODE="d38-h18-000-r660"
HOG_NAMESPACE="hog-ns-${RUN_ID}"
HOG_MOUNT_PATH="/mnt/local-storage/cbt-demo-local-pool"
HOG_DURATION=60        # per the Jira issue (chaos duration: 60 seconds)
HOG_WORKERS=8          # parallel stress-ng hdd writers (r02 calibration)
HOG_WRITE_BYTES=2g     # per worker; 8 x 2g = 16g of ~1.4t free
HOG_BLOCK_SIZE=1m
HOG_OPTS="dsync"       # variant 2: O_DSYNC synchronous writes (the point)
HOG_POD_NAME="io-hog-${RUN_ID}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-04/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
if oc get namespace "$HOG_NAMESPACE" >/dev/null 2>&1; then
  printf 'Hog namespace %s already exists; refusing to reuse it.\n' "$HOG_NAMESPACE" >&2
  exit 1
fi
# Pre-run topology guards: the pool backing pod must be Running on HOG_NODE.
pool_pod="$(oc get pods -n openshift-cnv -o name | grep -E '^pod/hpp-pool-cbt-demo-pool-')"
if [[ -z "$pool_pod" ]]; then
  printf 'Expected a Running hpp-pool-cbt-demo-pool pod in openshift-cnv; found none. Refusing to proceed.\n' >&2
  exit 1
fi
pool_pod_node="$(oc get pod "${pool_pod#pod/}" -n openshift-cnv -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
if [[ -z "$pool_pod_node" ]]; then
  printf 'Could not resolve the HostPath pool pod node; refusing to proceed.\n' >&2
  exit 1
fi
if [[ "$pool_pod_node" != "$HOG_NODE" ]]; then
  printf 'HostPath pool pod runs on %s, expected %s; refusing to proceed.\n' "$pool_pod_node" "$HOG_NODE" >&2
  exit 1
fi
# Capacity guard: the cbt-demo-hpp pool is a single node-local disk
# (observed /dev/sdb 1.5T backing /var/hpvolumes/csi). A run needs roughly
# 120+ GiB of ACTUAL pool space (thin-provisioned PVCs consume real bytes
# as data lands: ~31G root disk, ~17G full backup, ~35G mutation inside the
# root disk, ~35G incremental copy, 16g hog writes) — r01 hit ENOSPC when
# closed-run evidence PVCs had filled the disk to 100% and the VM paused on
# IOerror mid-mutation. Fail closed below a 400 GiB free floor.
pool_free_kib="$(oc debug node/"$HOG_NODE" -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | tail -1 | awk '{print $4}')"
if ! [[ "$pool_free_kib" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Could not read pool filesystem free space on %s; refusing to proceed.\n' "$HOG_NODE" >&2
  exit 1
fi
if (( pool_free_kib < 400 * 1024 * 1024 )); then
  free_gib=$(( pool_free_kib / 1024 / 1024 ))
  printf 'Pool filesystem on %s has only %s GiB free (< 400 GiB floor); the run would hit ENOSPC. Delete closed-run evidence PVCs first (r01 lesson).\n' "$HOG_NODE" "$free_gib" >&2
  exit 1
fi
printf 'Pool filesystem on %s has %s GiB free (floor 400 GiB).\n' "$HOG_NODE" "$(( pool_free_kib / 1024 / 1024 ))" >&2
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
kubectl create namespace "$HOG_NAMESPACE"
hog_ns_created=true
cleanup_hog_ns() {
  if [[ "${hog_ns_created:-}" == true ]]; then
    kubectl delete namespace "$HOG_NAMESPACE" --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup_hog_ns EXIT INT TERM
# Active-copy watcher on the INCREMENTAL backup: p01 exists, Progressing=True,
# Done not yet True (r02-validated condition). Single-quoted JSONPath inside
# the command substitution (harness learning 2026-10-13). When the window
# opens, create the direct dsync hog pod on the pool path.
watch_and_inject() {
  local deadline=$((SECONDS + TRIGGERS_TIMEOUT)) backup_json
  while ((SECONDS < deadline)); do
    if test "$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)" = True \
       && test "$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True; then
      # Re-read to confirm the window is still open at the boundary.
      backup_json="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
        -o json --ignore-not-found 2>/dev/null || true)"
      if [[ -n "$backup_json" ]] && jq -e '
        all((.status.conditions // [])[]?; .type != "Done" or .status != "True")
      ' <<<"$backup_json" >/dev/null; then
        printf 'Active-copy signal observed; creating dsync I/O hog pod on %s (%s workers, %s bytes/worker, %s-block, opts=%s, %ss).\n' \
          "$HOG_NODE" "$HOG_WORKERS" "$HOG_WRITE_BYTES" "$HOG_BLOCK_SIZE" "$HOG_OPTS" "$HOG_DURATION" >&2
        kubectl run "$HOG_POD_NAME" \
          --namespace "$HOG_NAMESPACE" \
          --restart=Never \
          --image="quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog" \
          --overrides "{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${HOG_NODE}\"},\"containers\":[{\"name\":\"krkn-hog\",\"image\":\"quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog\",\"command\":[\"sh\",\"-c\",\"cd /hog-data && stress-ng --hdd ${HOG_WORKERS} --hdd-bytes ${HOG_WRITE_BYTES} --hdd-write-size ${HOG_BLOCK_SIZE} --hdd-opts ${HOG_OPTS} --timeout ${HOG_DURATION}\"],\"securityContext\":{\"privileged\":true},\"volumeMounts\":[{\"name\":\"node-volume\",\"mountPath\":\"/hog-data\"}]}],\"volumes\":[{\"name\":\"node-volume\",\"hostPath\":{\"path\":\"${HOG_MOUNT_PATH}\"}}]}}" \
          >/dev/null
        injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s\n' "$injection_requested_utc" >"$EVIDENCE_DIR/injection-requested-utc.txt"
        printf 'UTC action request: create %s on node %s at %s (p01 Progressing=True Done!=True).\n' \
          "$HOG_POD_NAME" "$HOG_NODE" "$injection_requested_utc" >&2
        return 0
      fi
    fi
    sleep 3
  done
  printf 'Timed out waiting for the active-copy window.\n' >&2
  return 1
}
watch_and_inject &
watcher_pid=$!
printf 'dsync I/O hog watcher started (pid=%s): node=%s path=%s workers=%s opts=%s duration=%ss.\n' \
  "$watcher_pid" "$HOG_NODE" "$HOG_MOUNT_PATH" "$HOG_WORKERS" "$HOG_OPTS" "$HOG_DURATION" >&2
# --- Stage 1: full backup (no contention; baseline for the chain) ----------
if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  full_status=0
else
  full_status=$?
fi
if ((full_status != 0)); then
  printf 'Full stage failed (%d); aborting before the incremental contention.\n' "$full_status" >&2
  wait "$watcher_pid" || true
  exit "$full_status"
fi
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
printf 'Full stage complete (checkpoint: %s). Starting incremental under dsync hog trigger.\n' "$full_checkpoint" >&2
# --- Stage 2: incremental pass under synchronous storage contention -------
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
# Placement guard: the VM must have run on the hog node.
vmi_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
printf 'VM %s ran on node %s (hog node %s).\n' "$VM_NAME" "${vmi_node:-unavailable}" "$HOG_NODE" >&2
if [[ "$vmi_node" != "$HOG_NODE" ]]; then
  printf 'PLACEMENT MISMATCH: VM node %s != hog node %s; run is harness-invalid.\n' \
    "$vmi_node" "$HOG_NODE" >&2
  exit 3
fi
if wait "$watcher_pid"; then
  injection_status=0
else
  injection_status=$?
fi
printf 'Incremental exit status: %d; injection watcher status: %d\n' \
  "$incr_status" "$injection_status" >&2
# Wait out the hog's own duration so the pod reaches a terminal state
# before evidence capture (stress-ng exits at the timeout).
hog_deadline=$((SECONDS + HOG_DURATION + 90))
while ((SECONDS < hog_deadline)); do
  hog_phase="$(kubectl get pod "$HOG_POD_NAME" -n "$HOG_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$hog_phase" == Succeeded || "$hog_phase" == Failed ]]; then
    break
  fi
  sleep 5
done
# Preserve hog-pod evidence BEFORE namespace cleanup (r02 lesson: the pod is
# deleted with the namespace; capture yaml+logs while it still exists).
kubectl get pod "$HOG_POD_NAME" -n "$HOG_NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/hog-pod.yaml" 2>/dev/null || true
kubectl logs "$HOG_POD_NAME" -n "$HOG_NAMESPACE" \
  >"$EVIDENCE_DIR/hog-pod.log" 2>/dev/null || true
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/incremental-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml \
  >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true
incr_type="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.type}' 2>/dev/null || true)"
incr_checkpoint="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
incr_duration="$(jq -r '.backups.incremental_passes[0].duration_seconds // empty' \
  "$ROOT_DIR/runs/$RUN_ID/run.json" 2>/dev/null || true)"
full_duration="$(jq -r '.backups.full.duration_seconds // empty' \
  "$ROOT_DIR/runs/$RUN_ID/run.json" 2>/dev/null || true)"
printf 'INCREMENTAL RESULT: type=%s checkpoint=%s duration=%ss (full control: %ss; no-contention baseline 16-21s).\n' \
  "${incr_type:-unknown}" "${incr_checkpoint:-unknown}" \
  "${incr_duration:-unknown}" "${full_duration:-unknown}" >&2
if ((injection_status != 0)); then
  printf 'Injection watcher never fired; run is harness-invalid.\n' >&2
  exit "$injection_status"
fi
if ((incr_status != 0)); then
  exit "$incr_status"
fi
printf 'Scenario complete: incremental executed under synchronous (dsync) storage contention; type, duration, and data verified above.\n' >&2
exit 0
