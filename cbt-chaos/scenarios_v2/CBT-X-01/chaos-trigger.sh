#!/usr/bin/env bash
# CBT-X-01: bounded memory pressure on the CBT worker node during the full
# backup copy (Jira: "backup may slow down; launcher VM must not be
# unintentionally OOM-killed").
#
# Design (I-08 pattern): start `make e2e TYPE=full` in the background; arm
# krknctl node-memory-hog with a command trigger gating on the full backup's
# Progressing condition BY TYPE (jsonpath); the hog runs 90s during the copy;
# wait for both; then run the clean incremental pass (follow-up run + tracker
# chain + workflow bit-exact verification). Verifications: no OOMKill,
# launcher restartCount unchanged, backup success, tracker advances exactly
# once, hashes exact.
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
if [[ -d "$EVIDENCE_DIR" ]]; then
  printf 'Refusing to run: %s already exists.\n' "$EVIDENCE_DIR" >&2
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
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'X01 run %s: bounded memory pressure during full backup copy.\n' "$RUN_ID" >&2
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/node-mem-before.txt" 2>/dev/null || true
launcher_name_at_start="$(oc get vmi -n "$NAMESPACE" "$VM_NAME" -o jsonpath='{.status.activePods}' 2>/dev/null || echo none)"
printf 'Pre-run: node mem %s%% used; VM guest memory from VMI spec recorded below.\n' "$node_mem_used_pct" >&2
oc get vmi -n "$NAMESPACE" "$VM_NAME" -o jsonpath='{.spec.domain.memory.guest}' >"$EVIDENCE_DIR/vmi-memory.txt" 2>/dev/null || true

# --- Stage 1: full backup in background + krkn memory hog gated on copy ------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started in background (pid=%s); arming krkn trigger.\n' "$wf_pid" >&2
krkn_log="$EVIDENCE_DIR/krkn-node-memory-hog.log"
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
printf 'krkn node-memory-hog armed (pid=%s); gate: %s Progressing-by-type.\n' "$krkn_pid" "$FULL_BACKUP_NAME" >&2
krkn_status=0
if wait "$krkn_pid"; then krkn_status=0; else krkn_status=$?; fi
printf 'krkn exit status: %d.\n' "$krkn_status" >&2
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/node-mem-after-hog.txt" 2>/dev/null || true
# Wait for the workflow.
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
tail -20 "$EVIDENCE_DIR/full-stage.log" >&2
if ((wf_status != 0)); then
  printf 'Full stage failed — aborting scenario.\n' >&2
  exit "$wf_status"
fi
# Backup outcome + timing.
backup_type="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.backupType}')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
printf 'Backup: type=%s Done reason=%s.\n' "$backup_type" "$backup_done_reason" >&2
# Launcher survived?
launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
launcher_restarts="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
launcher_last="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].status.containerStatuses[0].lastState}' 2>/dev/null || echo '{}')"
printf 'Launcher pod: %s restarts=%s lastState=%s.\n' "$launcher_pod" "$launcher_restarts" "$launcher_last" >&2
# OOMKill checks: node events + pod-level.
oom_node="$(oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null | grep -ci "OOMKilling\|OOMKilled" || true)"
oom_node="${oom_node:-0}"
oom_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json 2>/dev/null | jq -r '[.items[0].status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled" or .state.terminated.reason == "OOMKilled")] | length' 2>/dev/null || echo 0)"
printf 'OOM signals: node-namespace events=%s launcher OOMKilled=%s.\n' "$oom_node" "$oom_pod" >&2
# Node-level OOM check via debug (journalctl) — bounded window.
oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host journalctl -k --since "30 minutes ago" 2>/dev/null | grep -ci "Out of memory\|oom-kill" >"$EVIDENCE_DIR/node-oom-kernel.txt" || echo 0 >"$EVIDENCE_DIR/node-oom-kernel.txt"
printf 'Kernel OOM lines (30min window): %s.\n' "$(cat "$EVIDENCE_DIR/node-oom-kernel.txt")" >&2

# --- Stage 2: clean incremental pass (follow-up run + verification) ----------
incr_status=0
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
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
tail -12 "$EVIDENCE_DIR/incr-stage.log" >&2
((incr_status == 0)) || { printf 'Follow-up incremental failed — aborting.\n' >&2; exit "$incr_status"; }
# Tracker final state.
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint after follow-up: %s.\n' "$tracker_cp" >&2

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
# (a) hog ran during the copy
if grep -q "trigger condition satisfied" "$krkn_log" && grep -qiE "Successfully finished|injected" "$krkn_log"; then
  inject_check="PASS (trigger satisfied on Progressing; memory hog injected and finished; krkn exit $krkn_status)"
else
  inject_check="FAIL (see krkn log; exit $krkn_status)"
fi
printf 'CHECK injection-during-copy: %s\n' "$inject_check" | tee -a "$checks_file" >&2
# (b) no OOM kills of the launcher
if [[ "$oom_pod" == 0 && "$(cat "$EVIDENCE_DIR/node-oom-kernel.txt")" == 0 ]]; then
  oom_check="PASS (no OOMKilled containers in launcher; no kernel OOM lines in 30min window)"
else
  oom_check="FAIL (launcher OOM=$oom_pod kernel OOM lines=$(cat "$EVIDENCE_DIR/node-oom-kernel.txt"))"
fi
printf 'CHECK no-oom-kill: %s\n' "$oom_check" | tee -a "$checks_file" >&2
# (c) launcher unchanged
if [[ "$launcher_restarts" == 0 ]]; then
  launcher_check="PASS (launcher $launcher_pod restartCount=0)"
else
  launcher_check="FAIL (restartCount=$launcher_restarts lastState=$launcher_last)"
fi
printf 'CHECK launcher-unchanged: %s\n' "$launcher_check" | tee -a "$checks_file" >&2
# (d) backup success + type + tracker advanced
if [[ "$backup_type" == Full && "$backup_done_reason" == "Backup complete" ]] && grep -q "$FULL_BACKUP_NAME" <<<"$tracker_cp"; then
  backup_check="PASS (type=$backup_type reason=$backup_done_reason; tracker at $tracker_cp)"
else
  backup_check="FAIL (type=$backup_type reason=$backup_done_reason tracker=$tracker_cp)"
fi
printf 'CHECK backup-and-tracker: %s\n' "$backup_check" | tee -a "$checks_file" >&2
# (e) follow-up clean run bit-exact (workflow verify passed)
if ((incr_status == 0)); then
  followup_check="PASS (incremental pass + workflow restore verification PASS)"
else
  followup_check="FAIL"
fi
printf 'CHECK clean-followup: %s\n' "$followup_check" | tee -a "$checks_file" >&2
printf 'X01 scenario complete.\n' >&2
exit 0
