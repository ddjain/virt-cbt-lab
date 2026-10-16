#!/usr/bin/env bash
# Deterministic destination PVC/backup names let the compound trigger-command
# watch for "PVC Bound AND backup actively copying" directly, so krknctl
# starts (and absorbs its own startup latency) before `make e2e TYPE=full`
# ever applies the full-backup manifest.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"

: "${RUN_ID:?Set a unique RUN_ID for this full-backup lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not a valid workflow run ID: %s\n' "$RUN_ID" >&2
  exit 2
fi
for command in oc jq make tee krknctl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
# RHEL 9 always resolves the full-backup PVC to 80Gi regardless of variant
# (scripts/common.sh set_manifest_variant_settings); only the small Debian
# profiles have a destination PVC small enough to reach 95% fill within the
# issue's 120s chaos duration. "odf" (6Gi, ocs-storagecluster-ceph-rbd) is
# used over "default" (5Gi, cbt-demo-hpp) because Ceph RBD enforces PVC
# capacity strictly; HPP's filesystem is a weaker out-of-space guarantee.
# Force-set (not :-): the execution host's .env pre-exports VM_OS=rhel9 and
# MANIFEST_VARIANT=large-odf for the default campaign workload; env-
# conditional defaults never fire once .env exports the variable.
VM_OS="debian"
MANIFEST_VARIANT="odf"
if [[ "$VM_OS" != debian ]]; then
  printf 'CBT-F-08 requires VM_OS=debian; rhel9/windows resolve to an 80Gi+ destination PVC that cannot reach 95%% fill in the chaos window (got: %s)\n' \
    "$VM_OS" >&2
  exit 2
fi
case "$MANIFEST_VARIANT" in
  default | odf) ;;
  large | large-odf)
    printf 'CBT-F-08 targets a small destination PVC; MANIFEST_VARIANT=%s is 40Gi/48Gi. Use "default" or "odf".\n' \
      "$MANIFEST_VARIANT" >&2
    exit 2
    ;;
  *)
    printf 'MANIFEST_VARIANT must be "default" or "odf" for this scenario (got: %s)\n' "$MANIFEST_VARIANT" >&2
    exit 2
    ;;
esac
# Deliberately larger than the repository's small default (8 files, 4-12MiB)
# so there are bytes in flight for the filler to race against, while staying
# under the guest root disk budget (see sizing note below). Starting point
# only -- see scenario-spec.md §3/§7; tune with scripts/monitor.sh if the
# backup finishes before the trigger/fill land.
# Force-set: the execution host's .env pre-exports a much larger GUEST_*
# workload (1000x15-20MiB) that overflows this scenario's 6Gi root disk.
# Env-conditional defaults (:-) never fire once .env exports the variable.
# r03/r04 ENOSPC math (measured on r04): guest root disk vda capacity
# 5,348,786,176 bytes (4.98GiB, manifests/vm-odf.yaml hardcodes 5Gi
# request); ext4 on /dev/rbd7 5.9G total with ~5% reserved blocks;
# Debian OS ~0.3-0.4GiB. Safe payload budget ~3.5GiB; 48x90-96MiB
# (~4.5GiB) hit ENOSPC during baseline init twice.
GUEST_BASE_FILE_COUNT="36"
GUEST_FILE_SIZE_MIN_MIB="96"
GUEST_FILE_SIZE_MAX_MIB="96"
GUEST_INCREMENTAL_FILE_COUNT="4"
GUEST_INCREMENTAL_PASSES="1"
FILL_PERCENTAGE="${FILL_PERCENTAGE:-95}"
FILL_DURATION="${FILL_DURATION:-120}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
TRIGGERS_INTERVAL="${TRIGGERS_INTERVAL:-3}"
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-08/runs/$RUN_ID"

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
  unexpected_observer_content="$(find "$EVIDENCE_DIR/observer" -mindepth 1 \
    \( -name trigger.log -o -name krknctl.log \) -print -quit)"
  if [[ -n "$unexpected_observer_content" ]]; then
    printf 'Run ID %s observer already contains run artifacts; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Run ID %s evidence path is not a directory; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# Fires once the destination PVC is Bound AND the vmbackup is actively
# copying (Progressing=True with Done not yet True). API-only by design:
# the r02 attempt used oc-logs+grep here, which made each trigger check
# take ~60s (only 4 checks in 4 minutes) and the 10s live-copy window was
# unhittable. Progressing stays True for the whole copy, so this check is
# fast (single API read) and holds across the entire window.
# Quoting (proven live on r05 evidence): krkn executes the command string
# through a shell, so every jsonpath containing "(" MUST be single-quoted
# inside the command substitution -- an unquoted paren inside $(...) is a
# shell syntax error, and the whole condition can then never evaluate
# true (r02/r05 both missed the window because of exactly this, not
# timing). Nested double quotes break the command string the same way.
printf -v trigger_command \
  'test "$(oc get pvc %s -n %s -o jsonpath={.status.phase} 2>/dev/null)" = Bound && test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Progressing")].status}'"'"' 2>/dev/null)" = True && test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Done")].status}'"'"' 2>/dev/null)" != True' \
  "$FULL_BACKUP_PVC_NAME" "$NAMESPACE" "$FULL_BACKUP_NAME" "$NAMESPACE" "$FULL_BACKUP_NAME" "$NAMESPACE"

krknctl_log="$EVIDENCE_DIR/krknctl.log"
krknctl run pvc-scenarios \
  --namespace "$NAMESPACE" \
  --pvc-name "$FULL_BACKUP_PVC_NAME" \
  --fill-percentage "$FILL_PERCENTAGE" \
  --duration "$FILL_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krknctl_log" 2>&1 &
krknctl_pid=$!
printf 'krknctl pvc-scenarios started (pid=%s), watching for %s Bound + %s live-copy signal.\n' \
  "$krknctl_pid" "$FULL_BACKUP_PVC_NAME" "$FULL_BACKUP_NAME" >&2

if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi

if wait "$krknctl_pid"; then
  krknctl_status=0
else
  krknctl_status=$?
fi
printf 'E2E exit status: %d; krknctl trigger/injection status: %d (log: %s)\n' \
  "$e2e_status" "$krknctl_status" "$krknctl_log" >&2

oc get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup-pvc.yaml" 2>/dev/null || true
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true

if ((krknctl_status != 0)); then
  printf 'krknctl trigger/injection did not complete successfully; treat as a harness-side gap, not a product verdict, and inspect %s.\n' \
    "$krknctl_log" >&2
  exit "$krknctl_status"
fi

if ((e2e_status == 0)); then
  printf 'E2E TYPE=full exited 0 despite the destination-fill injection; the backup was not interrupted by the fault. Treat this run as INVALID (chaos missed the live-copy window), not a product pass. Re-run with a larger GUEST_BASE_FILE_COUNT/GUEST_FILE_SIZE_MAX_MIB.\n' >&2
  exit 1
fi

printf 'Full-stage exit status: %d (expected nonzero: failed backup detected). Run the same-VM recovery stage: make e2e TYPE=recover VM=%s NAMESPACE=%s KUBECONFIG_PATH=%s\n' \
  "$e2e_status" "$VM_NAME" "$NAMESPACE" "$KUBECONFIG_PATH" >&2

if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  recovery_status=0
else
  recovery_status=$?
fi
printf 'Same-VM recovery status: %d\n' "$recovery_status" >&2
exit "$recovery_status"
