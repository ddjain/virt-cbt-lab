#!/usr/bin/env bash
# CBT-T-01/02/03 threshold-hunt trigger (shared skeleton).
#
# Usage:
#   RUN_ID=<id> HOG_TYPE={cpu|memory|io} [CPU_WORKERS=32] [CPU_LOAD=100]
#   [MEM_BYTES=50%] [IO_WORKERS=8] bash chaos-trigger-th.sh
#
# Single-variable sweep leg: full backup in background, hog applied at the
# Progressing-by-type gate, telemetry during, verdict after. Exit 0 always
# (outcome recorded in checks file) EXCEPT on harness errors (exit 2).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
# Backend note: the HPP storage node outage (2026-10-13 17:22→18:50Z, X-03
# krkn rule leak) was recovered surgically (IPv6 SSH + iptables-legacy flush);
# sweeps run on the intended HPP/default backend on d38-h18-000-r660. The
# hog targets the VM's node (still resolved at gate time — harmless on HPP
# since placement is deterministic, and correct if placement ever changes).
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
CPU_WORKERS="${CPU_WORKERS:-32}"
CPU_LOAD="${CPU_LOAD:-100}"
# NOTE: VM_BYTES percentage in the hog image = % of the POD's cgroup view,
# not the node. For absolute node-memory targeting pass explicit sizes
# (e.g. MEM_BYTES=176g for ~35% of the 502GiB node). DURATION must be
# passed explicitly or run.sh defaults to 30s.
MEM_BYTES="${MEM_BYTES:-1g}"
MEM_WORKERS="${MEM_WORKERS:-4}"
IO_WORKERS="${IO_WORKERS:-8}"
IO_HDD_BYTES="${IO_HDD_BYTES:-2g}"
HOG_DURATION="${HOG_DURATION:-90}"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
CBT_NODE="${CBT_NODE:-}"   # resolved at gate time from the VMI (ODF mode)
HOG_NS="cbt-th-hog"
HOG_POD="${HOG_TYPE}-hog-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-T-${HOG_TYPE:0:1}/runs/$RUN_ID"
# Route io legs to T-03 dir, cpu→T-01, memory→T-02 (crude but explicit).
case "$HOG_TYPE" in
  cpu)    SCEN_DIR="CBT-T-01" ;;
  memory) SCEN_DIR="CBT-T-02" ;;
  io)     SCEN_DIR="CBT-T-03" ;;
  *) printf 'Unknown HOG_TYPE %s\n' "$HOG_TYPE" >&2; exit 2 ;;
esac
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/$SCEN_DIR/runs/$RUN_ID"
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
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'TH leg %s: %s-hog during full backup (cpu=%s@%s%% mem=%s io=%s dur=%ss).\n' \
  "$RUN_ID" "$HOG_TYPE" "$CPU_WORKERS" "$CPU_LOAD" "$MEM_BYTES" "$IO_WORKERS" "$HOG_DURATION" >&2

# --- Hog pod spec --------------------------------------------------------------
case "$HOG_TYPE" in
  cpu)
    HOG_CMD='cp -r /stress-ng/. /work/ && cd /work && bash run.sh'
    HOG_ENV="HOG_TYPE=cpu CPU_METHOD=all LOAD_PERCENTAGE=${CPU_LOAD} WORKERS=${CPU_WORKERS} DURATION=${HOG_DURATION}"
    ;;
  memory)
    HOG_CMD='cp -r /stress-ng/. /work/ && cd /work && bash run.sh'
    HOG_ENV="HOG_TYPE=memory VM_BYTES=${MEM_BYTES} WORKERS=${MEM_WORKERS} DURATION=${HOG_DURATION}"
    ;;
  io)
    # io variant: no image-copy needed — stress-ng runs directly against the hostPath.
    HOG_CMD="date -u +HOG_START_%FT%T; cd /hog-data && rm -rf ./tmp-stress-ng-hdd-* && stress-ng --hdd ${IO_WORKERS} --hdd-bytes ${IO_HDD_BYTES} --hdd-write-size 1m --hdd-opts dsync --timeout ${HOG_DURATION}; date -u +HOG_END_%FT%T"
    HOG_ENV=""
    ;;
esac
ENV_BLOCK=""
if [[ -n "$HOG_ENV" ]]; then
  ENV_BLOCK="    env:
$(printf '%s\n' "$HOG_ENV" | tr ' ' '\n' | while read -r kv; do
    printf '    - name: %s\n      value: "%s"\n' "${kv%%=*}" "${kv#*=}"
  done)"
fi
VOL_BLOCK='  volumes:
  - name: workdir
    emptyDir: {}'
MOUNT_BLOCK='    volumeMounts:
    - name: workdir
      mountPath: /work'
if [[ "$HOG_TYPE" == io ]]; then
  VOL_BLOCK='  volumes:
  - name: hog-data
    hostPath:
      path: /var/hpvolumes/csi
      type: Directory'
  MOUNT_BLOCK='    volumeMounts:
    - name: hog-data
      mountPath: /hog-data'
fi
# (hog spec is rendered at gate time, when the VM's node is resolved)
oc get namespace "$HOG_NS" >/dev/null 2>&1 || oc create namespace "$HOG_NS" >/dev/null
oc adm policy add-scc-to-user privileged -z default -n "$HOG_NS" >/dev/null 2>&1 || true
render_hog_pod() {
  cat > "$EVIDENCE_DIR/hog-pod.yaml" <<EOF
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
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: krkn-hog
    image: quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c", "$HOG_CMD"]
${ENV_BLOCK}
    securityContext:
      privileged: true
${MOUNT_BLOCK}
${VOL_BLOCK}
EOF
}

# --- Full backup in background; hog at gate ------------------------------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s Progressing.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
copy_start_epoch=$(date +%s)
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$prog" == True ]]; then
    gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    copy_start_epoch=$(date +%s)
    # ODF mode: resolve the VM's node at gate time (placement is scheduler's choice).
    CBT_NODE="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo '')"
    [[ -n "$CBT_NODE" ]] || { printf 'VMI has no nodeName at gate — aborting.\n' >&2; exit 2; }
    printf 'VM %s on node %s; rendering %s hog for that node.\n' "$VM_NAME" "$CBT_NODE" "$HOG_TYPE" >&2
    render_hog_pod
    oc apply -f "$EVIDENCE_DIR/hog-pod.yaml" >/dev/null
    printf 'Progressing=True at %s — %s hog applied on %s.\n' "$gate_hit_at" "$HOG_TYPE" "$CBT_NODE" >&2
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
for ((attempt = 1; attempt <= 60; attempt++)); do
  hp="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$hp" == Running ]] && { printf 'Hog Running at %s.\n' "$(date -u +%H:%M:%SZ)" >&2; break; }
  sleep 1
done
# Telemetry while the window runs (top snapshots + OOM watch).
( for ((i = 1; i <= 30; i++)); do
    printf '=== %s ===\n' "$(date -u +%H:%M:%SZ)"
    oc adm top node "$CBT_NODE" 2>/dev/null || true
    sleep 3
  done ) >"$EVIDENCE_DIR/node-top-during.txt" 2>/dev/null &
top_pid=$!
( for ((i = 1; i <= 15; i++)); do
    oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host \
      sh -c 'journalctl -k --since "1 minute ago" 2>/dev/null | grep -i "out of memory\|oom-kill" | tail -3' 2>/dev/null || true
    sleep 6
  done ) >"$EVIDENCE_DIR/node-oom-during.txt" 2>/dev/null &
oom_pid=$!
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
copy_end_epoch=$(date +%s)
copy_wall=$((copy_end_epoch - copy_start_epoch))
printf 'Workflow (full) exit status: %d; wall from gate to finish: %ss.\n' "$wf_status" "$copy_wall" >&2
kill "$top_pid" "$oom_pid" 2>/dev/null || true
sleep 2
oc logs "$HOG_POD" -n "$HOG_NS" >"$EVIDENCE_DIR/hog-pod.log" 2>/dev/null || true
hog_phase="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
printf 'Hog final phase: %s.\n' "$hog_phase" >&2
tail -4 "$EVIDENCE_DIR/hog-pod.log" >&2 || true
oc delete pod "$HOG_POD" -n "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
printf 'Backup: Done=%s reason=%s.\n' "$backup_done_status" "$backup_done_reason" >&2
launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
launcher_restarts="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
printf 'Launcher: %s restarts=%s.\n' "$launcher_pod" "$launcher_restarts" >&2
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json >"$EVIDENCE_DIR/launcher-status.json" 2>/dev/null || true
oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host journalctl -k --since "15 minutes ago" 2>/dev/null | grep -ci "out of memory\|oom-kill" >"$EVIDENCE_DIR/node-oom-kernel-count.txt" || echo 0 >"$EVIDENCE_DIR/node-oom-kernel-count.txt"
printf 'Kernel OOM lines (15min): %s.\n' "$(cat "$EVIDENCE_DIR/node-oom-kernel-count.txt")" >&2

# --- Follow-up incremental (only if full succeeded) ----------------------------
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

# --- Verdict (per-leg classification) -----------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
BASELINE_MIN=52; BASELINE_MAX=58
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* && "$copy_wall" -le $((BASELINE_MAX * 2)) ]]; then
  verdict="NO_EFFECT (backup ${copy_wall}s within 2x baseline; Done=True success)"
elif [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* ]]; then
  verdict="DEGRADED (backup ${copy_wall}s > 2x baseline ${BASELINE_MIN}-${BASELINE_MAX}s; Done=True success)"
elif [[ "$backup_done_status" == True ]]; then
  verdict="FAILED-CLEANLY (Done=True reason: $backup_done_reason)"
else
  verdict="HARNESS-ANOMALY (done=$backup_done_status — inspect)"
fi
printf 'CHECK leg-verdict: %s\n' "$verdict" | tee -a "$checks_file" >&2
oom_count="$(cat "$EVIDENCE_DIR/node-oom-kernel-count.txt")"
if [[ "$oom_count" == 0 && "$launcher_restarts" == 0 ]]; then
  printf 'CHECK no-oom-no-restart: PASS\n' | tee -a "$checks_file" >&2
else
  printf 'CHECK no-oom-no-restart: FAIL (oom_lines=%s launcher_restarts=%s)\n' "$oom_count" "$launcher_restarts" | tee -a "$checks_file" >&2
fi
printf 'CHECK backup-terminal-state: done=%s reason=%s\n' "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK copy-wall-seconds: %s (baseline %s-%s)\n' "$copy_wall" "$BASELINE_MIN" "$BASELINE_MAX" | tee -a "$checks_file" >&2
printf 'CHECK hog-evidence: phase=%s log-tail=%s\n' "$hog_phase" "$(tail -1 "$EVIDENCE_DIR/hog-pod.log" 2>/dev/null | cut -c1-80)" | tee -a "$checks_file" >&2
if [[ -n "$incr_status" ]]; then
  printf 'CHECK followup-incremental: rc=%s tracker=%s\n' "$incr_status" "$tracker_cp" | tee -a "$checks_file" >&2
fi
printf 'TH leg complete.\n' >&2
exit 0
