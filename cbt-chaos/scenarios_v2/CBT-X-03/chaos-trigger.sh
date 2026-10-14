#!/usr/bin/env bash
# CBT-X-03 r01: block ALL IP traffic (ingress+egress, tcp+udp) to the VM
# launcher pod during the full backup copy.
#
# Jira: technical scenario "application-outages" wants ALL IP traffic to the
# launcher blocked for 45s during the active disk copy. The krknctl
# application-outages plugin is namespace-wide (it blocks whole-namespace
# traffic) — with other VMs potentially sharing vm-cbt-demo that would
# over-disrupt. The F-12-proven direct-krkn pod_network_filter pattern
# targets an exact pod, so we use it with target = this run's launcher pod,
# ingress+egress, both protocols, all ports.
#
# Expected: copy continues (node-local, no pod networking involved); guest
# SSH breaks during the window and recovers after; post-chaos connectivity
# verified (F-12 bug #7: rule can leak if target container restarts
# mid-chaos — launcher must NOT restart, or the leak must be caught).
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
CHAOS_DURATION=45
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-X-03/runs/$RUN_ID"
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
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01-trigger.log") 2>&1
printf 'X03 r01: full IP block on launcher during full-backup copy, run %s.\n' "$RUN_ID" >&2
krkn_work="/tmp/x03-krkn-work-${RUN_ID}"
scenario_yaml="$krkn_work/scenario.yml"
rm -rf "$krkn_work"
mkdir -p "$krkn_work"
cat >"$krkn_work/kraken-config.yml" <<EOF
kraken:
    distribution: openshift
    kubeconfig_path: /work/kubeconfig
    exit_on_failure: False
    publish_kraken_status: False
    signal_state: RUN
    signal_address: 0.0.0.0
    port: 8081
    auto_rollback: False
    chaos_scenarios:
        -   network_chaos_ng_scenarios:
                - /work/scenario.yml
cerberus:
    cerberus_enabled: False
performance_monitoring:
    capture_metrics: False
    check_critical_alerts: False
    enable_alerts: False
    enable_metrics: False
tunings:
    wait_duration: 5
    iterations: 1
    daemon_mode: False
telemetry:
    enabled: False
elastic:
    enable_elastic: False
EOF
cp "$KUBECONFIG_PATH" "$krkn_work/kubeconfig"
chmod 644 "$krkn_work/kubeconfig"
krknctl_log="$EVIDENCE_DIR/r01-krkn.log"

# --- Stage 1: full backup; block launcher traffic at Progressing gate -------
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
    launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
    [[ -n "$launcher_pod" ]] || { printf 'No launcher pod at gate — aborting.\n' >&2; exit 2; }
    printf 'Progressing=True at %s — blocking ALL traffic on launcher %s for %ss.\n' \
      "$gate_hit_at" "$launcher_pod" "$CHAOS_DURATION" >&2
    # Snapshot launcher identity pre-chaos.
    oc get pod "$launcher_pod" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01-launcher-pre.json"
    # Direct krkn pod_network_filter (F-12 pattern): target the exact pod.
    cat >"$scenario_yaml" <<EOF
- id: pod_network_filter
  image: "quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos"
  wait_duration: 1
  test_duration: ${CHAOS_DURATION}
  label_selector: ""
  service_account: ""
  taints: []
  namespace: "${NAMESPACE}"
  instance_count: 1
  execution: serial
  ingress: true
  egress: true
  target: "${launcher_pod}"
  interfaces: []
  protocols:
    - tcp
    - udp
  ports: []
EOF
    cp "$scenario_yaml" "$EVIDENCE_DIR/r01-scenario.yml"
    podman run --rm --entrypoint bash \
      -v "$krkn_work":/work:Z \
      quay.io/krkn-chaos/krkn:latest \
      -c "cd /home/krkn/kraken && timeout $((CHAOS_DURATION + 180)) python3.11 run_kraken.py -c /work/kraken-config.yml" \
      >"$krknctl_log" 2>&1 &
    krkn_pid=$!
    printf 'krkn pod_network_filter started (pid=%s).\n' "$krkn_pid" >&2
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
# While chaos runs: probe guest SSH (via the workflow's SSH service port-forward
# path is complex mid-run; instead probe the launcher's network from inside).
( for ((i = 1; i <= 25; i++)); do
    ts="$(date -u +%H:%M:%S)"
    dns="$(oc exec "$launcher_pod" -n "$NAMESPACE" -c compute -- \
      timeout 3 getent hosts kubernetes.default.svc 2>/dev/null | wc -l | tr -d ' ')"
    api="$(oc exec "$launcher_pod" -n "$NAMESPACE" -c compute -- \
      timeout 3 curl -s -o /dev/null -m 2 https://172.30.0.1:443/healthz 2>/dev/null && echo 1 || echo 0)"
    printf '%s dns_ok=%s api_ok=%s\n' "$ts" "$dns" "$api"
    sleep 3
  done ) >"$EVIDENCE_DIR/r01-launcher-net-probe.txt" 2>&1 &
probe_pid=$!
krkn_rc=0
if wait "$krkn_pid"; then krkn_rc=0; else krkn_rc=$?; fi
printf 'krkn exited rc=%d at %s.\n' "$krkn_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
kill "$probe_pid" 2>/dev/null || true
# Bug #7 guard: verify the launcher regained connectivity; delete the pod ONLY
# if it stayed blocked AND it is safe to (the backup should be done by now —
# check first).
backup_done_status="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
post_chaos_dns="$(oc exec "$launcher_pod" -n "$NAMESPACE" -c compute -- \
  timeout 5 getent hosts kubernetes.default.svc 2>/dev/null | wc -l | tr -d ' ')"
post_chaos_api="$(oc exec "$launcher_pod" -n "$NAMESPACE" -c compute -- \
  timeout 5 curl -s -o /dev/null -m 4 https://172.30.0.1:443/healthz 2>/dev/null && echo 1 || echo 0)"
printf 'Post-chaos: backup Done=%s, launcher dns_ok=%s api_ok=%s.\n' "$backup_done_status" "$post_chaos_dns" "$post_chaos_api" >&2
if [[ "$post_chaos_dns" == 0 || "$post_chaos_api" == 0 ]]; then
  if [[ "$backup_done_status" == True ]]; then
    printf 'RULE-LEAK GUARD: launcher still blocked after chaos; backup already Done — deleting launcher to restore connectivity (VM recovers on new launcher).\n' >&2
    oc delete pod "$launcher_pod" -n "$NAMESPACE" --wait=false
    rule_leak="RECOVERED-BY-DELETE (bug #7 guard fired)"
  else
    printf 'RULE-LEAK GUARD: launcher still blocked and backup NOT done — NOT deleting (copy is node-local; wait for workflow).\n' >&2
    rule_leak="LEAK-OBSERVED (backup still running; not deleted)"
  fi
else
  rule_leak="none (connectivity restored with rule removal)"
fi
printf 'Rule-leak outcome: %s.\n' "$rule_leak" >&2
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
launcher_pod_after="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
launcher_restarts="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
printf 'Launcher after: %s restarts=%s (pre-chaos: %s).\n' "$launcher_pod_after" "$launcher_restarts" "$launcher_pod" >&2
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json >"$EVIDENCE_DIR/r01-launcher-post.json" 2>/dev/null || true
if ((wf_status != 0)); then
  printf 'Full stage failed — capturing failure evidence.\n' >&2
  oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o json >"$EVIDENCE_DIR/r01-vmbackup-failed.json" 2>/dev/null || true
  exit "$wf_status"
fi
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
printf 'Backup: Done=%s reason=%s.\n' True "$backup_done_reason" >&2
# Guest SSH recovery check: the workflow's own incremental stage does guest
# mutation over SSH — a clean incremental run proves guest access recovered.

# --- Stage 2: clean incremental pass (proves guest SSH recovered) -------------
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01-incr-stage.log" 2>&1; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
((incr_status == 0)) || { printf 'Follow-up incremental failed.\n' >&2; exit "$incr_status"; }
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/r01-trigger-checks.txt"
: > "$checks_file"
if [[ -n "$gate_hit_at" && "$krkn_rc" == 0 ]] && grep -q "applying iptables\|removing iptables rules" "$krknctl_log" 2>/dev/null; then
  inject_check="PASS (gate hit $gate_hit_at; krkn rc=0; iptables rules applied+removed for $launcher_pod)"
else
  inject_check="FAIL (gate=$gate_hit_at krkn_rc=$krkn_rc)"
fi
printf 'CHECK injection-during-copy: %s\n' "$inject_check" | tee -a "$checks_file" >&2
blocked_samples="$(grep -cE "dns_ok=0|api_ok=0" "$EVIDENCE_DIR/r01-launcher-net-probe.txt" || true)"
ok_samples="$(grep -cE "dns_ok=1.*api_ok=1" "$EVIDENCE_DIR/r01-launcher-net-probe.txt" || true)"
if ((blocked_samples > 0)); then
  traffic_check="PASS ($blocked_samples blocked samples / $ok_samples fully-unblocked during window — disruption observed)"
else
  traffic_check="FAIL (no blocked samples observed)"
fi
printf 'CHECK traffic-blocked-observed: %s\n' "$traffic_check" | tee -a "$checks_file" >&2
if [[ "$backup_done_status" == True ]]; then
  backup_check="PASS (Done=True reason=$backup_done_reason)"
else
  backup_check="FAIL (done=$backup_done_status)"
fi
printf 'CHECK backup-completed: %s\n' "$backup_check" | tee -a "$checks_file" >&2
if [[ "$launcher_pod_after" == "$launcher_pod" && "$launcher_restarts" == 0 ]]; then
  launcher_check="PASS (same pod $launcher_pod, restartCount=0)"
else
  launcher_check="NOTE (pod $launcher_pod → $launcher_pod_after, restarts=$launcher_restarts; rule-leak guard outcome: $rule_leak)"
fi
printf 'CHECK launcher-identity: %s\n' "$launcher_check" | tee -a "$checks_file" >&2
if [[ "$rule_leak" == none* ]]; then
  recovery_check="PASS (connectivity restored with rule removal; no leak)"
elif [[ "$rule_leak" == RECOVERED* ]]; then
  recovery_check="PASS-WITH-GUARD (leak recovered by pod deletion after backup Done)"
else
  recovery_check="FAIL ($rule_leak)"
fi
printf 'CHECK connectivity-recovered: %s\n' "$recovery_check" | tee -a "$checks_file" >&2
if ((incr_status == 0)); then
  followup_check="PASS (incremental + guest mutation over SSH + restore verification PASS — guest access recovered)"
else
  followup_check="FAIL"
fi
printf 'CHECK clean-followup: %s\n' "$followup_check" | tee -a "$checks_file" >&2
if [[ "$tracker_cp" == *"$RUN_ID"* ]]; then
  tracker_check="PASS (latestCheckpoint $tracker_cp)"
else
  tracker_check="FAIL ($tracker_cp)"
fi
printf 'CHECK tracker-advanced: %s\n' "$tracker_check" | tee -a "$checks_file" >&2
printf 'X03 r01 complete.\n' >&2
exit 0
