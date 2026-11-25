#!/usr/bin/env bash
set -euo pipefail
# Poll-based parallel CBT backup driver for a density pool.
# Phases: A baseline workload (SSH waves) → B all full backups at once (poll-wait)
#         → C incremental workload → D all incremental backups (poll-wait) + tracker check.
# Fully restartable: every phase skips work already done (idempotent markers in logs).
# Exits nonzero if any VM fails the final tally — callers can rely on exit status.
# Usage: scale-driver2.sh <pool-id> <start-N> <end-N> [ssh-wave]
# Requires: KUBECONFIG, GUEST_KEY, NAMESPACE, manifests in the repo checkout.

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=cbt-scale/lib-naming.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-naming.sh"
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"
POOL="${1:-}"
START_N="${2:-}"
END_N="${3:-}"
if [[ -n "${GROUP_FILE:-}" && -n "${GROUP_ID:-}" ]]; then
  # GROUP MODE: explicit VM list from the fleet group manifest (one VM per
  # line: vm<TAB>state<TAB>full<TAB>incr<TAB>result). Backup objects are
  # named <group-id>-<vm>; VMs/Services carry their real fleet names.
  mapfile -t GROUP_VMS < <(tail -n +2 "$GROUP_FILE" | cut -f1)
  (( ${#GROUP_VMS[@]} > 0 )) || { echo "GROUP_FILE $GROUP_FILE has no VMs" >&2; exit 2; }
elif [[ -z "$POOL" || -z "$START_N" || -z "$END_N" ]]; then
  echo "usage: scale-driver2.sh <pool-id> <start-N> <end-N> [ssh-wave] (or GROUP_FILE+GROUP_ID envs)" >&2
  exit 2
fi
WAVE="${4:-25}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
GUEST_KEY="${GUEST_KEY:-$ROOT_DIR/keys/id_ed25519}"
BACKUP_SC="${BACKUP_SC:-ocs-storagecluster-ceph-rbd}"
FULL_DEST_SIZE="${FULL_DEST_SIZE:-90Gi}"
INCR_DEST_SIZE="${INCR_DEST_SIZE:-30Gi}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$SCALE_STATE_DIR/scale-50-$POOL}"
GUEST_USER="cbt-demo"
WORKLOAD_DIR="/home/$GUEST_USER/cbt-workload"
BASE_COUNT=8
INCR_COUNT=4
SIZE_MIN_MIB=4
SIZE_MAX_MIB=12
LOG_DIR="$EVIDENCE_DIR/logs"
mkdir -p "$LOG_DIR"

rid_for() { printf '%s-%04d' "$POOL" "$1"; }
logf() { printf '%s/%s.log' "$LOG_DIR" "$1"; }
note() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$1" >> "$2"; }
reason_is_failure() { [[ "$1" == "Backup has failed"* ]]; }

# iterate the VM set: numeric mode yields <pool>-NNNN rids, group mode yields
# the manifest VM names (used both as VM/service names and as object ids).
each_vm() {  # emits "rid<TAB>logname" per VM
  if [[ -n "${GROUP_FILE:-}" ]]; then
    local vm; for vm in "${GROUP_VMS[@]}"; do printf '%s\t%s\n' "$(scale_rid "$vm")" "$vm"; done
  else
    local n; for ((n = START_N; n <= END_N; n++)); do
      printf '%s\t%s\n' "$(rid_for "$n")" "$(rid_for "$n")"
    done
  fi
}
# object id for a rid: group mode scopes it to the group (lib-naming.sh)
obj_for() { if [[ -n "${GROUP_FILE:-}" ]]; then scale_obj_id "$GROUP_ID" "$1"; else echo "$1"; fi; }

file_size_bytes() {
  local path="$1" digest hash_word value span size_mib
  digest="$(printf 'cbt-workload-size-v1:%s' "$path" | sha256sum | awk '{print $1}')"
  hash_word="${digest:0:8}"
  value=$((16#$hash_word))
  span=$((SIZE_MAX_MIB - SIZE_MIN_MIB + 1))
  size_mib=$((SIZE_MIN_MIB + value % span))
  printf '%s' "$((size_mib * 1048576))"
}

baseline_items=""
for i in $(seq 1 "$BASE_COUNT"); do
  n=$(printf 'base-%06d.dat' "$i")
  baseline_items+="'$n|$(file_size_bytes "$n")' "
done
incr_items=""
for i in $(seq 1 "$INCR_COUNT"); do
  n=$(printf 'incremental-01-%06d.dat' "$i")
  incr_items+="'$n|$(file_size_bytes "$n")' "
done
MOD_NAME="base-000001.dat"
MOD_SIZE="$(file_size_bytes "$MOD_NAME")"
MOD_PATTERN="CBT-WORKLOAD-V1:$MOD_NAME:MODIFIED-PASS-01"

gen_cmd='gen() { local spec="$1" name sz t a; IFS="|" read -r name sz <<< "$spec"; t="$WD/.cbt-workload-$name.tmp"; set +o pipefail; yes "CBT-WORKLOAD-V1:$name" | head -c "$sz" > "$t"; set -o pipefail; a=$(stat -c %s "$t"); [[ "$a" == "$sz" ]] || exit 1; if [[ -e "$WD/$name" ]]; then rm -f "$t"; else mv "$t" "$WD/$name"; fi; }'
baseline_script="set -euo pipefail; WD='$WORKLOAD_DIR'; mkdir -p \"\$WD\"; $gen_cmd; for s in $baseline_items; do gen \"\$s\"; done; sync; du -sb \"\$WD\""
incr_script="set -euo pipefail; WD='$WORKLOAD_DIR'; mkdir -p \"\$WD\"; $gen_cmd; for s in $incr_items; do gen \"\$s\"; done; T=\"\$WD/$MOD_NAME\"; [[ -f \"\$T\" ]] || exit 1; set +o pipefail; yes '$MOD_PATTERN' | head -c '$MOD_SIZE' > \"\$WD/.m.tmp\"; set -o pipefail; mv -f \"\$WD/.m.tmp\" \"\$T\"; sync; du -sb \"\$WD\""

# Windows guest mutation via QEMU guest-agent (no SSH in the image)
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/win-workload-agent.sh"

ssh_run() {
  local svc="$1" script="$2" log="$3" pf rc port ready
  port=$(( (RANDOM % 30000) + 20000 ))
  for _ in $(seq 1 10); do
    if ! ss -ltn | awk '{print $4}' | grep -qE ":$port$"; then break; fi
    port=$(( (RANDOM % 30000) + 20000 ))
  done
  oc port-forward -n "$NAMESPACE" "service/$svc" "$port:22" >>"$log" 2>&1 &
  pf=$!
  ready=false
  for _ in $(seq 1 30); do
    if ss -ltn | awk '{print $4}' | grep -qE ":$port$"; then ready=true; break; fi
    kill -0 "$pf" 2>/dev/null || break
    sleep 0.5
  done
  if [[ "$ready" != true ]]; then kill "$pf" 2>/dev/null; return 2; fi
  ssh -i "$GUEST_KEY" -p "$port" \
    -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$GUEST_USER@127.0.0.1" "$script"
  rc=$?
  kill "$pf" 2>/dev/null
  wait "$pf" 2>/dev/null || true
  return "$rc"
}

render_full() {
  sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__FULL_BACKUP_PVC__|vm-backup-pvc-$1|g" \
      -e "s|__TRACKER_NAME__|vm-tracker-$1|g" \
      -e "s|__VM_NAME__|vm-$1|g" \
      -e "s|__FULL_BACKUP_NAME__|vm-backup-$1|g" \
      -e "s|__LARGE_DISK_SIZE__|$FULL_DEST_SIZE|g" \
      -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
      -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
      -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
      -e "s|__RUN_ID__|$1|g" \
      -e "s|storageClassName: ocs-storagecluster-ceph-rbd\$|storageClassName: $BACKUP_SC|" \
      "$ROOT_DIR/manifests/full-backup-large-odf.yaml"
}
render_incr() {
  sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__TRACKER_NAME__|vm-tracker-$1|g" \
      -e "s|__INCREMENTAL_BACKUP_NAME__|vm-incremental-$1-p01|g" \
      -e "s|__INCREMENTAL_BACKUP_PVC__|vm-incremental-pvc-$1-p01|g" \
      -e "s|__INCREMENTAL_PVC_SIZE__|$INCR_DEST_SIZE|g" \
      -e "s|__RUN_ID__|$1|g" \
      -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
      -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
      -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
      -e "s|storageClassName: ocs-storagecluster-ceph-rbd\$|storageClassName: $BACKUP_SC|" \
      "$ROOT_DIR/manifests/incremental-backup-large-odf.yaml"
}

# group-mode render: $1 = real VM name (fleet), $2 = object id (<group>-<vm>)
render_full_g() {
  sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__FULL_BACKUP_PVC__|vm-backup-pvc-$2|g" \
      -e "s|__TRACKER_NAME__|vm-tracker-$2|g" \
      -e "s|__VM_NAME__|$1|g" \
      -e "s|__FULL_BACKUP_NAME__|vm-backup-$2|g" \
      -e "s|__LARGE_DISK_SIZE__|$FULL_DEST_SIZE|g" \
      -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
      -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
      -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
      -e "s|__RUN_ID__|$2|g" \
      -e "s|storageClassName: ocs-storagecluster-ceph-rbd\$|storageClassName: $BACKUP_SC|" \
      "$ROOT_DIR/manifests/full-backup-large-odf.yaml"
}
render_incr_g() {
  sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__TRACKER_NAME__|vm-tracker-$2|g" \
      -e "s|__INCREMENTAL_BACKUP_NAME__|vm-incremental-$2-p01|g" \
      -e "s|__INCREMENTAL_BACKUP_PVC__|vm-incremental-pvc-$2-p01|g" \
      -e "s|__INCREMENTAL_PVC_SIZE__|$INCR_DEST_SIZE|g" \
      -e "s|__RUN_ID__|$2|g" \
      -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
      -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
      -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
      -e "s|storageClassName: ocs-storagecluster-ceph-rbd\$|storageClassName: $BACKUP_SC|" \
      "$ROOT_DIR/manifests/incremental-backup-large-odf.yaml"
}

# ---- poll-based wait for a whole family of backups ----
wait_family() {  # $1 object-names file (exact names, one per line)  $2 timeout-s
  # exact names, not prefixes: in mixed groups several families share the
  # "<group>-" prefix, so a prefix count would span families
  local names_file="$1" timeout_s="${2:-$FAMILY_WAIT_TIMEOUT}" t0 d tot fail
  t0=$(date +%s)
  while :; do
    st="$(oc get vmbackup -n "$NAMESPACE" -o json \
      | jq -r --slurpfile nf <(jq -R -s 'split("\n") | map(select(length > 0))' "$names_file") "
      [.items[] | select(.metadata.name as \$n | \$nf[0] | index(\$n))] |
      {done: [.[] | .status.conditions[]? | select(.type==\"Done\" and .status==\"True\")] | length,
       total: length,
       failed: [.[] | .status.conditions[]? | select(.reason | startswith(\"Backup has failed\"))] | length}")"
    d=$(jq -r .done <<<"$st"); tot=$(jq -r .total <<<"$st"); fail=$(jq -r .failed <<<"$st")
    if (( fail > 0 )); then echo "$(date -u +%H:%M:%S) FAILURES: $fail"; return 1; fi
    if (( tot < $(wc -l < "$names_file" | tr -d ' ') )); then
      echo "$(date -u +%H:%M:%S) INCOMPLETE: $tot/$(wc -l < "$names_file" | tr -d ' ') expected backups exist (apply failed?)"; return 1
    fi
    if (( d >= tot )) && (( tot > 0 )); then echo "$(date -u +%H:%M:%S) all $tot done"; return 0; fi
    if (( $(date +%s) - t0 > timeout_s )); then echo "$(date -u +%H:%M:%S) TIMEOUT ($d/$tot done)"; return 2; fi
    sleep 30
  done
}
# Family wait timeout: sized so 2000-VM waves finish. Measured: 300 fulls
# ~488s, 1200 fulls >2h (run rhel9-light-20-11-2026-15-19-05 hit the old
# 7200s default with all backups eventually Done). Scale VMs x 15s with a
# 7200s floor; 2000 VMs -> 30000s (~8.3h). Override: FAMILY_WAIT_TIMEOUT env.
(( ${#GROUP_VMS[@]} * 15 > 7200 )) && _fwt=$(( ${#GROUP_VMS[@]} * 15 )) || _fwt=7200
FAMILY_WAIT_TIMEOUT="${FAMILY_WAIT_TIMEOUT:-$_fwt}"

# ---- Phase A: baseline workload ----
echo "=== Phase A: baseline workload ==="
while IFS=$'\t' read -r rid logname; do
  while (( $(jobs -rp | wc -l) >= WAVE )); do sleep 2; done
  (
    log="$(logf "${logname:-$rid}")"
    [[ -f "$log" ]] && grep -q "baseline workload written" "$log" 2>/dev/null && exit 0
    ok=false
    for attempt in 1 2 3 4 5; do
      if is_win_vm "$rid"; then out="$(win_workload_ps "vm-$rid" baseline 2>>"$log")" && ok=true && break
      elif out="$(ssh_run "vm-ssh-$rid" "$baseline_script" "$log" 2>>"$log")"; then ok=true; break; fi
      note "baseline ssh attempt $attempt failed" "$log"; sleep 5
    done
    if [[ "$ok" != true ]]; then note "RESULT baseline_workload FAILED" "$log"; exit 1; fi
    note "baseline workload written: $out" "$log"
  ) &
done < <(each_vm)
wait || true

# ---- Phase B: all full backups at once (apply all, then poll) ----
echo "=== Phase B: all full backups at once ==="
T0=$(date +%s)
# batch existence check (one oc get) instead of one per VM
existing_full="$(oc get vmbackup -n "$NAMESPACE" -o name --no-headers 2>/dev/null || true)"
full_names="$(mktemp "$EVIDENCE_DIR/full-names.XXXXXX")"
# render all pending manifests into one multi-doc stream, single oc apply
batch="$(mktemp "$EVIDENCE_DIR/full-batch.XXXXXX")"
while IFS=$'\t' read -r rid logname; do
  obj="$(obj_for "$rid")"
  printf 'vm-backup-%s\n' "$obj" >> "$full_names"
  grep -qE "/vm-backup-$obj$" <<<"$existing_full" && continue
  { printf -- '---\n'; if [[ -n "${GROUP_FILE:-}" ]]; then render_full_g "vm-$rid" "$obj"; else render_full "$rid"; fi; } >> "$batch"
done < <(each_vm)
if [[ -s "$batch" ]]; then
  oc apply -f "$batch" >> "$LOG_DIR/phase.log" 2>&1 \
    || { echo "full apply batch FAILED (see phase.log)" >&2; note "RESULT full_apply FAILED" "$LOG_DIR/phase.log"; }
fi
rm -f "$batch"
note "all full backup requests applied" "$LOG_DIR/phase.log"
wait_family "$full_names" \
  || note "RESULT full_wait FAILED" "$LOG_DIR/phase.log"
T1=$(date +%s)
echo "full phase wall: $((T1-T0))s" | tee -a "$LOG_DIR/phase.log"

# per-VM full validation (single bulk fetch, indexed by name)
full_status_json="$(oc get vmbackup -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')"
while IFS=$'\t' read -r rid logname; do
  obj="$(obj_for "$rid")"; log="$(logf "${logname:-$rid}")"
  reason="$(jq -r --arg n "vm-backup-$obj" '.items[] | select(.metadata.name==$n)
      | .status.conditions[]? | select(.type=="Done") | .reason' <<<"$full_status_json" | head -1)"
  [[ -n "$reason" ]] || reason=missing
  if reason_is_failure "$reason" || [[ "$reason" == missing ]]; then
    note "RESULT full_backup FAILED reason=$reason" "$log"
  else
    note "full backup done reason=$reason" "$log"
  fi
done < <(each_vm)

# ---- Phase C: incremental workload ----
echo "=== Phase C: incremental workload ==="
while IFS=$'\t' read -r rid logname; do
  while (( $(jobs -rp | wc -l) >= WAVE )); do sleep 2; done
  (
    log="$(logf "${logname:-$rid}")"
    grep -q "incremental workload written" "$log" 2>/dev/null && exit 0
    ok=false
    for attempt in 1 2 3 4 5; do
      if is_win_vm "$rid"; then out="$(win_workload_ps "vm-$rid" incr 2>>"$log")" && ok=true && break
      elif out="$(ssh_run "vm-ssh-$rid" "$incr_script" "$log" 2>>"$log")"; then ok=true; break; fi
      note "incremental ssh attempt $attempt failed" "$log"; sleep 5
    done
    if [[ "$ok" != true ]]; then note "RESULT incremental_workload FAILED" "$log"; exit 1; fi
    note "incremental workload written: $out" "$log"
  ) &
done < <(each_vm)
wait || true

# ---- Phase D: all incremental backups at once ----
echo "=== Phase D: all incremental backups at once ==="
T2=$(date +%s)
# batch existence check (one oc get), then single oc apply of all renders
existing_incr="$(oc get vmbackup -n "$NAMESPACE" -o name --no-headers 2>/dev/null || true)"
incr_names="$(mktemp "$EVIDENCE_DIR/incr-names.XXXXXX")"
batch="$(mktemp "$EVIDENCE_DIR/incr-batch.XXXXXX")"
while IFS=$'\t' read -r rid logname; do
  obj="$(obj_for "$rid")"
  printf 'vm-incremental-%s-p01\n' "$obj" >> "$incr_names"
  grep -qE "/vm-incremental-$obj-p01$" <<<"$existing_incr" && continue
  { printf -- '---\n'; if [[ -n "${GROUP_FILE:-}" ]]; then render_incr_g "vm-$rid" "$obj"; else render_incr "$rid"; fi; } >> "$batch"
done < <(each_vm)
if [[ -s "$batch" ]]; then
  oc apply -f "$batch" >> "$LOG_DIR/phase.log" 2>&1 \
    || { echo "incr apply batch FAILED (see phase.log)" >&2; note "RESULT incr_apply FAILED" "$LOG_DIR/phase.log"; }
fi
rm -f "$batch"
note "all incremental backup requests applied" "$LOG_DIR/phase.log"
wait_family "$incr_names" \
  || note "RESULT incr_wait FAILED" "$LOG_DIR/phase.log"
T3=$(date +%s)
echo "incr phase wall: $((T3-T2))s" | tee -a "$LOG_DIR/phase.log"

# per-VM incremental validation + tracker (single bulk fetch per kind)
incr_status_json="$(oc get vmbackup -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')"
tracker_json="$(oc get vmbackuptracker -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')"
while IFS=$'\t' read -r rid logname; do
  obj="$(obj_for "$rid")"; log="$(logf "${logname:-$rid}")"
  reason="$(jq -r --arg n "vm-incremental-$obj-p01" '.items[] | select(.metadata.name==$n)
      | .status.conditions[]? | select(.type=="Done") | .reason' <<<"$incr_status_json" | head -1)"
  [[ -n "$reason" ]] || reason=missing
  if reason_is_failure "$reason" || [[ "$reason" == missing ]]; then
    note "RESULT incr_backup FAILED reason=$reason" "$log"
  else
    note "incr backup done reason=$reason" "$log"
  fi
  cp="$(jq -r --arg n "vm-tracker-$obj" '.items[] | select(.metadata.name==$n)
      | .status.latestCheckpoint.name' <<<"$tracker_json" | head -1)"
  [[ -n "$cp" ]] || cp=missing
  if [[ "$cp" != "vm-incremental-$obj-p01-"* ]]; then
    note "RESULT tracker_check FAILED checkpoint=$cp" "$log"
  else
    note "tracker advanced: $cp" "$log"
  fi
done < <(each_vm)

# ---- tally ----
pass=0; fail=0
while IFS=$'\t' read -r rid logname; do
  l="$(logf "${logname:-$rid}")"
  if grep -q "full backup done reason=" "$l" 2>/dev/null && \
     grep -q "incr backup done reason=" "$l" 2>/dev/null && \
     ! grep -q "RESULT .* FAILED" "$l" 2>/dev/null && \
     grep -q "tracker advanced" "$l" 2>/dev/null; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
done < <(each_vm)
{
  if [[ -n "${GROUP_FILE:-}" ]]; then
    printf 'SUMMARY group=%s vms=%d pass=%d fail=%d\n' "$GROUP_ID" "${#GROUP_VMS[@]}" "$pass" "$fail"
  else
    printf 'SUMMARY pool=%s vms=%d-%d pass=%d fail=%d\n' "$POOL" "$START_N" "$END_N" "$pass" "$fail"
  fi
  cat "$LOG_DIR/phase.log" 2>/dev/null
} | tee "$EVIDENCE_DIR/summary.txt"
(( fail == 0 )) || exit 1
