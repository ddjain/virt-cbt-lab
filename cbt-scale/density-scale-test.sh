#!/usr/bin/env bash
set -euo pipefail
# density-scale-test.sh — reusable N-VM parallel CBT backup scale test.
#
# Wraps the proven flow: density-setup (kube-burner pool) → parallel driver
# (baseline workload → all-N full backups at once → incremental workload →
# all-N incremental backups at once → Done-reason + tracker validation)
# → storage-utilization snapshots at each stage → summary report.
#
# Usage:
#   ./density-scale-test.sh [N] [VM_OS] [options]
#     N        number of VMs (default: asks)
#     VM_OS    rhel9 | rhel9-light | windows (default: asks; rhel9 uses
#              large-odf profile, rhel9-light a 10Gi-root RHEL 9 (needs
#              `make rhel-light-golden` once), windows uses the windows-odf profile with OOBE-aware timeouts)
#
# Options:
#   --pool <id>          reuse/expect this pool id (default: auto-generated)
#   --keep               do NOT clean up previous run's objects first
#   --skip-setup         pool already exists and is ready; skip density-setup
#   --backup-sc <sc>     backup destination storage class
#                        (default: ocs-storagecluster-ceph-rbd, durable 3-copy)
#   --wave <n>           SSH workload wave size (default 25)
#   --full-timeout <s>   full-phase poll timeout (default 5400s)
#
# Behaviour:
#   - ALWAYS asks before cleaning previous VMs/backups (unless --keep).
#   - ALWAYS asks for the OS profile if not provided and not defaulted.
#   - Restartable: driver phases skip work already done (per-VM log markers).
#
# Requirements: oc, jq, virtctl not needed; kubeconfig with cluster access;
# repo checkout with manifests/ (this repo) on the execution host.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"; export SCALE_STATE_DIR
DRIVER="$SCRIPT_DIR/scale-driver2.sh"
SNAPSHOT="$SCRIPT_DIR/storage-snapshot.sh"
LOG_DIR_HOST="/tmp/density-scale-test"
EVIDENCE_ROOT="$SCALE_STATE_DIR"

# ---- defaults ----
N=""
VM_OS=""
POOL=""
KEEP=false
SKIP_SETUP=false
BACKUP_SC="ocs-storagecluster-ceph-rbd"
WAVE=25
FULL_TIMEOUT=5400

# ---- arg parsing ----
while (($#)); do
  case "$1" in
    --pool) POOL="$2"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    --skip-setup) SKIP_SETUP=true; shift ;;
    --backup-sc) BACKUP_SC="$2"; shift 2 ;;
    --wave) WAVE="$2"; shift 2 ;;
    --full-timeout) FULL_TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)
      if [[ -z "$N" ]] && [[ "$1" =~ ^[1-9][0-9]*$ ]]; then N="$1"; shift
      elif [[ -z "$VM_OS" ]] && [[ "$1" == rhel9 || "$1" == rhel9-light || "$1" == windows ]]; then VM_OS="$1"; shift
      else printf 'unknown argument: %s\n' "$1" >&2; exit 2; fi ;;
  esac
done

: "${KUBECONFIG:?export KUBECONFIG first}"

export NAMESPACE="${NAMESPACE:-vm-cbt-demo}"

ask() { # $1 question, $2 default (y/n)
  local d="${2:-y}" reply
  read -r -p "$1 [$d] " reply || true
  reply="${reply:-$d}"
  [[ "$reply" =~ ^[Yy] ]]
}

os_profile_note() {
  case "$1" in
    rhel9)   printf 'rhel9 + MANIFEST_VARIANT=large-odf (80Gi root, 90Gi full dest, 30Gi incr dest)' ;;
    rhel9-light) printf 'rhel9-light + MANIFEST_VARIANT=large-odf (10Gi root, 12Gi full dest, 2Gi incr dest)' ;;
    windows) printf 'windows + windows-odf profile (60Gi Block root, 70Gi full dest, 30Gi incr dest; OOBE ~20-25 min, GUEST_EXEC_POLL_ATTEMPTS=450)' ;;
  esac
}

# ---- 1. N ----
if [[ -z "$N" ]]; then
  read -r -p "Number of VMs to test in parallel: " N
  [[ "$N" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid N\n' >&2; exit 2; }
fi

# ---- 2. OS profile (always ask if not provided) ----
if [[ -z "$VM_OS" ]]; then
  printf 'Available OS profiles:\n'
  printf '  1) rhel9   — %s\n' "$(os_profile_note rhel9)"
  printf '  2) windows — %s\n' "$(os_profile_note windows)"
  printf '  3) rhel9-light — %s\n' "$(os_profile_note rhel9-light)"
  read -r -p "Select OS profile [1/2/3] (default 1): " sel
  sel="${sel:-1}"
  case "$sel" in
    1) VM_OS=rhel9 ;;
    2) VM_OS=windows ;;
    3) VM_OS=rhel9-light ;;
    *) printf 'invalid selection\n' >&2; exit 2 ;;
  esac
fi
printf 'OS profile: %s (%s)\n' "$VM_OS" "$(os_profile_note "$VM_OS")"


# ---- 3. cleanup gate: always ask (unless --keep) ----
if [[ "$KEEP" != true ]]; then
  existing=$(oc get vm,vmbackup,vmbackuptracker,pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if (( existing > 0 )); then
    printf 'Found %s existing VMs/backups/PVCs in the namespace from previous runs.\n' "$existing"
    if ask 'Clean up ALL previous VMs, backups, trackers and PVCs first? This is destructive' n; then
      printf 'Cleaning previous run objects...\n'
      oc delete vmbackup -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1 || true
      oc delete vmbackuptracker -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1 || true
      oc delete vm -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1 || true
      # PVCs labeled virt-cbt-lab/golden=true are CDI-managed golden images; never delete
      oc delete pvc -n "$NAMESPACE" -l '!virt-cbt-lab/golden' --wait=false >/dev/null 2>&1 || true
      oc delete svc -n "$NAMESPACE" --all --wait=false >/dev/null 2>&1 || true
      for i in $(seq 1 60); do
        v=$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,svc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        p=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        (( v == 0 && p == 0 )) && break
        sleep 15
      done
      # purge Released/Available PVs (this namespace's claims) so storage returns to baseline
      for round in $(seq 1 10); do
        oc get pv -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Released" or .status.phase=="Available") | select(.spec.claimRef.namespace=="'"$NAMESPACE"'") | .metadata.name' \
          | xargs -r -n 20 -I{} oc delete pv {} --wait=false >/dev/null 2>&1 || true
        sleep 20
        left=$(oc get pv -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Released" or .status.phase=="Available") | select(.spec.claimRef.namespace=="'"$NAMESPACE"'")] | length')
        (( left == 0 )) && break
      done
      printf 'Previous run cleaned.\n'
    else
      printf 'Keeping previous objects (--keep behaviour); they will coexist with the new pool.\n' >&2
    fi
  fi
fi

if [[ "$SKIP_SETUP" != true ]]; then
# ---- 4. pool setup ----
  if [[ -z "$POOL" ]]; then
    case "$VM_OS" in
      rhel9)   POOL="rhel-$(date -u +%m%d%H%M%S)" ;;
      rhel9-light) POOL="rhl-$(date -u +%m%d%H%M%S)" ;;
      windows) POOL="win-$(date -u +%m%d%H%M%S)" ;;
    esac
  fi
  printf 'Creating density pool %s with %s %s VMs...\n' "$POOL" "$N" "$VM_OS"
  bash "$SNAPSHOT" "${POOL}-pre-setup" >/dev/null 2>&1 || true
  ( cd "$ROOT_DIR" && set -a && . ./.env 2>/dev/null || true; set +a
    make density-setup VM_OS="$VM_OS" MANIFEST_VARIANT=large-odf \
      DENSITY_VM_COUNT="$N" DENSITY_INCREMENTAL_PASSES=1 DENSITY_QPS=50 \
      POOL="$POOL" 2>&1 | tail -5 )
else
  [[ -n "$POOL" ]] || { printf '--skip-setup requires --pool\n' >&2; exit 2; }
  printf 'Skipping setup; waiting for pool %s readiness...\n' "$POOL"
fi

# wait for readiness (works for both paths)
while :; do
  ready=$(oc get vm -n "$NAMESPACE" -l "virt-cbt-lab/pool=$POOL" -o json \
    | jq '[.items[] | .status.ready // false] | map(select(.)) | length' 2>/dev/null || echo 0)
  printf '\rready %s/%s' "$ready" "$N"
  (( ready >= N )) 2>/dev/null && break
  sleep 30
done
printf '\nPool %s ready (%s/%s).\n' "$POOL" "$ready" "$N"
bash "$SNAPSHOT" "${POOL}-post-setup" >/dev/null 2>&1 || true

# ---- 5. run the driver ----
printf 'Running parallel backup driver (full + 1 incremental, all-at-once waves)...\n'
# driver2 hardcodes scale-50 evidence dir; point evidence at a per-run dir
EVID="$EVIDENCE_ROOT/density-scale-$POOL"
mkdir -p "$EVID"
# driver2 honours BACKUP_SC and FAMILY_WAIT_TIMEOUT via env; fall back to its defaults
export BACKUP_SC FAMILY_WAIT_TIMEOUT="$FULL_TIMEOUT"
if [[ "$VM_OS" == "rhel9-light" ]]; then
  export FULL_DEST_SIZE="${RHEL_LIGHT_FULL_BACKUP_SIZE:-12Gi}" INCR_DEST_SIZE="${RHEL_LIGHT_INCREMENTAL_PVC_SIZE:-2Gi}"
fi
bash "$DRIVER" "$POOL" 1 "$N" "$WAVE" 2>&1 | tee "$EVID/driver.log" | tail -20

bash "$SNAPSHOT" "${POOL}-post-backup" >/dev/null 2>&1 || true

# ---- 6. report ----
SUM="$EVID/summary.txt"
cp "$SCALE_STATE_DIR/scale-50-$POOL/summary.txt" "$SUM" 2>/dev/null || true
printf '\n===== RUN SUMMARY (%s, %s VMs) =====\n' "$POOL" "$N"
cat "$SUM" 2>/dev/null || printf 'summary missing; check %s/driver.log\n' "$EVID"
if [[ -f "$SCALE_STATE_DIR/storage.csv" ]]; then
  printf '\nStorage snapshots:\n'
  grep "$POOL" "$SCALE_STATE_DIR/storage.csv" || true
fi
printf '\nEvidence: %s\n' "$EVID"
