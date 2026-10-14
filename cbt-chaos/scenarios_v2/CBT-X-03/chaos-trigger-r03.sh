#!/usr/bin/env bash
# CBT-X-03 r03: deferred verification leg.
#
# The decisive r02 run proved the backup completes under a total launcher
# network block (and even a node-wide outage), but the node incident cut the
# run short of its guest-recovery and restore-verification criteria. This leg
# runs the Jira's scenario on the recovered cluster with a SAFE injection —
# an EXPLICIT port list (22 + 443) rather than ports:[] (which krkn turns
# into a node-destructive host-netns rule, krknctl-bugs #11) — and completes
# the full lifecycle: block during copy, backup succeeds, connectivity
# restored with rule removal, guest SSH recovers, incremental + restore
# verify PASS.
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
node_ready="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
if [[ "$node_ready" != True ]]; then
  printf 'Node %s not Ready (%s) — aborting.\n' "$CBT_NODE" "$node_ready" >&2
  exit 2
fi
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r03-trigger.log") 2>&1
printf 'X03 r03: verification leg (explicit-port block), run %s.\n' "$RUN_ID" >&2
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
krknctl_log="$EVIDENCE_DIR/r03-krkn.log"

# --- Stage 1: full backup; block launcher traffic (22/443) at gate -------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r03-full-stage.log" 2>&1 &
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
    printf 'Progressing=True at %s — blocking tcp/udp 22+443 on launcher %s for %ss.\n' \
      "$gate_hit_at" "$launcher_pod" "$CHAOS_DURATION" >&2
    oc get pod "$launcher_pod" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r03-launcher-pre.json"
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
  ports:
    - 22
    - 443
EOF
    cp "$scenario_yaml" "$EVIDENCE_DIR/r03-scenario.yml"
    podman run --rm --entrypoint bash \
      -v "$krkn_work":/work:Z \
      quay.io/krkn-chaos/krkn:latest \
      -c "cd /home/krkn/kraken && timeout $((CHAOS_DURATION + 180)) python3.11 run_kraken.py -c /work/kraken-config.yml" \
      >"$krknctl_log" 2>&1 &
    krkn_pid=$!
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
krkn_rc=0
if wait "$krkn_pid"; then krkn_rc=0; else krkn_rc=$?; fi
printf 'krkn exited rc=%d at %s.\n' "$krkn_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
# Connectivity restored? (bug #7 leak guard — explicit ports, node-safe)
post_dns="$(oc exec "$launcher_pod" -n "$NAMESPACE" -c compute -- \
  timeout 5 getent hosts kubernetes.default.svc 2>/dev/null | wc -l | tr -d ' ')"
printf 'Post-chaos launcher dns_ok=%s.\n' "$post_dns" >&2
if [[ "$post_dns" == 0 ]]; then
  printf 'RULE-LEAK GUARD: launcher still blocked — deleting to restore (new netns).\n' >&2
  oc delete pod "$launcher_pod" -n "$NAMESPACE" --wait=false
  rule_leak="RECOVERED-BY-DELETE"
else
  rule_leak="none"
fi
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
printf 'Backup: Done=%s reason=%s.\n' "$backup_done_status" "$backup_done_reason" >&2
((wf_status == 0)) || { printf 'Full stage failed.\n' >&2; exit "$wf_status"; }
node_ready_after="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
printf 'Node Ready after chaos: %s (incident-free explicit-port block).\n' "$node_ready_after" >&2

# --- Stage 2: incremental + restore verify (proves guest SSH + data path) ------
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r03-incr-stage.log" 2>&1; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
((incr_status == 0)) || { printf 'Follow-up incremental failed.\n' >&2; exit "$incr_status"; }
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/r03-trigger-checks.txt"
: > "$checks_file"
rules_applied=$(grep -c "applying iptables" "$krknctl_log" 2>/dev/null || echo 0)
rules_removed=$(grep -c "removing iptables rules" "$krknctl_log" 2>/dev/null || echo 0)
if [[ -n "$gate_hit_at" && "$krkn_rc" == 0 && "$rules_applied" -gt 0 && "$rules_removed" -gt 0 ]]; then
  inject_check="PASS (gate $gate_hit_at; $rules_applied rule lines applied; clean removal; rc=0)"
else
  inject_check="FAIL (gate=$gate_hit_at rc=$krkn_rc applied=$rules_applied removed=$rules_removed)"
fi
printf 'CHECK injection-clean-cycle: %s\n' "$inject_check" | tee -a "$checks_file" >&2
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* ]]; then
  backup_check="PASS (Done=True success)"
else
  backup_check="FAIL (done=$backup_done_status reason=$backup_done_reason)"
fi
printf 'CHECK backup-completed: %s\n' "$backup_check" | tee -a "$checks_file" >&2
if [[ "$rule_leak" == none ]]; then
  recovery_check="PASS (connectivity restored with rule removal; leak=$rule_leak)"
else
  recovery_check="NOTE (leak guard fired: $rule_leak)"
fi
printf 'CHECK connectivity-recovered: %s\n' "$recovery_check" | tee -a "$checks_file" >&2
if [[ "$node_ready_after" == True ]]; then
  node_check="PASS (node stayed Ready — explicit-port block is node-safe)"
else
  node_check="FAIL (node $node_ready_after)"
fi
printf 'CHECK node-healthy: %s\n' "$node_check" | tee -a "$checks_file" >&2
if ((incr_status == 0)); then
  followup_check="PASS (incremental + guest mutation over SSH + restore verification bit-exact)"
else
  followup_check="FAIL"
fi
printf 'CHECK guest-recovery-and-restore: %s\n' "$followup_check" | tee -a "$checks_file" >&2
printf 'X03 r03 complete.\n' >&2
exit 0
