#!/usr/bin/env bash
# EXP-6 (adaptive, WeaknessAnalyst P1): multi-disk silent disk-drop.
# Hypothesis (source-verified kubevirt v1.8.4 = live CNV 4.22.12):
# RedefineCheckpoint probes each disk independently; a disk whose qcow2
# lost the checkpoint bitmap is silently excluded (V(3) log only) and all
# subsequent incrementals complete Done=True WITHOUT that disk — silent
# permanent data-protection loss for the dropped volume.
#
# Legs:
#   leg A (control): 2-disk VM, full + incremental, NO surgery — proves the
#     2-disk harness itself keeps both disks in includedVolumes.
#   leg B (surgery): same setup; after the full, remove the checkpoint
#     bitmap from ONE disk (vdb) via QMP block-dirty-bitmap-remove (verified
#     fail-closed via the dirty-bitmaps array of query-named-block-nodes;
#     this QEMU has no query-block-dirty-bitmap command), restart the VMI
#     (fires the redefinition path), then incremental. FAIL if the incremental
#     is Done=True with vdb missing from includedVolumes and no warning.
# Judge-mandated checks: per-disk restore verification (vdb file written
# pre-full must be present in the cumulative restore — a drop is detectable
# by content, not metadata), QMP bitmap-gone confirmation, redefinition log
# capture (virt-handler/virt-controller logs around VMI start).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set a unique RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not valid: %s\n' "$RUN_ID" >&2; exit 2
fi
for command in oc jq make tee kubectl ssh python3; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
PLAN_MODE=false
for arg in "$@"; do
  case "$arg" in
    --plan) PLAN_MODE=true ;;
    -h|--help)
      printf 'Usage: %s [--plan]\n' "$(basename "${BASH_SOURCE[0]}")"
      printf '  --plan  Resolve the environment, run the read-only collision checks, print the full leg plan, and exit without mutating anything.\n'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s exists locally; refusing to reuse it.\n' "$RUN_ID" >&2; exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  # Team-harness scaffolding (run ledger/state, contracts, per-role output
  # directories) is created by the orchestrating Lead before the trigger runs
  # and is not prior run evidence; ignore exactly those entries. Anything else
  # already present still refuses the run, preserving the collision guard
  # (see tests/test-trigger-plan-rehearsal.sh).
  TEAM_ENTRIES=(observer trigger recovery checkers reports contracts preflight ledger.jsonl state.json evidence-index.json)
  find_args=("$EVIDENCE_DIR" -mindepth 1 -maxdepth 1)
  for team_entry in "${TEAM_ENTRIES[@]}"; do find_args+=(! -name "$team_entry"); done
  existing_evidence="$(find "${find_args[@]}" -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has output; refusing to reuse it (remove it only after confirming no cluster object references it).\n' \
      "$RUN_ID" >&2; exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Run ID %s evidence path is not a directory; refusing to reuse it.\n' "$RUN_ID" >&2; exit 1
fi
VM_NAME="vm-${RUN_ID}"
DV_NAME="vm-disk-${RUN_ID}"
EXTRA_DV_NAME="vm-data-${RUN_ID}"

# Rehearsal mode: resolves the run identity, the target, and the exact stage
# commands from local state only. It contacts no cluster, mutates nothing, and
# creates nothing, so it is safe to run while the observers are still arming.
# The cluster-side collision check is deliberately deferred to the real run.
if [[ "$PLAN_MODE" == true ]]; then
  printf 'PLAN (read-only; contacts no cluster and mutates nothing)\n'
  printf 'RUN_ID: %s (lifecycle run %s, adopted via EXISTING_VM=vm-%s)\n' "$RUN_ID" "$RUN_ID" "$RUN_ID"
  printf '  namespace=%s kubeconfig=%s vm_os=%s manifest_variant=%s\n' \
    "$NAMESPACE" "$KUBECONFIG_PATH" "$VM_OS" "$MANIFEST_VARIANT"
  printf '  local precondition check: clear (lifecycle dir absent, evidence dir holds only team-harness entries and an observer dir)\n'
  printf '  cluster collision check: deferred to the run (plan mode contacts no cluster)\n'
  printf '  VM=%s rootdisk-DV=%s datadisk-DV=%s ssh-service=%s\n' \
    "$VM_NAME" "$DV_NAME" "$EXTRA_DV_NAME" "vm-ssh-$RUN_ID"
  printf '  tracker=vm-tracker-%s full-backup=vm-backup-%s incremental-pass-1=vm-incremental-%s-p01\n' \
    "$RUN_ID" "$RUN_ID" "$RUN_ID"
  printf '  evidence dir=%s (trigger artifacts under trigger/)\n' "$EVIDENCE_DIR"
  printf '  workload: %s baseline files of %s-%s MiB, %s incremental files\n' \
    "$GUEST_BASE_FILE_COUNT" "$GUEST_FILE_SIZE_MIN_MIB" "$GUEST_FILE_SIZE_MAX_MIB" "$GUEST_INCREMENTAL_FILE_COUNT"
  printf '  stage command 1: make e2e TYPE=full EXISTING_VM=%s NAMESPACE=%s MANIFEST_VARIANT=%s (adopt + baseline workload + full backup)\n' \
    "$VM_NAME" "$NAMESPACE" "$MANIFEST_VARIANT"
  printf '  stage command 2: make e2e TYPE=incremental VM=%s NAMESPACE=%s MANIFEST_VARIANT=%s (surgery incremental + final-pass verification)\n' \
    "$VM_NAME" "$NAMESPACE" "$MANIFEST_VARIANT"
  printf '  leg A (control): apply %s -> wait VMI Running + CBT Enabled -> stage command 1 -> assert includedVolumes contains rootdisk AND datadisk\n' \
    "vm-2disk.yaml"
  printf '  leg B (surgery): tracker latestCheckpoint -> QMP query-named-block-nodes (select the unique /cbt/datadisk.qcow2 node whose node-name ends -format; its dirty-bitmaps array MUST contain that checkpoint with recording=true; fail-closed) -> block-dirty-bitmap-remove -> re-query (bitmap MUST be gone; fail-closed) -> oc delete vmi %s -> wait Running + CBT Enabled -> stage command 2 -> classify includedVolumes\n' \
    "$VM_NAME"
  printf '  gates: observer-ready-file + live-PID check before the QMP removal and again before the VMI delete; run-scoped VM/VMI identity check before both\n'
  exit 0
fi

existing="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume -n "$NAMESPACE" -o name 2>/dev/null || true)"
if [[ "$existing" == *"$RUN_ID"* ]]; then
  printf 'Cluster resources for %s exist; refusing.\n' "$RUN_ID" >&2; exit 1
fi
mkdir -p "$EVIDENCE_DIR" "$EVIDENCE_DIR/trigger"
TRIGGER_DIR="$EVIDENCE_DIR/trigger"
exec > >(tee -a "$TRIGGER_DIR/trigger.log") 2>&1

launcher_pod() {
  oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=vm-${1}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

virsh() {
  local run_id="$1"; shift
  local pod; pod="$(launcher_pod "$run_id")"
  [[ -n "$pod" ]] || { printf 'no launcher pod for %s\n' "$run_id" >&2; return 1; }
  kubectl exec -n "$NAMESPACE" "$pod" -c compute -- virsh "$@"
}

# ---------- Fail-closed gates (trigger hardening; Lead-approved 2026-10-16) ----------
# Both mutations (the QMP bitmap removal and the VMI delete) are refused unless
# the Observer Worker's watches are verifiably live and the target is the exact
# run-scoped VM/VMI. Never infer an armed observer from a marker alone.
require_observer_armed() {
  local stage="$1" armed="$EVIDENCE_DIR/observer/ARMED"
  local -a ready_files=() missing=() dead=()
  local ready_file watch_pid
  if [[ ! -s "$armed" ]]; then
    printf 'OBSERVER GATE (%s): %s missing or empty; refusing to act.\n' "$stage" "$armed" >&2
    return 1
  fi
  if ! jq -e . "$armed" >/dev/null 2>&1; then
    printf 'OBSERVER GATE (%s): %s is not valid JSON; refusing to act.\n' "$stage" "$armed" >&2
    return 1
  fi
  mapfile -t ready_files < <(jq -r '.required_ready_files[]? // empty' "$armed" 2>/dev/null)
  shopt -s nullglob
  local -a glob_ready=("$EVIDENCE_DIR/observer/watches/"*.ready)
  shopt -u nullglob
  if ((${#glob_ready[@]})); then ready_files+=("${glob_ready[@]}"); fi
  # The ARMED list and the watches glob overlap by design; count each unique
  # ready file once (r02 logged "14 ready file(s)" for 7 watches).
  if ((${#ready_files[@]})); then
    mapfile -t ready_files < <(printf '%s\n' "${ready_files[@]}" | LC_ALL=C sort -u)
  fi
  if ((${#ready_files[@]} == 0)); then
    printf 'OBSERVER GATE (%s): ARMED lists no ready file and none exist; refusing to act.\n' "$stage" >&2
    return 1
  fi
  for ready_file in "${ready_files[@]}"; do
    if [[ ! -s "$ready_file" ]]; then missing+=("$ready_file"); continue; fi
    watch_pid="$(sed -n 's/^watch_pid=//p' "$ready_file" | tail -n1)"
    if [[ -z "$watch_pid" ]] || ! kill -0 "$watch_pid" 2>/dev/null; then dead+=("$ready_file"); fi
  done
  if ((${#missing[@]})) || ((${#dead[@]})); then
    printf 'OBSERVER GATE (%s): watch health check FAILED; refusing to act.\n' "$stage" >&2
    ((${#missing[@]})) && printf '  missing/empty ready files: %s\n' "${missing[*]}" >&2
    ((${#dead[@]})) && printf '  dead or unreadable watch PIDs: %s\n' "${dead[*]}" >&2
    return 1
  fi
  printf 'OBSERVER GATE (%s): %s ready file(s) verified live via %s.\n' "$stage" "${#ready_files[@]}" "$armed" >&2
  return 0
}

require_target_identity() {
  local stage="$1" vm_json vmi_json vm_uid vmi_owner_uid label_run_id label_managed_by
  if ! vm_json="$(oc get vm "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null)"; then
    printf 'TARGET GATE (%s): VM %s not readable; refusing to act.\n' "$stage" "$VM_NAME" >&2
    return 1
  fi
  vm_uid="$(jq -r '.metadata.uid // empty' <<<"$vm_json")"
  label_run_id="$(jq -r '.metadata.labels["virt-cbt-lab/run-id"] // empty' <<<"$vm_json")"
  label_managed_by="$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // empty' <<<"$vm_json")"
  if [[ -z "$vm_uid" || "$label_run_id" != "$RUN_ID" || "$label_managed_by" != "virt-cbt-lab" ]]; then
    printf 'TARGET GATE (%s): VM %s is not the run-scoped target (uid=%s run-id=%s managed-by=%s); refusing to act.\n' \
      "$stage" "$VM_NAME" "${vm_uid:-none}" "${label_run_id:-none}" "${label_managed_by:-none}" >&2
    return 1
  fi
  if ! vmi_json="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null)"; then
    printf 'TARGET GATE (%s): VMI %s not readable; refusing to act.\n' "$stage" "$VM_NAME" >&2
    return 1
  fi
  vmi_owner_uid="$(jq -r '.metadata.ownerReferences[0].uid // empty' <<<"$vmi_json")"
  if [[ "$vmi_owner_uid" != "$vm_uid" ]]; then
    printf 'TARGET GATE (%s): VMI %s is not owned by VM uid %s (owner uid=%s); refusing to act.\n' \
      "$stage" "$VM_NAME" "$vm_uid" "${vmi_owner_uid:-none}" >&2
    return 1
  fi
  printf 'TARGET GATE (%s): VM uid=%s, VMI owned by it, run-id=%s verified.\n' \
    "$stage" "$vm_uid" "$label_run_id" >&2
  return 0
}

# ---------- Stage 1: 2-disk VM via templated manifest + workflow bookkeeping
# (VM_NAME/DV_NAME/EXTRA_DV_NAME are resolved above, before plan mode.)
printf 'Creating 2-disk VM %s (rootdisk + datadisk/vdb).\n' "$VM_NAME" >&2
source "$ROOT_DIR/scripts/common.sh"
# Reuse the workflow's parameter resolution for the templated fields.
DATA_SOURCE_NAME="$(oc get datasource -n openshift-virtualization-os-images rhel9 -o jsonpath='{.metadata.name}' 2>/dev/null || echo rhel9)"
DATA_SOURCE_NS="openshift-virtualization-os-images"
SSH_PUB_KEY="$(cat "$GUEST_KEY.pub")"
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__DV_NAME__|$DV_NAME|g" \
  -e "s|__EXTRA_DV_NAME__|$EXTRA_DV_NAME|g" \
  -e "s|__DATA_SOURCE_NAME__|$DATA_SOURCE_NAME|g" \
  -e "s|__DATA_SOURCE_NAMESPACE__|$DATA_SOURCE_NS|g" \
  -e "s|__GUEST_CLOUD_INIT_PACKAGE_UPDATE__|false|g" \
  -e "s|__GUEST_CLOUD_INIT_PACKAGES__|[]|g" \
  -e "s|__GUEST_SSHD_SERVICE__|sshd|g" \
  -e "s|__GUEST_LINUX_GROUP__|wheel|g" \
  -e "s|__SSH_PUBLIC_KEY__|$SSH_PUB_KEY|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  -e "s|__SSH_SERVICE__|vm-ssh-${RUN_ID}|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  "$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml" \
  | kubectl apply -f - >/dev/null
printf 'VM manifest applied; waiting for VMI Running + CBT Enabled.\n' >&2
deadline=$(( $(date -u +%s) + 900 ))
while :; do
  phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  cbt="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
  [[ "$phase" == Running && "$cbt" == Enabled ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'VMI did not reach Running+CBT-Enabled in 900s (phase=%s cbt=%s).\n' "${phase:-?}" "${cbt:-?}" >&2
    exit 5
  fi
  sleep 5
done
printf '2-disk VMI Running with CBT Enabled.\n' >&2
# Verify both disks present in the domain.
virsh "$RUN_ID" domblklist "$(printf 'vm-cbt-demo_%s' "$VM_NAME" | tr '[:lower:]' '[:lower:]')" || true
printf '=== Domain block list above (expect vda rootdisk + vdb datadisk). ===\n' >&2
# Write a marker file on vdb via the guest (ssh service may not exist yet —
# create the baseline workload through the workflow's vm-setup instead).
# For bookkeeping compatibility with make e2e verify, register the run.
# NOTE: full workflow run.json is produced by vm-backup below.

# Fail-closed capacity floor on the filesystem that backs the PVCs, measured
# where they live (never the pool's parent hostPath). A run that cannot afford
# its own full pass cannot answer its own question.
POOL_DATA_DIR="/cbt-demo-pool-data-dir/csi"
POOL_FLOOR_GIB="${POOL_FLOOR_GIB:-100}"   # this scenario needs ~100 GiB for a fresh full
pool_free_gib() {
  local pod
  pod="$(oc get pods -n openshift-cnv -o name 2>/dev/null | grep hostpath-provisioner-csi | head -1 | cut -d/ -f2)"
  [[ -n "$pod" ]] || return 1
  oc exec -n openshift-cnv "$pod" -c hostpath-provisioner -- df -B1 "$POOL_DATA_DIR" 2>/dev/null |
    tail -1 | awk -v f="$POOL_FLOOR_GIB" '{printf "%d", $4/1024/1024/1024}'
}
free_now_gib="$(pool_free_gib || echo 0)"
printf 'Pool filesystem %s has %s GiB free (floor %s GiB).\n' "$POOL_DATA_DIR" "$free_now_gib" "$POOL_FLOOR_GIB" >&2
if (( free_now_gib < POOL_FLOOR_GIB )); then
  printf 'FAIL-CLOSED: pool free %s GiB < floor %s GiB; refusing to start.\n' "$free_now_gib" "$POOL_FLOOR_GIB" >&2
  exit 8
fi

# ---------- Stage 2: control leg (no surgery): full + incremental ----------
printf '=== LEG A (control): full + incremental on 2-disk VM, no surgery ===\n' >&2
# The workflow's vm-setup would recreate the VM; instead drive backup directly.
# Create run bookkeeping via vm_info_initialize equivalent: run `make vm-backup`
# needs run.json; simplest compatible path: use e2e TYPE=full with EXISTING_VM.
# EXISTING_VM requires no runs/<id> dir yet — true. It adopts our VM.
if make e2e TYPE=full EXISTING_VM="$VM_NAME" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  control_full_status=0
else
  control_full_status=$?
fi
printf 'Leg A full+incremental+verify status: %d\n' "$control_full_status" >&2
oc get vmbackup "vm-backup-$RUN_ID" -n "$NAMESPACE" -o yaml \
  >"$TRIGGER_DIR/legA-full-backup.yaml" 2>/dev/null || true
if ((control_full_status != 0)); then
  printf 'Control leg failed — 2-disk harness issue; aborting before surgery.\n' >&2
  exit "$control_full_status"
fi
# Record the full backup's included volumes (must contain BOTH disks).
control_volumes="$(oc get vmbackup "vm-backup-$RUN_ID" -n "$NAMESPACE" \
  -o jsonpath='{.status.includedVolumes[*].volumeName}' 2>/dev/null || true)"
printf 'CONTROL full backup includedVolumes: %s\n' "$control_volumes" >&2
if [[ "$control_volumes" != *rootdisk* || "$control_volumes" != *datadisk* ]]; then
  printf 'CONTROL DEFECT SIGNAL: full backup missing a disk (%s).\n' "$control_volumes" >&2
fi

# ---------- Stage 3: surgery leg — remove vdb's checkpoint bitmap ----------
printf '=== LEG B (surgery): remove vdb checkpoint bitmap, restart, incremental ===\n' >&2
CHECKPOINT_NAME="$(oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
if [[ -z "$CHECKPOINT_NAME" ]]; then
  printf 'No checkpoint on tracker; cannot proceed with surgery.\n' >&2
  exit 5
fi
printf 'Surgery target: checkpoint %s on disk vdb.\n' "$CHECKPOINT_NAME" >&2
# Snapshot the tracker after the control full and before the surgery, so the
# post-redefinition tracker state can be compared against the pre-surgery one.
oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" -o yaml \
  >"$TRIGGER_DIR/tracker-before-restart.yaml" 2>/dev/null || true
# Fail-closed gates: the surgery is refused unless the read-only observer
# watches are live and the target really is this run's VM/VMI.
require_observer_armed "pre-surgery" || exit 7
require_target_identity "pre-surgery" || exit 7
DOM="vm-cbt-demo_${VM_NAME}"
# Find vdb's QEMU node name via query-named-block-nodes.
LAUNCHER="$(launcher_pod "$RUN_ID")"
NODES_JSON_BEFORE="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" '{"execute":"query-named-block-nodes"}' 2>/dev/null || true)"
printf '%s\n' "$NODES_JSON_BEFORE" >"$TRIGGER_DIR/query-named-block-nodes-before.json"
# The CBT overlay for the datadisk ends /cbt/datadisk.qcow2; the raw backing
# .../vmi-disks/datadisk/disk.img must NOT be selected. libvirt exposes that
# file through two nodes (…-format carries the dirty bitmaps, …-storage is the
# protocol child), so require exactly one …/cbt/datadisk.qcow2 node whose
# node-name ends in -format and refuse anything ambiguous (fail-closed).
VDB_NODE="$(printf '%s' "$NODES_JSON_BEFORE" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cands = [n for n in d.get('return',[])
         if n.get('file','').endswith('/cbt/datadisk.qcow2')
         and n.get('node-name','').endswith('-format')]
if len(cands) == 1:
    print(cands[0]['node-name'])
" 2>/dev/null || true)"
if [[ -z "$VDB_NODE" ]]; then
  printf 'Could not resolve a unique vdb CBT-overlay (-format) node; aborting surgery leg (fail-closed).\n' >&2
  printf 'Candidate datadisk nodes:\n' >&2
  printf '%s' "$NODES_JSON_BEFORE" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('  (query-named-block-nodes returned unparsable output)'); sys.exit(0)
for n in d.get('return',[]):
    f = n.get('file','')
    if 'datadisk' in f or 'datadisk' in n.get('node-name',''):
        print('  node-name=%s file=%s bitmaps=%d' % (n.get('node-name',''), f, len(n.get('dirty-bitmaps',[]))))
" 2>/dev/null || true
  exit 6
fi
printf 'vdb QEMU node: %s\n' "$VDB_NODE" >&2

# Bitmap inventory of the target node. This QEMU does not implement
# query-block-dirty-bitmap (verified: QMP query-commands lists only
# block-dirty-bitmap-{add,clear,disable,enable,merge,remove}); the durable way
# to list a node's bitmaps is the dirty-bitmaps array of
# query-named-block-nodes. A query that cannot be parsed is fail-closed, never
# a pass.
bitmaps_json_for_node() {
  local node="$1"
  printf '%s' "$NODES_JSON_BEFORE" | python3 -c "
import json,sys
node = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for n in d.get('return',[]):
    if n.get('node-name') == node:
        print(json.dumps(n.get('dirty-bitmaps', [])))
        sys.exit(0)
sys.exit(4)
" "$node"
}
BITMAPS_BEFORE="$(bitmaps_json_for_node "$VDB_NODE")" || {
  printf 'FAIL-CLOSED: could not read the datadisk node bitmap list before surgery.\n' >&2; exit 6; }
printf '%s\n' "$BITMAPS_BEFORE" >"$TRIGGER_DIR/bitmaps-before.json"
if ! printf '%s' "$BITMAPS_BEFORE" | jq -e --arg name "$CHECKPOINT_NAME" \
     '.[]? | select(.name == $name and .recording == true)' >/dev/null 2>&1; then
  printf 'FAIL-CLOSED: checkpoint bitmap %s is not present+recording on vdb before surgery (bitmaps: %s).\n' \
    "$CHECKPOINT_NAME" "$(printf '%s' "$BITMAPS_BEFORE" | jq -c '[.[]?.name]' 2>/dev/null || echo '?')" >&2
  exit 6
fi
# Publish the resolved surgery target so the observer can resolve the same
# checkpoint/node before the removal, without waiting for the tracker's (later)
# projection, and block the removal until the observer's own pre-read exists.
printf '{"utc":"%s","checkpoint":"%s","disk":"datadisk","qemu_node":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CHECKPOINT_NAME" "$VDB_NODE" \
  >"$TRIGGER_DIR/surgery-target.json"

WITNESS_MAX_AGE_SECONDS=60
WITNESS_WAIT_SECONDS=120

require_pre_state_witness() {
  local ready="$EVIDENCE_DIR/observer/effect/PRE-READY"
  local pre="$EVIDENCE_DIR/observer/effect/qmp-bitmaps-pre.json"
  local deadline=$(( $(date -u +%s) + WITNESS_WAIT_SECONDS ))
  local captured captured_s
  while :; do
    if [[ -s "$ready" && -s "$pre" ]] &&
       jq -e --arg name "$CHECKPOINT_NAME" '.[]? | select(.name == $name)' "$pre" >/dev/null 2>&1; then
      captured="$(tr -d '\n' < "$ready")"
      captured_s="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$captured" +%s 2>/dev/null || true)"
      if [[ -n "$captured_s" ]] && (( $(date -u +%s) - captured_s <= WITNESS_MAX_AGE_SECONDS )); then
        printf 'PRE-STATE WITNESS: observer read %s at %s (age %ss, checkpoint %s).\n' \
          "$pre" "$captured" "$(( $(date -u +%s) - captured_s ))" "$CHECKPOINT_NAME" >&2
        return 0
      fi
    fi
    if (( $(date -u +%s) >= deadline )); then
      printf 'FAIL-CLOSED: no observer pre-state witness for %s within %ss (wanted %s naming %s); refusing to remove the bitmap.\n' \
        "$CHECKPOINT_NAME" "$WITNESS_WAIT_SECONDS" "$ready" "$pre" >&2
      return 1
    fi
    sleep 1
  done
}

require_pre_state_witness || exit 7
printf 'Bitmap %s confirmed on vdb. Removing (QMP block-dirty-bitmap-remove).\n' "$CHECKPOINT_NAME" >&2
REMOVE_RESULT="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" \
  "{\"execute\":\"block-dirty-bitmap-remove\",\"arguments\":{\"node\":\"$VDB_NODE\",\"name\":\"$CHECKPOINT_NAME\"}}" 2>&1 || true)"
printf '%s\n' "$REMOVE_RESULT" >>"$TRIGGER_DIR/qmp-remove-result.txt"
if ! printf '%s' "$REMOVE_RESULT" | jq -e '.return == {} or .return == null' >/dev/null 2>&1; then
  printf 'FAIL-CLOSED: block-dirty-bitmap-remove did not return success: %s\n' "$REMOVE_RESULT" >&2
  exit 6
fi
# Verify the bitmap is GONE (fail-closed), via the same query-named-block-nodes
# inventory used for the before-state.
NODES_JSON_AFTER="$(kubectl exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh qemu-monitor-command "$DOM" '{"execute":"query-named-block-nodes"}' 2>/dev/null || true)"
printf '%s\n' "$NODES_JSON_AFTER" >"$TRIGGER_DIR/query-named-block-nodes-after.json"
BITMAPS_AFTER="$(printf '%s' "$NODES_JSON_AFTER" | python3 -c "
import json,sys
node = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for n in d.get('return',[]):
    if n.get('node-name') == node:
        print(json.dumps(n.get('dirty-bitmaps', [])))
        sys.exit(0)
sys.exit(4)
" "$VDB_NODE")" || BITMAPS_AFTER=""
if [[ -z "$BITMAPS_AFTER" ]]; then
  printf 'FAIL-CLOSED: could not read the datadisk node bitmap list after removal.\n' >&2
  exit 6
fi
printf '%s\n' "$BITMAPS_AFTER" >"$TRIGGER_DIR/bitmaps-after.json"
if printf '%s' "$BITMAPS_AFTER" | jq -e --arg name "$CHECKPOINT_NAME" \
     '.[]? | select(.name == $name)' >/dev/null 2>&1; then
  printf 'FAIL-CLOSED: bitmap %s still present after removal; aborting.\n' "$CHECKPOINT_NAME" >&2
  exit 6
fi
printf 'Bitmap removal VERIFIED on vdb (%s).\n' "$CHECKPOINT_NAME" >&2

# ---------- Stage 4: hard restart (fires checkpoint redefinition) ----------
# Second fail-closed gate: re-check observer health and target identity at the
# injection boundary, then record the UTC action request with the exact target
# identity before the mutation.
require_observer_armed "pre-vmi-restart" || exit 7
require_target_identity "pre-vmi-restart" || exit 7
OLD_UID="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
VM_UID="$(oc get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
OLD_LAUNCHER="$(launcher_pod "$RUN_ID")"
OLD_LAUNCHER_UID="$(oc get pod "$OLD_LAUNCHER" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
restart_requested="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -nc \
  --arg utc "$restart_requested" --arg run_id "$RUN_ID" --arg namespace "$NAMESPACE" \
  --arg vm "$VM_NAME" --arg vm_uid "$VM_UID" --arg vmi "$VM_NAME" --arg vmi_uid "$OLD_UID" \
  --arg launcher_pod "$OLD_LAUNCHER" --arg launcher_pod_uid "$OLD_LAUNCHER_UID" \
  --arg checkpoint "$CHECKPOINT_NAME" --arg disk "datadisk" --arg qmp_node "$VDB_NODE" \
  --arg bitmaps_before "$TRIGGER_DIR/bitmaps-before.json" \
  --arg bitmaps_after "$TRIGGER_DIR/bitmaps-after.json" \
  --arg qmp_result "$TRIGGER_DIR/qmp-remove-result.txt" \
  '{utc_action_request: $utc, run_id: $run_id, namespace: $namespace,
    action: "oc delete vmi (hard restart to fire checkpoint redefinition)",
    surgery: "QMP block-dirty-bitmap-remove on the datadisk checkpoint bitmap",
    window: "after the control full backup reached a terminal Done condition, before the incremental backup object is created",
    observed_signal: "tracker latestCheckpoint resolved after the control full; checkpoint bitmap confirmed present on the datadisk QEMU node before removal and absent after",
    target: {kind: "VirtualMachineInstance", name: $vmi, uid: $vmi_uid},
    vm: {name: $vm, uid: $vm_uid},
    launcher_pod: {name: $launcher_pod, uid: $launcher_pod_uid},
    surgery_target: {disk: $disk, checkpoint: $checkpoint, qemu_node: $qmp_node},
    evidence: {bitmaps_before: $bitmaps_before, bitmaps_after: $bitmaps_after, qmp_remove_result: $qmp_result}}' \
  >"$TRIGGER_DIR/action-request.json"
printf 'UTC action request: delete VMI %s (uid %s) at %s (redefinition with vdb bitmap missing).\n' \
  "$VM_NAME" "$OLD_UID" "$restart_requested" >&2
oc delete vmi "$VM_NAME" -n "$NAMESPACE"
deadline=$(( $(date -u +%s) + 900 ))
while :; do
  new_uid="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ -n "$new_uid" && "$new_uid" != "$OLD_UID" && "$phase" == Running ]]; then break; fi
  if (( $(date -u +%s) > deadline )); then
    printf 'VMI did not restart in 900s.\n' >&2; exit 5
  fi
  sleep 3
done
printf 'VMI restarted (uid %s). Waiting for CBT Enabled.\n' "$new_uid" >&2
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  cbt="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}' 2>/dev/null || true)"
  [[ "$cbt" == Enabled ]] && break
  if (( $(date -u +%s) > deadline )); then
    printf 'CBT not Enabled after restart (state=%s).\n' "${cbt:-?}" >&2; break
  fi
  sleep 3
done
# Capture tracker state + redefinition evidence.
oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" -o yaml \
  >"$TRIGGER_DIR/tracker-after-restart.yaml" 2>/dev/null || true
TRACKER_VOLUMES="$(oc get vmbackuptracker "vm-tracker-$RUN_ID" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.volumes[*].volumeName}' 2>/dev/null || true)"
printf 'Tracker latestCheckpoint volumes after redefinition: %s\n' "${TRACKER_VOLUMES:-none}" >&2
# Effect check: the old VMI/pod UID is gone and a replacement launcher is Ready.
NEW_LAUNCHER="$(launcher_pod "$RUN_ID")"
NEW_LAUNCHER_UID="$(oc get pod "$NEW_LAUNCHER" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
if oc get pod "$OLD_LAUNCHER" -n "$NAMESPACE" >/dev/null 2>&1; then old_pod_gone=false; else old_pod_gone=true; fi
if oc get pod "$NEW_LAUNCHER" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
  new_pod_ready=true
else new_pod_ready=false; fi
jq -nc \
  --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run_id "$RUN_ID" \
  --arg old_vmi_uid "$OLD_UID" --arg new_vmi_uid "$new_uid" \
  --arg old_pod "$OLD_LAUNCHER" --arg old_pod_uid "$OLD_LAUNCHER_UID" \
  --arg new_pod "$NEW_LAUNCHER" --arg new_pod_uid "$NEW_LAUNCHER_UID" \
  --argjson old_pod_gone "$old_pod_gone" --argjson new_pod_ready "$new_pod_ready" \
  --arg cbt "$cbt" --arg tracker_volumes "${TRACKER_VOLUMES:-}" \
  '{utc_effect_observed: $utc, run_id: $run_id,
    old_pod: {name: $old_pod, uid: $old_pod_uid}, old_pod_uid: $old_pod_uid, old_pod_gone: $old_pod_gone,
    replacement_pod: {name: $new_pod, uid: $new_pod_uid, ready: $new_pod_ready},
    old_vmi_uid: $old_vmi_uid, new_vmi_uid: $new_vmi_uid,
    cbt_state_after_restart: $cbt, tracker_volumes_after_redefinition: $tracker_volumes}' \
  >"$TRIGGER_DIR/effect-check.json"
printf 'Effect check: old pod %s gone=%s; replacement %s ready=%s; VMI %s -> %s.\n' \
  "$OLD_LAUNCHER" "$old_pod_gone" "${NEW_LAUNCHER:-none}" "$new_pod_ready" "$OLD_UID" "$new_uid" >&2
# Controller log window around the restart (redefinition evidence).
LEADER="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$LEADER" -n openshift-cnv --since=5m >"$TRIGGER_DIR/controller-redefinition-window.log" 2>/dev/null || true
# virt-handler log window for the same period: the redefinition V(3) line that
# reports a per-disk drop is emitted by the node-side handler.
oc logs -n openshift-cnv -l kubevirt.io=virt-handler --tail=-1 --since=5m \
  >"$TRIGGER_DIR/virt-handler-redefinition-window.log" 2>/dev/null || true

# ---------- Stage 5: incremental on the redefined checkpoint ----------
printf 'Running incremental pass on the redefined chain.\n' >&2
# The affected pass must end in a recorded outcome. The workflow's own bound is
# the only bound there is (`scripts/common.sh:1037,1046` --timeout=20m), so the
# trigger measures the stage against it and records whether the object ever
# reached a terminal condition.
PASS_WAIT_BOUND_SECONDS=1200
incr_started_s="$(date -u +%s)"
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
incr_waited_s=$(( $(date -u +%s) - incr_started_s ))
printf 'Surgery-leg incremental status: %d\n' "$incr_status" >&2
INCR_NAME="vm-incremental-${RUN_ID}-p01"
incr_volumes="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.includedVolumes[*].volumeName}' 2>/dev/null || true)"
incr_done="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
incr_type="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.type}' 2>/dev/null || true)"
printf 'SURGERY INCREMENTAL RESULT: type=%s Done=%s includedVolumes=%s\n' \
  "${incr_type:-?}" "${incr_done:-?}" "${incr_volumes:-?}" >&2
oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" -o yaml \
  >"$TRIGGER_DIR/legB-incremental-backup.yaml" 2>/dev/null || true
incr_message="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].message}' 2>/dev/null || true)"
incr_reason="$(oc get vmbackup "$INCR_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
jq -nc \
  --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run_id "$RUN_ID" \
  --arg checkpoint "$CHECKPOINT_NAME" --arg control_volumes "$control_volumes" \
  --argjson control_status "$control_full_status" \
  --arg incr_name "$INCR_NAME" --arg incr_type "${incr_type:-}" --arg incr_done "${incr_done:-}" \
  --arg incr_reason "${incr_reason:-}" --arg incr_message "${incr_message:-}" \
  --arg incr_volumes "$incr_volumes" --arg tracker_volumes "${TRACKER_VOLUMES:-}" \
  --argjson status "$incr_status" --argjson waited "$incr_waited_s" \
  --argjson bound "$PASS_WAIT_BOUND_SECONDS" \
  '{utc_result_recorded: $utc, run_id: $run_id, checkpoint: $checkpoint,
    control_full_included_volumes: $control_volumes,
    control_full_status: $control_status,
    pass_wait_bound_seconds: $bound,
    surgery_incremental: {name: $incr_name, status: $status, type: $incr_type, done: $incr_done,
      reason: $incr_reason, message: $incr_message, included_volumes: $incr_volumes,
      terminal: (($incr_done == "True") or ($incr_done == "False")), waited_seconds: $waited},
    tracker_volumes_after_redefinition: $tracker_volumes}' \
  >"$TRIGGER_DIR/exit-statuses.json"
if [[ "$incr_done" == True && "$incr_type" == Incremental ]]; then
  if [[ "$incr_volumes" != *datadisk* ]]; then
    printf 'DEFECT CONFIRMED: incremental Done=True WITHOUT datadisk (silent disk drop) — includedVolumes=%s\n' \
      "$incr_volumes" >&2
  elif [[ "$incr_volumes" == *datadisk* && "$incr_volumes" == *rootdisk* ]]; then
    printf 'RESILIENT: incremental still includes both disks (%s).\n' "$incr_volumes" >&2
  fi
elif [[ "$incr_done" != "True" && "$incr_done" != "False" ]]; then
  if (( incr_waited_s >= PASS_WAIT_BOUND_SECONDS )); then
    printf 'STALLED NON-TERMINAL: %s had no terminal condition after %ss (bound %ss); type=%s done=%s includedVolumes=%s — recorded as an outcome, not a timeout.\n' \
      "$INCR_NAME" "$incr_waited_s" "$PASS_WAIT_BOUND_SECONDS" "${incr_type:-?}" "${incr_done:-?}" "${incr_volumes:-?}" >&2
  else
    printf 'NON-TERMINAL (inside the wait bound): %s type=%s done=%s\n' \
      "$INCR_NAME" "${incr_type:-?}" "${incr_done:-?}" >&2
  fi
fi
if ((incr_status != 0)); then
  printf 'Incremental failed (status %d) — could be the detected-and-failed path (resilient) or a wedge; evidence preserved.\n' "$incr_status" >&2
fi
printf 'EXP-6 complete. Classification above; per-disk restore grading in the report.\n' >&2
exit 0
