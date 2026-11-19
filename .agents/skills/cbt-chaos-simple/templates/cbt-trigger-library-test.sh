#!/usr/bin/env bash
# =============================================================================
# cbt-trigger-library test harness — validates every checkpoint condition in
# cbt-trigger-library.sh against live objects on the cluster.
#
# Usage (on cloud05, with KUBECONFIG exported):
#   bash cbt-trigger-library-test.sh
#
# Substitutes the F-11 r01 live run's real names, then runs each numbered
# condition (extracted from the library between its ###-N marker) and prints
# PASS/FAIL per checkpoint with expected-vs-actual.
#
# Expected states on the completed F-11 run (terminal full + incremental p01):
#   positive (rc=0): 1 PVC_BOUND, 5 BACKUP_COMPLETED, 7 CHECKPOINT_RECORDED,
#                    9 LAUNCHER_SCHEDULED, 10 BACKUP_REQUESTED, 11 GUEST_FROZEN,
#                    12 COPY_STARTED, 13 COPY_FINISHED_LOCAL, 14 TRACKER_ADVANCED,
#                    15 HOTPLUG_POD_CREATED, 16 VOLUME_MOUNTED, 17 VOLUME_UNMOUNTED,
#                    18 HOTPLUG_POD_DELETED, COMPOUND (needs guard NOT-Done -> rc!=0 on terminal)
#   negative (rc!=0): 2 BACKUP_INITIALIZING (terminal), 3 VOLUME_ATTACHING (transient),
#                     4 COPY_IN_PROGRESS (terminal), 6 BACKUP_FAILED (succeeded),
#                     8 BACKUP_TARGET_DETACHING (reason gone)
# =============================================================================
set -u
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cbt-trigger-library.sh"
[[ -r "$LIB" ]] || { echo "library not found: $LIB" >&2; exit 1; }

# Live-substituted variables (completed F-11 r01 run) — exported so the
# extracted condition bodies (run via bash -c) can reference them.
export NS=vm-cbt-demo
export RUN=20261111-cbtf11-r01
export BACKUP=vm-backup-$RUN
export PVC=vm-backup-pvc-$RUN
POD=$(oc get pod -n "$NS" -l vm.kubevirt.io/name=vm-$RUN -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
export POD
export TRACKER=vm-tracker-$RUN
export VM=vm-$RUN
[[ -n "$POD" ]] || { echo "launcher pod not found for $VM" >&2; exit 1; }

# Expected rc on the completed F-11 run (terminal full + terminal incremental
# p01 — the tracker has advanced PAST the full to the incremental):
#   0: 1 PVC_BOUND, 5 BACKUP_COMPLETED, 7 CHECKPOINT_RECORDED, 9 LAUNCHER_SCHEDULED,
#      10-13 log-based (all present), 14 TRACKER_ADVANCED (tracker now points at
#      the INCREMENTAL, so full-prefix test is rc=1 — set BACKUP to the
#      incremental name to test positively), 15-18 event-based (within retention)
#   !=0: 2 BACKUP_INITIALIZING, 3 VOLUME_ATTACHING, 4 COPY_IN_PROGRESS (terminal),
#        6 BACKUP_FAILED (backup succeeded), 8 BACKUP_TARGET_DETACHING,
#        COMPOUND (guard requires Done≠True — terminal run must not satisfy)
declare -A EXPECT=(
  [1]=0 [2]=1 [3]=1 [4]=1 [5]=0 [6]=1 [7]=0 [8]=1 [9]=0
  [10]=0 [11]=0 [12]=0 [13]=0 [14]=1 [15]=0 [16]=0 [17]=0 [18]=0
  [COMPOUND]=1
)

run_cond() { # $1=name $2=condition-body
  local name="$1" body="$2"
  bash -c "$body" >/dev/null 2>&1
  echo $?
}

total=0; failed=0
while IFS= read -r block; do
  name="${block%%|*}"; body="${block#*|}"
  [[ -z "$body" ]] && continue
  key="${name%.}"
  rc=$(run_cond "$key" "$body")
  exp="${EXPECT[$key]:-?}"
  status=OK; [[ "$rc" != "$exp" ]] && { status=MISMATCH; failed=$((failed+1)); }
  printf '%-10s expected_rc=%s actual_rc=%s  %s\n' "$key" "$exp" "$rc" "$status"
  total=$((total+1))
done < <(awk '
  /^# [0-9]+\.|^# COMPOUND/ { sub(/^# /,""); split($0,a," "); name=a[1]; inblock=1; collect=0; body=""; next }
  inblock && /^# ---/ && !collect { collect=1; next }
  collect && /^#/ { print name "|" body; collect=0; inblock=0; next }
  collect && NF > 0 { if (body != "") body = body "\n"; body = body $0; next }
  collect && NF == 0 && body != "" { print name "|" body; collect=0; inblock=0 }
  END { if (collect && body != "") print name "|" body }
' "$LIB")

printf '\n%d conditions tested, %d mismatches\n' "$total" "$failed"
[[ "$failed" -eq 0 ]] && echo "ALL EXPECTATIONS MET" || exit 1
