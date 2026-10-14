#!/usr/bin/env bash
# CBT-X-01 r01b: re-run with the hog namespace pre-created.
# r01 analysis: the trigger gate worked (satisfied 15:45:22.958Z mid-copy),
# but krkn node-memory-hog does NOT create its target namespace — pod
# creation 404'd against the nonexistent x01-hog-<RID> namespace. Everything
# else in r01 was clean (backup 54s success, launcher restartCount=0, no OOM,
# follow-up incremental + verify PASS) — but no memory pressure was ever
# applied, so the injection is invalid. r01b re-runs the gated leg with the
# namespace pre-created, reusing r01's completed full backup is NOT possible
# (the gate would never fire on a Done backup), so the full stage re-runs.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
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
HOG_NS="x01-hog-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-X-01/runs/$RUN_ID"
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
node_mem_used_pct="$(oc adm top node "$CBT_NODE" --no-headers 2>/dev/null | awk '{gsub("%","",$5); print $5}')"
if [[ -z "$node_mem_used_pct" ]] || ((node_mem_used_pct > 20)); then
  printf 'Node memory usage %s%% above 20%% guard — aborting.\n' "${node_mem_used_pct:-?}" >&2
  exit 2
fi
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k /var/hpvolumes 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01b-trigger.log") 2>&1
printf 'X01 r01b: memory hog with pre-created namespace, run %s.\n' "$RUN_ID" >&2
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/r01b-node-mem-before.txt" 2>/dev/null || true

# --- Pre-create the hog namespace (the r01 fix) -------------------------------
oc create namespace "$HOG_NS" >/dev/null
printf 'Hog namespace %s pre-created.\n' "$HOG_NS" >&2

# --- Stage 1: full backup in background + krkn memory hog gated on copy ------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01b-full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started in background (pid=%s).\n' "$wf_pid" >&2
krkn_log="$EVIDENCE_DIR/r01b-krkn-node-memory-hog.log"
gate_cmd="oc get vmbackup $FULL_BACKUP_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}' | grep -q True"
krknctl run node-memory-hog \
  --chaos-duration 90 \
  --memory-consumption "40%" \
  --memory-workers 4 \
  --node-selector "kubernetes.io/hostname=$CBT_NODE" \
  --namespace "$HOG_NS" \
  --trigger-command "$gate_cmd" \
  --triggers-interval 2 \
  --triggers-timeout 900 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krkn_log" 2>&1 &
krkn_pid=$!
printf 'krkn armed (pid=%s); gate: %s Progressing-by-type.\n' "$krkn_pid" "$FULL_BACKUP_NAME" >&2
krkn_status=0
if wait "$krkn_pid"; then krkn_status=0; else krkn_status=$?; fi
printf 'krkn exit status: %d.\n' "$krkn_status" >&2
# Hog evidence: pod in HOG_NS + node memory during/after.
oc get pods -n "$HOG_NS" -o wide >"$EVIDENCE_DIR/r01b-hog-pods.txt" 2>/dev/null || true
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/r01b-node-mem-after-hog.txt" 2>/dev/null || true
oc logs -n "$HOG_NS" "$(oc get pods -n "$HOG_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" >"$EVIDENCE_DIR/r01b-hog-pod.log" 2>&1 || true
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
grep -E "Backup completed|✓|✗|RESULT" "$EVIDENCE_DIR/r01b-full-stage.log" | tail -8 >&2
if ((wf_status != 0)); then
  printf 'Full stage failed — aborting.\n' >&2
  oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true
  exit "$wf_status"
fi
backup_type="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.backupType}')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
printf 'Backup: type=%s Done=%s reason=%s.\n' "$backup_type" "$backup_done_status" "$backup_done_reason" >&2
launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
launcher_restarts="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
printf 'Launcher pod: %s restarts=%s.\n' "$launcher_pod" "$launcher_restarts" >&2
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json >"$EVIDENCE_DIR/r01b-launcher-status.json" 2>/dev/null || true
oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host journalctl -k --since "30 minutes ago" 2>/dev/null | grep -ci "Out of memory\|oom-kill" >"$EVIDENCE_DIR/r01b-node-oom-kernel.txt" || echo 0 >"$EVIDENCE_DIR/r01b-node-oom-kernel.txt"
printf 'Kernel OOM lines (30min): %s.\n' "$(cat "$EVIDENCE_DIR/r01b-node-oom-kernel.txt")" >&2

# --- Stage 2: clean incremental pass ------------------------------------------
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01b-incr-stage.log" 2>&1; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
((incr_status == 0)) || { printf 'Follow-up incremental failed.\n' >&2; exit "$incr_status"; }
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2
# Cleanup hog namespace.
oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/r01b-trigger-checks.txt"
: > "$checks_file"
if grep -q "trigger condition satisfied" "$krkn_log" && grep -q "Successfully finished running Kraken" "$krkn_log"; then
  inject_check="PASS (gate satisfied mid-copy; hog pod ran; krkn exit $krkn_status; pod evidence in r01b-hog-pods.txt)"
else
  inject_check="FAIL (krkn exit $krkn_status — see r01b-krkn-node-memory-hog.log)"
fi
printf 'CHECK injection-during-copy: %s\n' "$inject_check" | tee -a "$checks_file" >&2
oom_pod="$(jq -r '[.items[0].status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled" or .state.terminated.reason == "OOMKilled")] | length' "$EVIDENCE_DIR/r01b-launcher-status.json" 2>/dev/null || echo 0)"
if [[ "$oom_pod" == 0 && "$(cat "$EVIDENCE_DIR/r01b-node-oom-kernel.txt")" == 0 ]]; then
  oom_check="PASS (no OOMKilled containers; no kernel OOM lines)"
else
  oom_check="FAIL (launcher OOM=$oom_pod kernel=$(cat "$EVIDENCE_DIR/r01b-node-oom-kernel.txt"))"
fi
printf 'CHECK no-oom-kill: %s\n' "$oom_check" | tee -a "$checks_file" >&2
if [[ "$launcher_restarts" == 0 ]]; then
  launcher_check="PASS (launcher $launcher_pod restartCount=0)"
else
  launcher_check="FAIL (restartCount=$launcher_restarts)"
fi
printf 'CHECK launcher-unchanged: %s\n' "$launcher_check" | tee -a "$checks_file" >&2
if [[ "$backup_done_status" == True && "$backup_type" == Full ]] && [[ "$tracker_cp" == *"$RUN_ID"* ]]; then
  backup_check="PASS (type=$backup_type Done=True; tracker at $tracker_cp)"
else
  backup_check="FAIL (type=$backup_type done=$backup_done_reason tracker=$tracker_cp)"
fi
printf 'CHECK backup-and-tracker: %s\n' "$backup_check" | tee -a "$checks_file" >&2
printf 'CHECK clean-followup: %s\n' "$((incr_status == 0)) && echo PASS || echo FAIL" | tee -a "$checks_file" >&2
printf 'X01 r01b complete.\n' >&2
exit 0
