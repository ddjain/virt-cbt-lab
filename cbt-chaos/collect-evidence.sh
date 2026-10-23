#!/usr/bin/env bash
# Lead-owned evidence collector for CBT chaos v2 runs.
# Started by the Lead (or its agent) BEFORE the injection window opens and
# left running until the attempt is terminal. It is deliberately separate
# from scenario trigger scripts, which stay minimal (async pipeline +
# injection only). Read-only: never mutates cluster state or deletes evidence.
#
# Usage:
#   collect-evidence.sh --run-root <dir> --namespace <ns> --lifecycle <id> \
#     [--vm <name>] [--full-backup <name>] [--incremental-backup <name>] \
#     [--tracker <name>] [--watch-max-seconds <s>] [--residual-seconds <s>] \
#     [--extra-watch <name>:<resource>:<mode>:<selector>] ...
#
# Produces under <run-root>/:
#   baseline-<utc>.json    identities/state snapshot before the window
#   watch-<name>.jsonl     scoped resource watches (watch-resource.sh)
#   watch-<name>.ready     readiness markers (wait for these before arming)
#   final-<utc>.json       terminal final-state snapshot (always written,
#                          including failed paths; failed probes -> .failed.json)
#   collector.status       this script's own exit status
set -euo pipefail

fail() { printf 'collect-evidence: %s\n' "$*" >&2; exit 2; }

RUN_ROOT='' NAMESPACE='' LIFECYCLE='' VM='' FULL_BK='' INC_BK='' TRACKER=''
WATCH_MAX=2700 RESIDUAL=30
declare -a EXTRA_WATCHES=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-root) RUN_ROOT="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --lifecycle) LIFECYCLE="$2"; shift 2 ;;
    --vm) VM="$2"; shift 2 ;;
    --full-backup) FULL_BK="$2"; shift 2 ;;
    --incremental-backup) INC_BK="$2"; shift 2 ;;
    --tracker) TRACKER="$2"; shift 2 ;;
    --watch-max-seconds) WATCH_MAX="$2"; shift 2 ;;
    --residual-seconds) RESIDUAL="$2"; shift 2 ;;
    --extra-watch) EXTRA_WATCHES+=("$2"); shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_ROOT" && -n "$NAMESPACE" && -n "$LIFECYCLE" ]] || fail '--run-root, --namespace and --lifecycle are required'
mkdir -p "$RUN_ROOT" || fail "cannot create run root: $RUN_ROOT"
command -v oc >/dev/null 2>&1 || fail 'oc not found in PATH'

OC=(oc --request-timeout=30s)
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- baseline snapshot (identities + untouched-sibling exclusions) ----------
BASELINE_TS="$(utc)"
{
  printf '{"captured_at":"%s","lifecycle_id":"%s","namespace":"%s"' "$BASELINE_TS" "$LIFECYCLE" "$NAMESPACE"
  [[ -z "$VM" ]] || printf ',"vm":%s' "$("${OC[@]}" get vm "$VM" -n "$NAMESPACE" -o json 2>/dev/null || printf '"unreadable"')"
  printf ',"vmis":%s' "$("${OC[@]}" get vmi -n "$NAMESPACE" -o json 2>/dev/null || printf '"unreadable"')"
  [[ -z "$FULL_BK" ]] || printf ',"full_backup":%s' "$("${OC[@]}" get vmbackup "$FULL_BK" -n "$NAMESPACE" -o json 2>/dev/null || printf '"unreadable"')"
  [[ -z "$TRACKER" ]] || printf ',"tracker":%s' "$("${OC[@]}" get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json 2>/dev/null || printf '"unreadable"')"
  [[ -z "$INC_BK" ]] || printf ',"incremental_backup":%s' "$("${OC[@]}" get vmbackup "$INC_BK" -n "$NAMESPACE" -o json 2>/dev/null || printf '"unreadable"')"
  printf '}\n'
} > "$RUN_ROOT/baseline-$BASELINE_TS.json"

# --- scoped watches ----------------------------------------------------------
declare -a WATCH_PIDS=() WATCH_NAMES=()
start_watch() {
  local name="$1" resource="$2" mode="$3" selector="$4"
  WATCH_MAX_SECONDS="$WATCH_MAX" timeout -k 5 $((WATCH_MAX+15)) \
    bash "$SCRIPT_DIR/watch-resource.sh" "$NAMESPACE" "$resource" "$mode" "$selector" \
    "$RUN_ROOT/watch-$name.jsonl" "$RUN_ROOT/watch-$name.ready" \
    > "$RUN_ROOT/watch-$name.log" 2>&1 &
  WATCH_PIDS+=("$!"); WATCH_NAMES+=("$name")
}

[[ -z "$VM" ]] || start_watch vm vm name "$VM"
[[ -z "$VM" ]] || start_watch vmi vmi name "$VM"
[[ -z "$VM" ]] || start_watch vmpods pods label "vm.kubevirt.io/name=$VM"
start_watch backup vmbackup label "virt-cbt-lab/run-id=$LIFECYCLE"
[[ -z "$TRACKER" ]] || start_watch tracker vmbackuptracker name "$TRACKER"
[[ -z "$INC_BK" ]] || start_watch incremental vmbackup name "$INC_BK"
for spec in "${EXTRA_WATCHES[@]:-}"; do
  [[ -n "$spec" ]] || continue
  IFS=: read -r wname wresource wmode wselector <<< "$spec"
  [[ -n "${wname:-}" && -n "${wresource:-}" && -n "${wmode:-}" ]] || fail "bad --extra-watch spec: $spec"
  start_watch "$wname" "$wresource" "$wmode" "${wselector:-}"
done

# readiness markers appear when watch-resource.sh is armed; the Lead waits for
# these (bounded) before opening the window. See watch-resource.sh contract.

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  for pid in "${WATCH_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  printf '%s\n' "$rc" > "$RUN_ROOT/collector.status"
}
trap cleanup EXIT INT TERM

# --- wait for terminal condition, then residual window, then final snapshot --
# Terminal = both full and incremental backups (when named) reach a terminal
# phase, or watch budget expires. Simple bounded poll; scenario-specific
# terminal logic stays with the Lead/entrypoint.
terminal_state() {
  local done_count=0 expected=0 done_status
  [[ -z "$FULL_BK" ]] || expected=$((expected+1))
  [[ -z "$INC_BK" ]] || expected=$((expected+1))
  [[ "$expected" -eq 0 ]] && return 0
  for bk in "$FULL_BK" "$INC_BK"; do
    [[ -z "$bk" ]] && continue
    # The live VirtualMachineBackup CRD has no .status.phase; the Done
    # condition is the terminal marker (Done=True with any reason, including
    # failure reasons, is terminal). The reason itself stays in the raw
    # objects/watches for the grader; it is not interpreted here.
    done_status="$("${OC[@]}" get vmbackup "$bk" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || printf 'UNKNOWN')"
    [[ "$done_status" == "True" ]] && done_count=$((done_count+1))
  done
  [[ "$done_count" -eq "$expected" ]]
}

deadline=$((SECONDS+WATCH_MAX))
until terminal_state; do
  ((SECONDS<deadline)) || break
  sleep 10
done
sleep "$RESIDUAL"   # bounded residual window for post-terminal observation

FINAL_TS="$(utc)"
FINAL_TARGETS=()
[[ -z "$VM" ]] || FINAL_TARGETS+=("vm:$VM" "vmi:$VM")
[[ -z "$FULL_BK" ]] || FINAL_TARGETS+=("vmbackup:$FULL_BK")
[[ -z "$INC_BK" ]] || FINAL_TARGETS+=("vmbackup:$INC_BK")
[[ -z "$TRACKER" ]] || FINAL_TARGETS+=("vmbackuptracker:$TRACKER")
for target in "${FINAL_TARGETS[@]}"; do
  res="${target%%:*}"; name="${target#*:}"; out="$RUN_ROOT/final-$res-$name.json"
  if ! "${OC[@]}" get "$res" "$name" -n "$NAMESPACE" -o json > "$out" 2>"$out.err"; then
    printf '{"probe_failed":true,"target":"%s/%s"}\n' "$res" "$name" > "$out.failed.json"
  fi
done
"${OC[@]}" get vmi -n "$NAMESPACE" -o json > "$RUN_ROOT/final-vmis-namespace.json" 2>/dev/null \
  || printf '{"probe_failed":true}\n' > "$RUN_ROOT/final-vmis-namespace.failed.json"
printf '{"captured_at":"%s","residual_seconds":%s}\n' "$FINAL_TS" "$RESIDUAL" > "$RUN_ROOT/final-$FINAL_TS.json"

exit 0
