#!/usr/bin/env bash
# CBT-X-01 r01c: direct hog pod with writable WORKDIR.
#
# r01/r01b root cause (REPRODUCED in-cluster): the krkn-hub hog image's
# run.sh writes hog-jobfile.conf to its WORKDIR /stress-ng, which is NOT
# writable for the privileged pod as scheduled by krkn on OpenShift
# ("run.sh: line 41: hog-jobfile.conf: Read-only file system" → exit 1 in
# ~1s). krknctl exposes no way to mount a writable dir at WORKDIR, so the
# sanctioned direct-injection pattern (I-04/F-10/R-02 precedent) deploys the
# hog pod directly: same image + env (HOG_TYPE=memory, VM_BYTES=40%,
# WORKERS=4, DURATION=90) with an emptyDir mounted at /stress-ng.
# Gating stays on the backup's Progressing-by-type condition (poll loop).
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
HOG_POD="memory-hog-${RUN_ID}"
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
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01c-trigger.log") 2>&1
printf 'X01 r01c: direct memory-hog pod (writable WORKDIR), run %s.\n' "$RUN_ID" >&2
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/r01c-node-mem-before.txt" 2>/dev/null || true

# --- Hog pod spec (pre-rendered; applied at gate) ------------------------------
cat > "$EVIDENCE_DIR/r01c-hog-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $HOG_POD
  namespace: $HOG_NS
  labels:
    run: $HOG_POD
spec:
  nodeSelector:
    kubernetes.io/hostname: $CBT_NODE
  containers:
  - name: krkn-hog
    image: quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c", "cp -r /stress-ng/. /work/ && cd /work && bash run.sh"]
    env:
    - name: HOG_TYPE
      value: memory
    - name: VM_BYTES
      value: "40%"
    - name: WORKERS
      value: "4"
    - name: DURATION
      value: "90"
    securityContext:
      privileged: true
    volumeMounts:
    - name: workdir
      mountPath: /work
  volumes:
  - name: workdir
    emptyDir: {}
EOF
oc create namespace "$HOG_NS" >/dev/null
oc adm policy add-scc-to-user privileged -z default -n "$HOG_NS" >/dev/null 2>&1 || true

# --- Stage 1: full backup in background; apply hog at Progressing gate ---------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01c-full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s Progressing.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$prog" == True ]]; then
    gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    oc apply -f "$EVIDENCE_DIR/r01c-hog-pod.yaml" >/dev/null
    printf 'Progressing=True at %s — hog pod applied.\n' "$gate_hit_at" >&2
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
# Confirm hog started (Running + first log line).
hog_running_at=""
for ((attempt = 1; attempt <= 60; attempt++)); do
  hp="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$hp" == Running ]] && { hog_running_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; break; }
  sleep 1
done
printf 'Hog pod Running at %s.\n' "${hog_running_at:-never}" >&2
# Watch the hog to completion (its own log stream, retry-attach).
( for _ in $(seq 1 30); do
    oc logs -f "$HOG_POD" -n "$HOG_NS" 2>/dev/null && break
    sleep 2
  done ) >"$EVIDENCE_DIR/r01c-hog-pod.log" 2>&1 &
hoglog_pid=$!
# Memory telemetry while the hog runs.
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/r01c-node-mem-during.txt" 2>/dev/null || true
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
wait "$hoglog_pid" 2>/dev/null || true
sleep 2
kill "$hoglog_pid" 2>/dev/null || true
hog_phase_final="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
printf 'Hog pod final phase: %s.\n' "$hog_phase_final" >&2
printf -- '--- hog log tail ---\n' >&2
tail -6 "$EVIDENCE_DIR/r01c-hog-pod.log" >&2 || true
oc adm top node "$CBT_NODE" >"$EVIDENCE_DIR/r01c-node-mem-after.txt" 2>/dev/null || true
if ((wf_status != 0)); then
  printf 'Full stage failed — aborting.\n' >&2
  oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true
  exit "$wf_status"
fi
backup_type="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.backupType}')"
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
printf 'Backup: type=%s Done=%s reason=%s.\n' "$backup_type" "$backup_done_status" "$backup_done_reason" >&2
launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
launcher_restarts="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
printf 'Launcher pod: %s restarts=%s.\n' "$launcher_pod" "$launcher_restarts" >&2
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json >"$EVIDENCE_DIR/r01c-launcher-status.json" 2>/dev/null || true
oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host journalctl -k --since "30 minutes ago" 2>/dev/null | grep -ci "Out of memory\|oom-kill" >"$EVIDENCE_DIR/r01c-node-oom-kernel.txt" || echo 0 >"$EVIDENCE_DIR/r01c-node-oom-kernel.txt"
printf 'Kernel OOM lines (30min): %s.\n' "$(cat "$EVIDENCE_DIR/r01c-node-oom-kernel.txt")" >&2

# --- Stage 2: clean incremental pass ------------------------------------------
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01c-incr-stage.log" 2>&1; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
((incr_status == 0)) || { printf 'Follow-up incremental failed.\n' >&2; exit "$incr_status"; }
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2
oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/r01c-trigger-checks.txt"
: > "$checks_file"
if [[ -n "$gate_hit_at" && "$hog_phase_final" == Succeeded ]] && grep -q "successful run completed" "$EVIDENCE_DIR/r01c-hog-pod.log" 2>/dev/null; then
  inject_check="PASS (gate hit $gate_hit_at; hog pod Running ${hog_running_at}; stress-ng completed 90s; final phase $hog_phase_final)"
else
  inject_check="FAIL (gate=$gate_hit_at hog_phase=$hog_phase_final)"
fi
printf 'CHECK injection-during-copy: %s\n' "$inject_check" | tee -a "$checks_file" >&2
oom_pod="$(jq -r '[.items[0].status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled" or .state.terminated.reason == "OOMKilled")] | length' "$EVIDENCE_DIR/r01c-launcher-status.json" 2>/dev/null || echo 0)"
if [[ "$oom_pod" == 0 && "$(cat "$EVIDENCE_DIR/r01c-node-oom-kernel.txt")" == 0 ]]; then
  oom_check="PASS (no OOMKilled containers; no kernel OOM lines)"
else
  oom_check="FAIL (launcher OOM=$oom_pod kernel=$(cat "$EVIDENCE_DIR/r01c-node-oom-kernel.txt"))"
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
  backup_check="FAIL (type=$backup_type done=$backup_done_status tracker=$tracker_cp)"
fi
printf 'CHECK backup-and-tracker: %s\n' "$backup_check" | tee -a "$checks_file" >&2
if ((incr_status == 0)); then
  followup_check="PASS (incremental + workflow restore verification PASS)"
else
  followup_check="FAIL"
fi
printf 'CHECK clean-followup: %s\n' "$followup_check" | tee -a "$checks_file" >&2
printf 'X01 r01c complete.\n' >&2
exit 0
