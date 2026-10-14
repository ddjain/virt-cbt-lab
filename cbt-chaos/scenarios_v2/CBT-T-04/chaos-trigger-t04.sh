#!/usr/bin/env bash
# CBT-T-04 threshold-hunt trigger: storage-capacity floor.
#
# Usage:
#   RUN_ID=<id> TARGET_FREE_GIB={100|60|40} bash chaos-trigger-t04.sh
#
# Pre-fills the HPP pool (/var/hpvolumes/csi on /dev/sdb) so the backup cycle
# starts with TARGET_FREE_GIB free, then runs the full backup (and incremental
# if it survives). Records whether the boundary is PVC admission or copy-time
# ENOSPC, and the free-space floor for a successful cycle.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
: "${TARGET_FREE_GIB:?Set TARGET_FREE_GIB (e.g. 100)}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
CBT_NODE="d38-h18-000-r660"
FILL_NS="cbt-t04-fill"
FILLER_POD="pool-filler-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-T-04/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
  exit 2
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Refusing to run: resources for %s already exist.\n' "$RUN_ID" >&2
  exit 2
fi
node_ready="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
if [[ "$node_ready" != True ]]; then
  printf 'Node %s not Ready (%s) — aborting.\n' "$CBT_NODE" "$node_ready" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'T04 leg %s: pre-fill pool to leave %s GiB free.\n' "$RUN_ID" "$TARGET_FREE_GIB" >&2

# --- Measure current free space (via a short debug pod, authoritative df) -----
raw_free_kib="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$raw_free_kib" ]]; then
  printf 'Cannot read pool free space — aborting.\n' >&2
  exit 2
fi
current_free_gib=$((raw_free_kib / 1024 / 1024))
printf 'Current pool free: %s GiB; target: %s GiB.\n' "$current_free_gib" "$TARGET_FREE_GIB" >&2
if ((current_free_gib <= TARGET_FREE_GIB)); then
  printf 'Already at/below target free space (%s <= %s) — no fill needed.\n' "$current_free_gib" "$TARGET_FREE_GIB" >&2
  fill_gib=0
else
  fill_gib=$((current_free_gib - TARGET_FREE_GIB))
fi
printf '%s GiB current, %s GiB target, %s GiB to fill.\n' "$current_free_gib" "$TARGET_FREE_GIB" "$fill_gib" >"$EVIDENCE_DIR/pool-math.txt"

# --- Filler pod ----------------------------------------------------------------
if ((fill_gib > 0)); then
  oc get namespace "$FILL_NS" >/dev/null 2>&1 || oc create namespace "$FILL_NS" >/dev/null
  cat > "$EVIDENCE_DIR/filler-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $FILLER_POD
  namespace: $FILL_NS
spec:
  nodeSelector:
    kubernetes.io/hostname: $CBT_NODE
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: filler
    image: registry.access.redhat.com/ubi9/ubi:latest
    command: ["/bin/bash", "-c", "df -B1G /fill | tail -1; fallocate -l ${fill_gib}G /fill/.t04-filler && echo FILL_DONE; df -B1G /fill | tail -1; sleep 3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: fill
      mountPath: /fill
  volumes:
  - name: fill
    hostPath:
      path: /var/hpvolumes/csi
      type: Directory
EOF
  oc apply -f "$EVIDENCE_DIR/filler-pod.yaml" >/dev/null
  fill_ok=""
  for ((attempt = 1; attempt <= 120; attempt++)); do
    if oc logs "$FILLER_POD" -n "$FILL_NS" 2>/dev/null | grep -q FILL_DONE; then
      fill_ok=yes
      break
    fi
    phase="$(oc get pod "$FILLER_POD" -n "$FILL_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    [[ "$phase" == Failed ]] && break
    sleep 5
  done
  oc logs "$FILLER_POD" -n "$FILL_NS" >"$EVIDENCE_DIR/filler-pod.log" 2>/dev/null || true
  if [[ "$fill_ok" != yes ]]; then
    printf 'Filler did not complete (phase=%s) — aborting leg.\n' "${phase:-?}" >&2
    tail -5 "$EVIDENCE_DIR/filler-pod.log" >&2 || true
    exit 2
  fi
  printf 'Fill complete; filler log: %s\n' "$(grep FILL_DONE "$EVIDENCE_DIR/filler-pod.log")" >&2
fi
# Authoritative post-fill free space.
post_free_kib="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
post_free_gib=$((post_free_kib / 1024 / 1024))
printf 'Post-fill free: %s GiB.\n' "$post_free_gib" >&2
printf 'post_fill_free_gib=%s target=%s\n' "$post_free_gib" "$TARGET_FREE_GIB" >>"$EVIDENCE_DIR/pool-math.txt"

# --- Full backup cycle ----------------------------------------------------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s).\n' "$wf_pid" >&2
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
printf 'Backup: Done=%s reason=%s.\n' "$backup_done_status" "$backup_done_reason" >&2
# Failure-mode classification: PVC admission vs copy-time ENOSPC.
pvc_phase="$(oc get pvc -n "$NAMESPACE" "vm-backup-pvc-${RUN_ID}" -o jsonpath='{.status.phase}' 2>/dev/null || echo absent)"
grep -iE "no space|ENOSPC|exceed|quota|capacity" "$EVIDENCE_DIR/full-stage.log" >"$EVIDENCE_DIR/full-stage-space-errors.txt" 2>/dev/null || true
vmi_paused="$(oc get vmi -n "$NAMESPACE" "$VM_NAME" -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || echo '')"
printf 'backup PVC phase: %s; VMI Paused condition: %s.\n' "$pvc_phase" "${vmi_paused:-none}" >&2

# --- Follow-up incremental if full succeeded -----------------------------------
incr_status=""
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* ]]; then
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH" \
    >"$EVIDENCE_DIR/incr-stage.log" 2>&1; then
    incr_status=0
  else
    incr_status=$?
  fi
  printf 'Incremental stage exit status: %s.\n' "$incr_status" >&2
fi
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2
final_free_kib="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
printf 'Free space after cycle: %s GiB.\n' "$((final_free_kib / 1024 / 1024))" >&2

# --- Cleanup filler (space reclaimed) ------------------------------------------
if ((fill_gib > 0)); then
  oc delete pod "$FILLER_POD" -n "$FILL_NS" --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
  printf 'Filler deleted; space reclaimed.\n' >&2
fi

# --- Verdict --------------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* && ( -z "$incr_status" || "$incr_status" == 0 ) ]]; then
  verdict="SUCCEEDS (full Done=True success; incr rc=${incr_status:-skipped}) at ${post_free_gib} GiB free"
elif [[ "$pvc_phase" != Bound ]]; then
  verdict="FAILED-AT-ADMISSION (backup PVC phase=$pvc_phase — pool could not admit PVC)"
elif [[ "$backup_done_status" == True ]]; then
  verdict="FAILED-COPY-TIME (Done reason: $backup_done_reason; VMI Paused=${vmi_paused:-none})"
else
  verdict="HARNESS-ANOMALY (done=$backup_done_status pvc=$pvc_phase — inspect)"
fi
printf 'CHECK leg-verdict: %s\n' "$verdict" | tee -a "$checks_file" >&2
printf 'CHECK free-space: start=%sGiB post_fill=%sGiB end=%sGiB target=%sGiB\n' \
  "$current_free_gib" "$post_free_gib" "$((final_free_kib / 1024 / 1024))" "$TARGET_FREE_GIB" | tee -a "$checks_file" >&2
printf 'CHECK space-errors: %s\n' "$(head -3 "$EVIDENCE_DIR/full-stage-space-errors.txt" 2>/dev/null | tr '\n' ';' | cut -c1-200)" | tee -a "$checks_file" >&2
printf 'CHECK tracker: %s\n' "$tracker_cp" | tee -a "$checks_file" >&2
printf 'T04 leg complete.\n' >&2
exit 0
