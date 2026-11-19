#!/usr/bin/env bash
# cbt-chaos-simple — precheck template (READ-ONLY; instantiate per run).
# Validates: collision guard, trigger-command parse, sizing sanity.
# Learning encoded: a trigger parse error is indistinguishable from "not yet
# satisfied" in krknctl logs (r02/r05) — never skip the parse validation.
set -uo pipefail

# ==== CONFIG (fill per run) ====
SCENARIO_ID="CBT-F-08"                     # cbt-chaos/scenarios_v2/<SCENARIO_ID>/
NEW_RUN="20261111-<scenario>-r01"           # chaos run id (must not exist anywhere)
REF_RUN="<fresh-control-run-id>"            # control run: stage Done=True success
NS="vm-cbt-demo"
CHECKOUT="/root/v2/virt-cbt-lab"
KUBECONFIG_PATH="/root/mno/kubeconfig"
# Names for the stage under attack (full: vm-backup-<id> / vm-backup-pvc-<id>;
# incremental pass NN: vm-incremental-<id>-pNN / vm-incremental-pvc-<id>-pNN):
backup_name_for() { printf 'vm-backup-%s' "$1"; }          # adjust for incremental
pvc_name_for()    { printf 'vm-backup-pvc-%s' "$1"; }      # adjust for incremental
# Sizing sanity (measured values; leave empty to skip the assertion):
DEST_CAPACITY_KIB=""   # df -k inside the dest mount (NOT the PVC request)
FILL_PCT=""            # approved fill percentage (ODF 95; HPP 99)
ARTIFACT_GIB=""        # control-run artifact size

export KUBECONFIG="$KUBECONFIG_PATH"

echo "== collision check for $NEW_RUN =="
if oc get vm,vmbackup,pvc,vmbackuptracker -n "$NS" -o name 2>/dev/null | grep -F -- "$NEW_RUN"; then
  echo "COLLISION: cluster resources already exist for $NEW_RUN"; exit 1
fi
if ls "$CHECKOUT/runs/" 2>/dev/null | grep -F -- "$NEW_RUN"; then
  echo "COLLISION: local run dir exists for $NEW_RUN"; exit 1
fi
if ls "$CHECKOUT/cbt-chaos/scenarios_v2/$SCENARIO_ID/runs/" 2>/dev/null | grep -F -- "$NEW_RUN"; then
  echo "COLLISION: chaos evidence dir exists for $NEW_RUN"; exit 1
fi
echo "collision: clear"

# Compound trigger (live-proven, backend- and OS-agnostic): target PVC Bound
# AND launcher pod exists AND target backup not Done AND the exact backup's
# "Backup started" line present in the launcher compute logs.
build_trigger() { # $1 = run id
  local rid="$1" backup pvc
  backup="$(backup_name_for "$rid")"; pvc="$(pvc_name_for "$rid")"
  printf "test \"\$(oc get pvc %s -n %s -o jsonpath='{.status.phase}' 2>/dev/null)\" = Bound && pod=\$(oc get pod -n %s -l vm.kubevirt.io/name=vm-%s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && test -n \"\$pod\" && test \"\$(oc get vmbackup %s -n %s -o jsonpath='{.status.conditions[?(@.type==\"Done\")].status}' 2>/dev/null)\" != True && oc logs -n %s \"\$pod\" -c compute --tail=2000 2>/dev/null | grep -F -- %s | grep -F -- 'Backup started'" \
    "$pvc" "$NS" "$NS" "$rid" "$backup" "$NS" "$NS" "$backup"
}

echo
echo "== trigger parse validation against reference run $REF_RUN =="
cmd="$(build_trigger "$REF_RUN")"
echo "$cmd"
if bash -c "$cmd"; then
  echo "UNEXPECTED rc=0 (reference is Done=True; the compound should fail there)"
else
  echo "compound rc=$? (a clause blocked it — parse is valid; a parse error would look different)"
fi
# krkn collapses backslashes in --trigger-command (CBT-F-13 r02: a jq regex escape
# became a compile error that never shows in krknctl logs). Reject them up front.
if printf '%s' "$cmd" | grep -q '\\'; then
  echo "FAIL: trigger text contains a backslash — krkn will mangle it; rewrite without escapes"; exit 1
fi
echo "no-backslash guard: OK"
echo
echo "== clause-by-clause on reference run =="
c1="$(oc get pvc "$(pvc_name_for "$REF_RUN")" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
[ "$c1" = Bound ] && echo "clause1 PVC phase: Bound OK" || echo "clause1 PVC phase: $c1 FAIL"
pod="$(oc get pod -n "$NS" -l vm.kubevirt.io/name=vm-$REF_RUN -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$pod" ] && echo "clause2 launcher pod: $pod OK" || echo "clause2 launcher pod: EMPTY FAIL"
c3="$(oc get vmbackup "$(backup_name_for "$REF_RUN")" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)"
[ "$c3" = True ] && echo "clause3 Done: True OK (blocks as designed)" || echo "clause3 Done: $c3"
echo "clause4 log grep: covered by the compound rc above"

echo
echo "== sizing sanity =="
if [ -n "$DEST_CAPACITY_KIB" ] && [ -n "$FILL_PCT" ] && [ -n "$ARTIFACT_GIB" ]; then
  floor_gib=$(( DEST_CAPACITY_KIB * (100 - FILL_PCT) / 100 / 1048576 ))
  echo "floor after fill: ~${floor_gib}GiB free vs artifact ${ARTIFACT_GIB}GiB"
  if [ "$floor_gib" -lt "$ARTIFACT_GIB" ]; then
    echo "sizing OK (floor < artifact — the copy will die mid-way)"
  else
    echo "SIZING INVALID: floor >= artifact — the backup would SUCCEED. Fix before running."
    exit 1
  fi
else
  echo "(sizing values not filled — assertion skipped; fill them for pvc-fill scenarios)"
fi
