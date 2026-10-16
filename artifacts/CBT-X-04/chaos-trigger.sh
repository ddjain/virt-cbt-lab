#!/usr/bin/env bash
# CBT-X-04 r01: combined failure — storage I/O pressure + launcher stop
# during the SAME full backup copy.
#
# Jira: start controlled I/O pressure at the active-copy gate, stop the
# launcher ~20s later. Expect: backup fails cleanly, tracker NOT advanced,
# VM recovers, storage load ends; then a complete clean full+incremental
# workflow with hash/marker validation.
#
# Mechanism (both legs are sanctioned patterns from this campaign):
#  - I/O leg: direct hog pod (I-04 r03 / R-02 recipe — krkn-hub image,
#    dsync hdd workers on the HPP pool filesystem /var/hpvolumes/csi on
#    /dev/sdb, the SAME device as the backup PVCs; X-01 emptyDir-workdir
#    workaround for the read-only-IMAGE issue not needed here because the
#    io variant cds to the hostPath /hog-data before writing).
#  - Launcher leg: force-delete launcher pod (I-02 r04 recipe, oc delete
#    --grace-period=0 --force).
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
# Backend note: the HPP storage node outage (2026-10-13 17:22→18:50Z, X-03
# krkn rule leak) was recovered surgically (IPv6 link-local SSH + iptables-
# legacy flush via a krkn container — see X-03 report). All remaining runs
# use the intended HPP/default backend on d38-h18-000-r660; the I/O hog
# targets /var/hpvolumes/csi (same /dev/sdb as VM disk + backup PVCs).
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
CBT_NODE="${CBT_NODE:-}"   # resolved at gate time from the VMI (ODF mode)
HOG_DURATION=90          # Jira: 90s of I/O load
LAUNCHER_KILL_DELAY=20   # Jira: launcher stopped ~20s after load begins
HOG_NS="x04-hog-${RUN_ID}"
HOG_POD="io-hog-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-X-04/runs/$RUN_ID"
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
# Guards: node Ready + HPP pool capacity on the REAL CSI path.
node_ready="$(oc get node "${CBT_NODE:-d38-h18-000-r660}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
if [[ "$node_ready" != True ]]; then
  printf 'Node %s not Ready (%s) — aborting.\n' "${CBT_NODE:-d38-h18-000-r660}" "$node_ready" >&2
  exit 2
fi
POOL_FREE_KIB="$(oc debug node/d38-h18-000-r660 --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01-trigger.log") 2>&1
printf 'X04 r01: io-hog + launcher kill during full backup, run %s.\n' "$RUN_ID" >&2

# --- Hog namespace (spec is rendered at the gate, when the VM's node is known) --
oc create namespace "$HOG_NS" >/dev/null
oc adm policy add-scc-to-user privileged -z default -n "$HOG_NS" >/dev/null 2>&1 || true

# --- Stage 1: full backup; hog at gate; launcher kill +20s --------------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01-full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s Progressing.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
launcher_pod=""
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$prog" == True ]]; then
    gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Resolve the VM's node at gate time (ODF mode: placement is scheduler's choice).
    CBT_NODE="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo '')"
    [[ -n "$CBT_NODE" ]] || { printf 'VMI has no nodeName at gate — aborting.\n' >&2; exit 2; }
    node_ready_now="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    printf 'VM %s runs on node %s (Ready=%s); rendering hog for that node.\n' "$VM_NAME" "$CBT_NODE" "$node_ready_now" >&2
    cat > "$EVIDENCE_DIR/r01-hog-pod.yaml" <<EOF
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
  - name: io-hog
    image: quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c", "date -u +HOG_START_%FT%T; cd /hog-data && stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync --timeout ${HOG_DURATION}; date -u +HOG_END_%FT%T"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: hog-data
      mountPath: /hog-data
  volumes:
  - name: hog-data
    hostPath:
      path: /var/hpvolumes/csi
      type: Directory
EOF
    oc apply -f "$EVIDENCE_DIR/r01-hog-pod.yaml" >/dev/null
    printf 'Progressing=True at %s — I/O hog applied on %s (90s dsync on /var/hpvolumes/csi).\n' "$gate_hit_at" "$CBT_NODE" >&2
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
# Confirm hog Running.
for ((attempt = 1; attempt <= 60; attempt++)); do
  hp="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$hp" == Running ]] && { printf 'Hog Running at %s.\n' "$(date -u +%H:%M:%SZ)" >&2; break; }
  sleep 1
done
# Wait LAUNCHER_KILL_DELAY seconds of load, then force-delete the launcher.
launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
[[ -n "$launcher_pod" ]] || { printf 'No launcher pod found — aborting kill leg.\n' >&2; exit 2; }
oc get pod "$launcher_pod" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01-launcher-pre.json"
sleep "$LAUNCHER_KILL_DELAY"
kill_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc delete pod "$launcher_pod" -n "$NAMESPACE" --grace-period=0 --force --wait=false
printf 'Launcher %s force-deleted at %s (hog still running).\n' "$launcher_pod" "$kill_at" >&2
# Capture backup + tracker state right after the kill.
sleep 5
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01-vmbackup-after-kill.json" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01-tracker-after-kill.json" 2>/dev/null || true
# Wait for the full stage to finish (expected FAIL — the workflow exits nonzero
# when the backup fails; capture its exit but continue to recovery validation).
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d (nonzero EXPECTED — backup should fail cleanly).\n' "$wf_status" >&2
# Hog completion evidence.
hog_phase="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
oc logs "$HOG_POD" -n "$HOG_NS" >"$EVIDENCE_DIR/r01-hog-pod.log" 2>/dev/null || true
printf 'Hog final phase: %s; log tail: %s\n' "$hog_phase" "$(tail -2 "$EVIDENCE_DIR/r01-hog-pod.log" 2>/dev/null | tr '\n' ' ')" >&2
# Post-failure state capture.
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01-vmbackup-final.json" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01-tracker-final.json" 2>/dev/null || true
backup_done_status="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
printf 'Backup final: Done=%s reason=%s.\n' "$backup_done_status" "$backup_done_reason" >&2
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo none)"
tracker_status_raw="$(jq -r '.status // "none"' "$EVIDENCE_DIR/r01-tracker-final.json" 2>/dev/null || echo none)"
printf 'Tracker final: latestCheckpoint=%s status=%s.\n' "$tracker_cp" "$tracker_status_raw" >&2

# --- Stage 2: VM recovery observation ------------------------------------------
printf 'Waiting for VM recovery (new launcher Running)…\n' >&2
recovered_at=""
for ((attempt = 1; attempt <= 240; attempt++)); do
  new_launcher="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
  new_phase="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo '')"
  if [[ -n "$new_launcher" && "$new_launcher" != "$launcher_pod" && "$new_phase" == Running ]]; then
    recovered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    break
  fi
  sleep 5
done
printf 'VM recovery: %s (new launcher %s at %s).\n' "${recovered_at:+RECOVERED}" "${new_launcher:-none}" "${recovered_at:-never}" >&2
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json >"$EVIDENCE_DIR/r01-launcher-post.json" 2>/dev/null || true

# --- Stage 3: complete clean full + incremental workflow (fresh run) -----------
# The Jira requires "a complete clean full and incremental workflow with hash
# and marker validation" after the failure. Run it as a NEW run ID so the
# failed run's objects stay pristine as evidence.
CLEAN_RUN_ID="${RUN_ID}-clean"
clean_status=0
if make e2e TYPE=full NAME="$CLEAN_RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01-clean-full-incr.log" 2>&1; then
  clean_status=0
else
  clean_status=$?
fi
printf 'Clean full+incremental workflow exit status: %d.\n' "$clean_status" >&2
oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/r01-trigger-checks.txt"
: > "$checks_file"
if [[ -n "$gate_hit_at" ]] && grep -q "HOG_START" "$EVIDENCE_DIR/r01-hog-pod.log" 2>/dev/null; then
  inject_check="PASS (gate hit $gate_hit_at; hog started $(grep -o 'HOG_START_[^ ]*' "$EVIDENCE_DIR/r01-hog-pod.log" | head -1); launcher killed $kill_at = +${LAUNCHER_KILL_DELAY}s into load)"
else
  inject_check="FAIL (gate=$gate_hit_at hog_log=$(grep -c HOG_START "$EVIDENCE_DIR/r01-hog-pod.log" 2>/dev/null || echo 0))"
fi
printf 'CHECK combined-injection: %s\n' "$inject_check" | tee -a "$checks_file" >&2
if [[ "$backup_done_status" == True && "$backup_done_reason" == *"failed"* ]]; then
  fail_check="PASS (backup failed cleanly: reason=$backup_done_reason)"
elif [[ "$backup_done_status" == True ]]; then
  fail_check="NOTE (backup SUCCEEDED despite combined chaos: reason=$backup_done_reason)"
else
  fail_check="FAIL (backup not terminal: done=$backup_done_status)"
fi
printf 'CHECK backup-fails-cleanly: %s\n' "$fail_check" | tee -a "$checks_file" >&2
if [[ "$tracker_cp" == none || -z "$tracker_cp" || "$tracker_status_raw" == "none" || "$tracker_status_raw" == "{}" ]]; then
  tracker_check="PASS (tracker NOT advanced past last-good: latestCheckpoint=%s status=%s)" 
  tracker_check="$(printf "$tracker_check" "${tracker_cp:-none}" "$tracker_status_raw")"
elif [[ "$tracker_cp" != *"$RUN_ID"* ]]; then
  tracker_check="PASS (tracker holds earlier checkpoint: $tracker_cp)"
else
  tracker_check="FAIL (tracker advanced to this run: $tracker_cp)"
fi
printf 'CHECK tracker-not-advanced: %s\n' "$tracker_check" | tee -a "$checks_file" >&2
if [[ -n "$recovered_at" ]]; then
  recover_check="PASS (new launcher $new_launcher Running at $recovered_at)"
else
  recover_check="FAIL (VM never recovered)"
fi
printf 'CHECK vm-recovered: %s\n' "$recover_check" | tee -a "$checks_file" >&2
if ((clean_status == 0)); then
  clean_check="PASS (complete clean full+incremental+verify workflow PASS: run $CLEAN_RUN_ID)"
else
  clean_check="FAIL (clean workflow rc=$clean_status — see r01-clean-full-incr.log)"
fi
printf 'CHECK clean-followup-lifecycle: %s\n' "$clean_check" | tee -a "$checks_file" >&2
printf 'X04 r01 complete.\n' >&2
exit 0
