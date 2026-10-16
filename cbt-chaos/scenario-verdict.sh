#!/usr/bin/env bash
# scenario-verdict.sh — deterministic verdict over one chaos scenario run.
#
# Why: a verdict must not depend on LLM judgement over loose artifacts. This
# script evaluates a fixed checklist over evidence that already exists on
# disk, returns machine-readable results, and exits non-zero unless every
# mandatory check passed. Missing mandatory evidence never becomes PASS.
#
# Usage:
#   cbt-chaos/scenario-verdict.sh --scenario-dir DIR --run-id ID \
#       [--lifecycle-run NAME] [--clean-lifecycle-run NAME] [--json PATH] \
#       [--list-checks] [--help]
#
#   --scenario-dir DIR        scenario directory containing runs/<run-id>/
#   --run-id ID               chaos run id (also the default --lifecycle-run)
#   --lifecycle-run NAME      lifecycle directory under the repo-root runs/
#                             (default: <run-id>)
#   --clean-lifecycle-run NAME
#                             separate clean lifecycle run to compare against
#   --json PATH               also write the JSON verdict to PATH (tmp+mv;
#                             the parent directory must already exist)
#   --list-checks             print check ids + descriptions as TSV, read
#                             nothing, exit 0
#   --help                    print usage, exit 0
#
# The repository root is derived from this script's location (the parent of
# cbt-chaos/), never from the current working directory.
#
# Read-only inputs (nothing else is read):
#   <scenario-dir>/runs/<run-id>/trigger/*        injection evidence
#   <scenario-dir>/runs/<run-id>/observer/*       optional corroboration
#   <root>/runs/<lifecycle-run>/{run.json,report.json,summary.json}
#   <root>/runs/<clean-lifecycle-run>/summary.json
# Nothing is written except the optional --json PATH.
#
# Checks (fixed ids, fixed order):
#   run-id-consistency   lifecycle run.json run_id/vm_name match --run-id and
#                        no trigger/observer artifact path references another run
#   injection-signal     trigger evidence records an active-copy signal naming the
#                        injection target (launcher) pod and its UID, the signal
#                        does not predate the observer arming instant, and an
#                        independent observer marker or watch stream exists (the
#                        injector is never the sole authority for its injection)
#   launcher-replacement trigger effect-check.json proves the old pod UID is gone,
#                        a replacement pod became Ready, and the removed pod is
#                        the pod the injection signal named (a provably different
#                        pod is a wrong-target injection)
#   backup-interrupted   the interrupted full backup is terminal+failed
#                        (type=Full, Done=True, failure reason, failed PVC kept)
#   tracker-not-advanced the tracker held no checkpoint at failure and none is
#                        attributed to the interrupted copy
#   cbt-recovered        CBT returned to Enabled and the VM/VMI is Running after
#                        recovery
#   same-vm-recovery     the same-VM recovery attempt succeeded and its restore
#                        comparison matched the baseline (count/bytes/hash)
#   clean-lifecycle      the clean lifecycle summary is PASS with verified restore
#                        hashes (NOT_APPLICABLE without --clean-lifecycle-run)
#
# Verdict rules (deterministic):
#   BLOCKED       observer/preflight recorded a blocked environment (observer
#                 marker files BLOCKED/WATCH-LOST/preflight-failed, an observer
#                 JSON payload with verdict/result/status BLOCKED, a lifecycle
#                 run.json status starting with "blocked", or a lifecycle
#                 summary.json verdict BLOCKED). Checked first: nothing can be
#                 concluded when the environment itself was blocked.
#   INVALID       the injected condition was never exercised: injection-signal
#                 and launcher-replacement are FAIL/UNKNOWN while
#                 backup-interrupted shows the full backup SUCCEEDED, or the
#                 removed pod is provably not the pod the signal named
#                 (wrong-target injection).
#   FAIL          any check FAILed.
#   INCONCLUSIVE  no FAIL, but some check is UNKNOWN, or clean-lifecycle is
#                 NOT_APPLICABLE (no --clean-lifecycle-run) — the verdict can be
#                 at most INCONCLUSIVE without a clean-lifecycle comparison.
#   PASS          every check PASSed.
# Missing mandatory evidence can therefore never yield PASS.
#
# Accepted artifact shapes (tolerant; a shape that cannot be parsed degrades to
# UNKNOWN, never to PASS):
#   trigger/action-request.json
#     signal  .signal_line | .signal_line_text | .backup_started_line |
#             .signal (string or {line|text}) | .active_copy_signal (string) |
#             .active_copy_signal==true | .signal_observed==true |
#             .copy_active==true | .backup_started==true
#     pod     .launcher_pod(name) | .launcher_pod_name | .target_pod(name) |
#             .pod(name) | .pod_name | .leader_pod(name) | .leader(name)
#     uid     .launcher_pod_uid | .target_pod_uid | .pod_uid | .launcher_uid |
#             .leader_pod_uid | .uid | {.launcher_pod,.target_pod,.pod,
#             .leader_pod,.leader}.uid
#   trigger/trigger.log fallback: an "Active-copy signal"/"Backup started" line,
#     a "<launcher|target|leader> pod[=:] <name>" token and a "uid[=:] <uid>" token.
#   trigger/effect-check.json
#     old uid  .old_pod.uid | .old_pod_uid | .deleted.uid | .deleted_pod_uid |
#              .previous_pod.uid | .previous_pod_uid | .target_pod.uid |
#              .target_pod_uid
#     new uid  .replacement_pod.uid | .new_pod.uid | .replacement_uid |
#              .replacement_pod_uid | .new_pod_uid
#     old gone .old_pod_gone | .old_pod_disappeared | .deleted_pod_gone |
#              .removal_confirmed | .delete_confirmed | .old_pod.removed |
#              .deleted.removed | (.old_pod_present|.deleted_pod_present)==false
#     new ready .replacement_pod.ready | .new_pod.ready | .replacement_ready |
#              .replacement_pod_ready | .new_pod_ready |
#              .replacement_pod.phase=="Running"
#   lifecycle run.json: .run_id, .vm_name, .vm_uid, .status, .cbt,
#     .backups.full_failure | .backups.full, .recovery.attempts[] (or
#     .recovery_attempts[]), .tracker
#   lifecycle report.json: .verification.checks[], .backups.full_failure |
#     .backups.full, .tracker.latest_checkpoint
#   lifecycle summary.json: .verdict, .cbt.vm_state, .lifecycle.state
#   clean summary.json: .verdict, .restore_hashes.{status,full_only,all}
#
# Exit codes: 0 only when the verdict is PASS; 1 for every other verdict;
#             2 for a usage/argument error.

set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: scenario-verdict.sh --scenario-dir DIR --run-id ID [options]' \
    '' \
    '  --scenario-dir DIR           scenario directory containing runs/<run-id>/' \
    '  --run-id ID                  chaos run id (default --lifecycle-run)' \
    '  --lifecycle-run NAME         lifecycle directory under <root>/runs/' \
    '  --clean-lifecycle-run NAME   separate clean lifecycle to compare against' \
    '  --json PATH                  also write the JSON verdict to PATH' \
    '  --list-checks                print check ids + descriptions as TSV' \
    '  --help                       print this usage' \
    '' \
    'Exit: 0 verdict PASS; 1 any other verdict; 2 usage/argument error.'
}

usage_err() {
  printf 'scenario-verdict: %s\n' "$1" >&2
  printf 'Try --help for usage.\n' >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

scenario_dir=''
run_id=''
lifecycle_run=''
clean_lifecycle_run=''
json_path=''
list_checks=false

while (($# > 0)); do
  case "$1" in
    --scenario-dir|--run-id|--lifecycle-run|--clean-lifecycle-run|--json)
      (($# >= 2)) || usage_err "$1 requires a value"
      case "$1" in
        --scenario-dir) scenario_dir="$2" ;;
        --run-id) run_id="$2" ;;
        --lifecycle-run) lifecycle_run="$2" ;;
        --clean-lifecycle-run) clean_lifecycle_run="$2" ;;
        --json) json_path="$2" ;;
      esac
      shift 2
      ;;
    --list-checks) list_checks=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

list_check_table() {
  printf '%s\t%s\n' \
    'run-id-consistency' 'lifecycle run.json run_id/vm_name match --run-id and no artifact path references another run' \
    'injection-signal' 'trigger evidence records an active-copy signal naming the exact launcher pod and its UID' \
    'launcher-replacement' 'trigger effect-check.json proves the old pod UID disappeared and a replacement launcher became Ready' \
    'backup-interrupted' 'the interrupted full backup is terminal and failed (type=Full, Done=True, failure reason, PVC retained)' \
    'tracker-not-advanced' 'the tracker held no checkpoint at failure and none is attributed to the interrupted copy' \
    'cbt-recovered' 'VM CBT state is Enabled and the VM/VMI is Running after recovery' \
    'same-vm-recovery' 'the same-VM recovery attempt succeeded and its restore comparison matched the baseline' \
    'clean-lifecycle' 'the separate clean lifecycle summary is PASS with verified restore hashes'
}

if [[ "$list_checks" == true ]]; then
  list_check_table
  exit 0
fi

[[ -n "$scenario_dir" ]] || usage_err 'missing required --scenario-dir'
[[ -n "$run_id" ]] || usage_err 'missing required --run-id'
[[ -d "$scenario_dir" ]] || usage_err "--scenario-dir is not a directory: $scenario_dir"
lifecycle_run="${lifecycle_run:-$run_id}"
valid_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] && ((${#1} <= 64))
}
valid_run_id "$run_id" || usage_err "--run-id is not a valid run id: $run_id"
valid_run_id "$lifecycle_run" || usage_err "--lifecycle-run is not a valid run id: $lifecycle_run"
if [[ -n "$clean_lifecycle_run" ]]; then
  valid_run_id "$clean_lifecycle_run" ||
    usage_err "--clean-lifecycle-run is not a valid run id: $clean_lifecycle_run"
fi
if [[ -n "$json_path" ]]; then
  [[ -d "$(dirname "$json_path")" ]] ||
    usage_err "--json parent directory does not exist: $(dirname "$json_path")"
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'scenario-verdict: required command not found: jq (install jq to evaluate a verdict)\n' >&2
  exit 1
fi

RUN_DIR="$scenario_dir/runs/$run_id"
TRIGGER_DIR="$RUN_DIR/trigger"
OBSERVER_DIR="$RUN_DIR/observer"
LC_DIR="$ROOT_DIR/runs/$lifecycle_run"
LC_RUN="$LC_DIR/run.json"
LC_REPORT="$LC_DIR/report.json"
LC_SUMMARY="$LC_DIR/summary.json"
CLEAN_SUMMARY=''
if [[ -n "$clean_lifecycle_run" ]]; then
  CLEAN_SUMMARY="$ROOT_DIR/runs/$clean_lifecycle_run/summary.json"
fi
ACTION_REQUEST="$TRIGGER_DIR/action-request.json"
TRIGGER_LOG="$TRIGGER_DIR/trigger.log"
EFFECT_CHECK="$TRIGGER_DIR/effect-check.json"

# jq_doc FILE — compact JSON document, or {} when the file is absent/invalid.
jq_doc() {
  local file="$1" value=''
  if [[ -s "$file" ]]; then
    value="$(jq -c '.' "$file" 2>/dev/null)" || value=''
  fi
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '{}'
  else
    printf '%s' "$value"
  fi
}

LC_RUN_JSON="$(jq_doc "$LC_RUN")"
LC_REPORT_JSON="$(jq_doc "$LC_REPORT")"
LC_SUMMARY_JSON="$(jq_doc "$LC_SUMMARY")"

# Shared jq helpers injected into every program below.
JQ_DEFS='
  def firststr: [.[] | select(type == "string" and length > 0)] | first // "";
  def nm: if type == "object" then (.name // .pod // "") else (. // "") end;
  def uidof: if type == "object" then (.uid // "") else "" end;
  def readyof: if type == "object" then (.ready // null) else null end;
'

CHECK_IDS=()
CHECK_STATUSES=()
CHECK_JSONS=()

add_check() {
  local id="$1" status="$2" expected="$3" actual="$4"
  shift 4
  local evidence_json
  evidence_json="$(jq -cn --args '$ARGS.positional' "$@")"
  CHECK_IDS+=("$id")
  CHECK_STATUSES+=("$status")
  CHECK_JSONS+=("$(jq -cn --arg id "$id" --arg status "$status" --arg expected "$expected" \
    --arg actual "$actual" --argjson evidence "$evidence_json" \
    '{id: $id, status: $status, expected: $expected, actual: $actual, evidence: $evidence}')")
  printf '%-22s %-14s %s\n' "$id" "$status" "$actual" >&2
}

status_of() {
  local id="$1" i
  for i in "${!CHECK_IDS[@]}"; do
    if [[ "${CHECK_IDS[$i]}" == "$id" ]]; then
      printf '%s' "${CHECK_STATUSES[$i]}"
      return 0
    fi
  done
  printf 'UNKNOWN'
}

FULL_BACKUP_SUCCEEDED=false
FULL_BACKUP_REASON=''
FULL_BACKUP_RECORD='{}'
# Set when the pod the trigger removed is provably not the pod the injection
# signal named: the injected condition then targeted the wrong resource.
WRONG_TARGET=''

# Converts an RFC3339 UTC timestamp to epoch seconds; prints nothing when the
# platform cannot parse it, so a comparison is skipped rather than guessed.
utc_epoch() { # <timestamp>
  local ts="${1:-}"
  [[ -n "$ts" ]] || return 0
  date -u -d "$ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || true
  return 0
}

# --------------------------------------------------------------------------
# 1. run-id-consistency
# --------------------------------------------------------------------------
check_run_id_consistency() {
  local expected="lifecycle run.json run_id=$run_id and vm_name referencing $run_id; every trigger/observer artifact path run-scoped"
  local evidence=("$RUN_DIR" "$LC_RUN" "$LC_REPORT" "$LC_SUMMARY")
  local problems=()

  if [[ -d "$RUN_DIR" ]]; then
    :
  else
    problems+=("scenario run directory missing: runs/$run_id")
  fi

  if [[ ! -s "$LC_RUN" ]]; then
    add_check run-id-consistency UNKNOWN "$expected" \
      "no lifecycle run.json at runs/$lifecycle_run/run.json" "${evidence[@]}"
    return 0
  fi

  local lc_run_id lc_vm_name
  lc_run_id="$(jq -r '.run_id // ""' <<<"$LC_RUN_JSON")"
  lc_vm_name="$(jq -r '.vm_name // ""' <<<"$LC_RUN_JSON")"
  [[ "$lc_run_id" == "$run_id" ]] || problems+=("run.json run_id=${lc_run_id:-<absent>}")
  if [[ "$lc_vm_name" != "$run_id" && "$lc_vm_name" != "vm-$run_id" ]]; then
    problems+=("run.json vm_name=${lc_vm_name:-<absent>}")
  fi

  local file rid label
  for file in report.json summary.json; do
    case "$file" in
      report.json) rid="$(jq -r '.run_id // ""' <<<"$LC_REPORT_JSON")" ;;
      summary.json) rid="$(jq -r '.run_id // ""' <<<"$LC_SUMMARY_JSON")" ;;
    esac
    if [[ -n "$rid" && "$rid" != "$run_id" ]]; then
      problems+=("$file run_id=$rid")
    fi
  done

  # Any artifact path recorded under trigger/ or observer/ must point at a run
  # id we were told to evaluate.
  local json_file foreign
  if [[ -d "$TRIGGER_DIR" || -d "$OBSERVER_DIR" ]]; then
    while IFS= read -r json_file; do
      [[ -n "$json_file" ]] || continue
      while IFS= read -r foreign; do
        [[ -n "$foreign" ]] || continue
        if [[ "$foreign" != "$run_id" && "$foreign" != "$lifecycle_run" &&
              "$foreign" != "$clean_lifecycle_run" ]]; then
          problems+=("$(basename "$json_file") references runs/$foreign/")
        fi
      done < <(jq -r "$JQ_DEFS"'
        [.. | strings | select(test("runs/[^/]+/")) | capture("runs/(?<id>[^/]+)/").id] | unique[]
      ' "$json_file" 2>/dev/null || true)
    done < <(find "$TRIGGER_DIR" "$OBSERVER_DIR" -type f -name '*.json' 2>/dev/null || true)
  fi

  if ((${#problems[@]} > 0)); then
    add_check run-id-consistency FAIL "$expected" "${problems[*]}" "${evidence[@]}"
  else
    label="run.json run_id=$run_id vm_name=$lc_vm_name"
    add_check run-id-consistency PASS "$expected" \
      "$label; trigger/observer artifacts reference $run_id only" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 2. injection-signal
# --------------------------------------------------------------------------
check_injection_signal() {
  local expected='trigger evidence records an active-copy signal naming the exact launcher pod and its UID'
  local evidence=("$ACTION_REQUEST" "$TRIGGER_LOG")
  if [[ ! -s "$ACTION_REQUEST" && ! -s "$TRIGGER_LOG" ]]; then
    add_check injection-signal UNKNOWN "$expected" \
      'no trigger evidence: action-request.json and trigger.log are absent' "${evidence[@]}"
    return 0
  fi

  local ar_json='{}'
  if [[ -s "$ACTION_REQUEST" ]]; then
    ar_json="$(jq_doc "$ACTION_REQUEST")"
  fi
  local info
  info="$(jq -c "$JQ_DEFS"'
    . as $a |
    {
      pod: ([($a.launcher_pod|nm), ($a.launcher_pod_name), ($a.target_pod|nm), ($a.pod|nm),
             ($a.pod_name), ($a.leader_pod|nm), ($a.leader|nm)] | firststr),
      uid: ([($a.launcher_pod_uid), ($a.target_pod_uid), ($a.pod_uid), ($a.launcher_uid),
             ($a.leader_pod_uid), ($a.uid), (($a.launcher_pod|uidof)), (($a.target_pod|uidof)),
             (($a.pod|uidof)), (($a.leader_pod|uidof)), (($a.leader|uidof))] | firststr),
      signal: ([($a.signal_line), ($a.signal_line_text), ($a.backup_started_line),
                ($a.signal | if type == "object" then (.line // .text // "") else (. // "") end),
                ($a.active_copy_signal | if type == "string" then . else "" end)] | firststr),
      flag: (($a.active_copy_signal == true) or ($a.signal_observed == true) or
             ($a.copy_active == true) or ($a.backup_started == true))
    }' <<<"$ar_json")"

  local pod uid signal flag signal_source='action-request.json'
  pod="$(jq -r '.pod' <<<"$info")"
  uid="$(jq -r '.uid' <<<"$info")"
  signal="$(jq -r '.signal' <<<"$info")"
  flag="$(jq -r '.flag' <<<"$info")"

  if [[ -s "$TRIGGER_LOG" ]]; then
    local log_line log_pod='' log_uid=''
    log_line="$(grep -m1 -Ei 'active-copy signal|backup started' "$TRIGGER_LOG" || true)"
    if [[ "$log_line" =~ (launcher|target|leader)[[:space:]]*pod[=:[:space:]]+([A-Za-z0-9._-]+) ]]; then
      log_pod="${BASH_REMATCH[2]}"
    fi
    if [[ "$log_line" =~ uid[=:[:space:]]+([A-Za-z0-9._-]+) ]]; then
      log_uid="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$signal" && -n "$log_line" ]]; then
      signal="$log_line"
      signal_source='trigger.log'
    fi
    if [[ -z "$pod" && -n "$log_pod" ]]; then pod="$log_pod"; signal_source='trigger.log'; fi
    if [[ -z "$uid" && -n "$log_uid" ]]; then uid="$log_uid"; signal_source='trigger.log'; fi
  fi

  local active_copy=false
  local lower_signal
  lower_signal="$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')"
  if [[ "$flag" == true ]]; then
    active_copy=true
  elif [[ "$lower_signal" == *'backup started'* || "$lower_signal" == *'active-copy'* ]]; then
    active_copy=true
  fi

  # A signal recorded before the observer's own arming instant contradicts the
  # watch window: a stale log line from an earlier backup on a long-lived pod
  # would produce exactly this shape. The timing claim is then not decidable.
  local armed_utc armed_epoch signal_utc signal_epoch
  armed_utc="$(jq -r '.utc_observer_armed // .since_time // ""' <<<"$ar_json" 2>/dev/null || true)"
  signal_utc="$(jq -r '.signal_utc // .utc_action_request // ""' <<<"$ar_json" 2>/dev/null || true)"
  if [[ -n "$armed_utc" && -n "$signal_utc" ]]; then
    armed_epoch="$(utc_epoch "$armed_utc")"
    signal_epoch="$(utc_epoch "$signal_utc")"
    if [[ -n "$armed_epoch" && -n "$signal_epoch" ]] && ((signal_epoch < armed_epoch)); then
      add_check injection-signal UNKNOWN \
        'the recorded signal falls inside the observer watch window' \
        "contradictory timing: signal_utc=$signal_utc predates observer_armed_utc=$armed_utc (stale-signal shape)" \
        "${evidence[@]}"
      return 0
    fi
  fi

  # The injecting agent cannot be the sole authority for its own injection
  # (verdict contract): the run must also carry observer evidence that an
  # independent witness was armed. Without it the timing claim is undecided.
  local corroboration=''
  local candidate
  for candidate in "$OBSERVER_DIR/ARMED" "$OBSERVER_DIR/PRESERVED" "$OBSERVER_DIR/FINAL" \
                   "$OBSERVER_DIR/finding.md"; do
    if [[ -s "$candidate" ]]; then corroboration="$candidate"; break; fi
  done
  if [[ -z "$corroboration" && -d "$OBSERVER_DIR/watches" ]]; then
    corroboration="$(find "$OBSERVER_DIR/watches" -maxdepth 1 -type f -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$corroboration" ]]; then
    add_check injection-signal UNKNOWN \
      'independent observer evidence corroborates the injection' \
      "pod=${pod:-<absent>} uid=${uid:-<absent>} signal=\"${signal:-<absent>}\"; no observer handoff marker (ARMED/PRESERVED/FINAL/finding.md) or watch stream exists under $OBSERVER_DIR, so the injector is the sole authority" \
      "${evidence[@]}" "$OBSERVER_DIR"
    return 0
  fi

  if [[ -n "$pod" && -n "$uid" && "$active_copy" == true ]]; then
    add_check injection-signal PASS "$expected" \
      "pod=$pod uid=$uid signal=\"$signal\" (source: $signal_source)" "${evidence[@]}"
  elif [[ -z "$pod" || -z "$uid" ]]; then
    add_check injection-signal UNKNOWN "$expected" \
      "trigger evidence present but does not name the launcher pod and its UID (pod=${pod:-<absent>} uid=${uid:-<absent>})" \
      "${evidence[@]}"
  else
    add_check injection-signal FAIL "$expected" \
      "pod=$pod uid=$uid but no active-copy signal recorded (signal=\"${signal:-<absent>}\")" \
      "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 3. launcher-replacement
# --------------------------------------------------------------------------
check_launcher_replacement() {
  local expected='effect-check.json confirms the old pod UID disappeared and a replacement launcher is Ready'
  local evidence=("$EFFECT_CHECK")
  if [[ ! -s "$EFFECT_CHECK" ]]; then
    add_check launcher-replacement UNKNOWN "$expected" \
      'no trigger effect-check.json recorded for this run' "${evidence[@]}"
    return 0
  fi

  local info
  info="$(jq -c "$JQ_DEFS"'
    . as $e |
    {
      old_uid: ([($e.old_pod|uidof), ($e.old_pod_uid), ($e.deleted|uidof), ($e.deleted_pod_uid),
                 ($e.previous_pod|uidof), ($e.previous_pod_uid), ($e.target_pod|uidof),
                 ($e.target_pod_uid)] | firststr),
      new_uid: ([($e.replacement_pod|uidof), ($e.new_pod|uidof), ($e.replacement_uid),
                 ($e.replacement_pod_uid), ($e.new_pod_uid)] | firststr),
      old_name: ([($e.old_pod|nm), ($e.deleted|nm), ($e.previous_pod|nm), ($e.target_pod|nm),
                  ($e.old_pod_name), ($e.deleted_pod_name)] | firststr),
      new_name: ([($e.replacement_pod|nm), ($e.new_pod|nm), ($e.replacement_pod_name),
                  ($e.new_pod_name)] | firststr),
      old_gone: ([($e.old_pod_gone), ($e.old_pod_disappeared), ($e.deleted_pod_gone),
                  ($e.removal_confirmed), ($e.delete_confirmed),
                  (if ($e.old_pod_present // $e.deleted_pod_present // null) == false then true else null end),
                  (($e.old_pod | if type == "object" then (.removed // .gone // .disappeared // null) else null end)),
                  (($e.deleted | if type == "object" then (.removed // .gone // .disappeared // null) else null end))] |
                 map(select(. == true or . == false)) | first // null),
      new_ready: ([($e.replacement_pod|readyof), ($e.new_pod|readyof), ($e.replacement_ready),
                   ($e.replacement_pod_ready), ($e.new_pod_ready),
                   (if (($e.replacement_pod | if type == "object" then .phase else null end) //
                        ($e.new_pod | if type == "object" then .phase else null end)) == "Running"
                    then true else null end)] |
                  map(select(. == true or . == false)) | first // null)
    }' "$EFFECT_CHECK" 2>/dev/null || printf '{}')"

  local old_uid new_uid old_gone new_ready old_name new_name
  old_uid="$(jq -r '.old_uid' <<<"$info")"
  new_uid="$(jq -r '.new_uid' <<<"$info")"
  old_gone="$(jq -r '.old_gone' <<<"$info")"
  new_ready="$(jq -r '.new_ready' <<<"$info")"
  old_name="$(jq -r '.old_name' <<<"$info")"
  new_name="$(jq -r '.new_name' <<<"$info")"
  [[ "$old_uid" == "null" ]] && old_uid=''
  [[ "$new_uid" == "null" ]] && new_uid=''

  local actual="old=${old_name:-<unnamed>}(${old_uid:-<no uid>}) gone=$old_gone replacement=${new_name:-<unnamed>}(${new_uid:-<no uid>}) ready=$new_ready"

  # The removed pod must be the pod the injection signal named. Only checked
  # when both artifacts name one: a scenario whose effect-check does not record a
  # pod cannot be judged here, and must not be failed for it.
  local signalled_uid=''
  if [[ -s "$ACTION_REQUEST" ]]; then
    signalled_uid="$(jq -rn "$JQ_DEFS"'
      [($ARGS.named.a.launcher_pod_uid), ($ARGS.named.a.target_pod_uid), ($ARGS.named.a.pod_uid),
       ($ARGS.named.a.launcher_uid), ($ARGS.named.a.launcher_pod|uidof),
       ($ARGS.named.a.target_pod|uidof), ($ARGS.named.a.pod|uidof)] | firststr' \
      --argjson a "$(jq_doc "$ACTION_REQUEST" 2>/dev/null || printf '{}')" 2>/dev/null || true)"
  fi
  [[ "$signalled_uid" == "null" ]] && signalled_uid=''
  if [[ -n "$signalled_uid" && -n "$old_uid" && "$signalled_uid" != "$old_uid" ]]; then
    WRONG_TARGET="$signalled_uid"
    add_check launcher-replacement FAIL \
      'the removed pod is the pod the injection signal named' \
      "$actual; the signal named UID $signalled_uid, but a different pod was removed" \
      "${evidence[@]}" "$ACTION_REQUEST"
    return 0
  fi

  if [[ -n "$old_uid" && -n "$new_uid" && "$old_uid" != "$new_uid" &&
        "$old_gone" == true && "$new_ready" == true ]]; then
    add_check launcher-replacement PASS "$expected" "$actual" "${evidence[@]}"
  elif [[ -z "$old_uid" || -z "$new_uid" || "$old_gone" == null || "$new_ready" == null ]]; then
    add_check launcher-replacement UNKNOWN "$expected" \
      "$actual (UIDs/disappearance/readiness not fully recorded)" "${evidence[@]}"
  else
    add_check launcher-replacement FAIL "$expected" "$actual" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 4. backup-interrupted
# --------------------------------------------------------------------------
full_backup_record() {
  jq -c "$JQ_DEFS"'
    . as $root |
    ($root.backups.full_failure // {}) as $ff |
    ($root.backups.full // {}) as $fb |
    (($root.recovery.attempts // $root.recovery_attempts // []) | (last // {})) as $att |
    ($att.failed_full // {}) as $af |
    (if (($ff | type) == "object" and (($ff.name // $ff.done_reason // "") != "")) then $ff
     elif (($fb | type) == "object" and (($fb.name // $fb.done_reason // "") != "")) then $fb
     elif (($af | type) == "object" and (($af.name // $af.done_reason // "") != "")) then $af
     else {} end) as $rec |
    {
      name: ($rec.name // ""),
      type: ($rec.type // ""),
      done_status: ($rec.done_status // ""),
      done_reason: ($rec.done_reason // ""),
      checkpoint_name: ($rec.checkpoint_name // ""),
      pvc_name: ($rec.pvc_name // ""),
      pvc_phase: ($rec.pvc_phase // ""),
      has_tracker_field: ($rec | has("tracker_checkpoint_at_failure"))
    }' <<<"$1"
}

record_is_empty() {
  [[ "$(jq -r 'if (.name == "" and .done_reason == "" and .type == "") then "empty" else "set" end' <<<"$1")" == "empty" ]]
}

reason_is_failure() {
  [[ "${1:-}" =~ [Ff]ail|[Ee]rror ]]
}

check_backup_interrupted() {
  local expected='interrupted full backup is type=Full, Done=True with a failure reason, and its PVC is retained'
  local evidence=("$LC_RUN" "$LC_REPORT")

  FULL_BACKUP_RECORD="$(full_backup_record "$LC_RUN_JSON")"
  if record_is_empty "$FULL_BACKUP_RECORD"; then
    local report_record
    report_record="$(full_backup_record "$LC_REPORT_JSON")"
    if ! record_is_empty "$report_record"; then
      FULL_BACKUP_RECORD="$report_record"
    fi
  fi

  local actual='' problems=() pending=()

  local name reason btype done_status pvc_name pvc_phase
  name="$(jq -r '.name' <<<"$FULL_BACKUP_RECORD")"
  reason="$(jq -r '.done_reason' <<<"$FULL_BACKUP_RECORD")"
  btype="$(jq -r '.type' <<<"$FULL_BACKUP_RECORD")"
  done_status="$(jq -r '.done_status' <<<"$FULL_BACKUP_RECORD")"
  pvc_name="$(jq -r '.pvc_name' <<<"$FULL_BACKUP_RECORD")"
  pvc_phase="$(jq -r '.pvc_phase' <<<"$FULL_BACKUP_RECORD")"

  if [[ -z "$name" && -z "$reason" && -z "$btype" ]]; then
    add_check backup-interrupted UNKNOWN "$expected" \
      "no full-backup record in runs/$lifecycle_run/run.json or report.json" "${evidence[@]}"
    return 0
  fi

  if [[ -n "$reason" ]] && ! reason_is_failure "$reason"; then
    FULL_BACKUP_SUCCEEDED=true
  fi
  FULL_BACKUP_REASON="$reason"

  actual="backup=${name:-<unnamed>} type=${btype:-<absent>} done=${done_status:-<absent>} reason=${reason:-<absent>} pvc=${pvc_name:-<absent>} pvc_phase=${pvc_phase:-<absent>}"

  [[ "$btype" == "Full" ]] || problems+=("type=$btype (expected Full)")
  if [[ -z "$done_status" ]]; then
    pending+=("done_status absent (backup not terminal)")
  elif [[ "$done_status" != "True" ]]; then
    problems+=("done_status=$done_status (expected True)")
  fi
  if [[ -z "$reason" ]]; then
    pending+=("done_reason absent")
  elif ! reason_is_failure "$reason"; then
    problems+=("done_reason is a success reason: $reason")
  fi
  if [[ -z "$pvc_name" ]]; then
    problems+=("failed PVC not recorded")
  elif [[ -z "$pvc_phase" ]]; then
    pending+=("pvc_phase absent (PVC preservation unproven)")
  elif [[ "$pvc_phase" != "Bound" ]]; then
    problems+=("pvc_phase=$pvc_phase (expected Bound)")
  fi

  if ((${#problems[@]} > 0)); then
    add_check backup-interrupted FAIL "$expected" "$actual; ${problems[*]}" "${evidence[@]}"
  elif ((${#pending[@]} > 0)); then
    add_check backup-interrupted UNKNOWN "$expected" "$actual; ${pending[*]}" "${evidence[@]}"
  else
    add_check backup-interrupted PASS "$expected" "$actual" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 5. tracker-not-advanced
# --------------------------------------------------------------------------
check_tracker_not_advanced() {
  local expected='tracker latest checkpoint empty/absent at failure and no usable checkpoint attributed to the interrupted copy'
  local evidence=("$LC_RUN" "$LC_REPORT")

  local name
  name="$(jq -r '.name' <<<"$FULL_BACKUP_RECORD")"
  if [[ -z "$name" ]]; then
    add_check tracker-not-advanced UNKNOWN "$expected" \
      "no failed full-backup record to attribute tracker state to" "${evidence[@]}"
    return 0
  fi

  local at_failure present interrupted tracker_latest
  at_failure="$(jq -r '
    (.backups.full_failure.tracker_checkpoint_at_failure
     // (.recovery.attempts // .recovery_attempts // [] | last // {} | .tracker.checkpoint_before)
     // "")' <<<"$LC_RUN_JSON")"
  if [[ -z "$at_failure" ]]; then
    at_failure="$(jq -r '.backups.full_failure.tracker_checkpoint_at_failure // ""' <<<"$LC_REPORT_JSON")"
  fi
  present="$(jq -r 'if .has_tracker_field then "yes" else "no" end' <<<"$FULL_BACKUP_RECORD")"
  if [[ "$present" != "yes" ]]; then
    present="$(jq -r '
      if ((.recovery.attempts // .recovery_attempts // []) | last // {} | (.tracker // {} | has("checkpoint_before")))
      then "yes" else "no" end' <<<"$LC_RUN_JSON")"
  fi
  if [[ "$present" != "yes" ]]; then
    present="$(jq -r 'if (.backups.full_failure | (type == "object") and has("tracker_checkpoint_at_failure")) then "yes" else "no" end' <<<"$LC_REPORT_JSON")"
  fi
  interrupted="$(jq -r '
    (.backups.full_failure.checkpoint_name
     // (.recovery.attempts // .recovery_attempts // [] | last // {} | .failed_full.checkpoint_name)
     // .backups.full.checkpoint_name // "")' <<<"$LC_RUN_JSON")"
  tracker_latest="$(jq -r '.tracker.latest_checkpoint // ""' <<<"$LC_REPORT_JSON")"
  if [[ -z "$tracker_latest" ]]; then
    tracker_latest="$(jq -r '.tracker.latest_checkpoint // ""' <<<"$LC_RUN_JSON")"
  fi
  if [[ -z "$tracker_latest" ]]; then
    tracker_latest="$(jq -r '.cbt.tracker_latest_checkpoint // ""' <<<"$LC_SUMMARY_JSON")"
  fi

  local actual="tracker_checkpoint_at_failure=${at_failure:-<empty>} interrupted_checkpoint=${interrupted:-<none>} tracker_latest_checkpoint=${tracker_latest:-<empty>}"

  if [[ "$present" != "yes" ]]; then
    add_check tracker-not-advanced UNKNOWN "$expected" \
      "$actual; tracker state at failure was not recorded" "${evidence[@]}"
  elif [[ -n "$at_failure" ]]; then
    add_check tracker-not-advanced FAIL "$expected" \
      "$actual; the tracker had already advanced to $at_failure" "${evidence[@]}"
  elif [[ -n "$interrupted" && "$tracker_latest" == "$interrupted" ]]; then
    add_check tracker-not-advanced FAIL "$expected" \
      "$actual; a usable checkpoint is attributed to the interrupted copy" "${evidence[@]}"
  else
    add_check tracker-not-advanced PASS "$expected" "$actual" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 6. cbt-recovered
# --------------------------------------------------------------------------
check_cbt_recovered() {
  local expected='CBT state Enabled and the VM/VMI Running after recovery'
  local evidence=("$LC_RUN" "$LC_REPORT" "$LC_SUMMARY")

  local info
  info="$(jq -cn --argjson rep "$LC_REPORT_JSON" --argjson run "$LC_RUN_JSON" --argjson sum "$LC_SUMMARY_JSON" '
    ($rep) as $p | ($run) as $r | ($sum) as $s |
    {
      cbt_check: ((($p.verification.checks // []) | map(select(.name == "vm_cbt_is_enabled")) | first)
                  | if . == null then null else (.passed // false) end),
      running_check: ((($p.verification.checks // [])
                       | map(select(.name == "vmi_running" or .name == "vm_is_running" or
                                     .name == "vm_running" or .name == "vm_running_state"))
                       | first) | if . == null then null else (.passed // false) end),
      run_cbt: ($r.cbt.vm_state // $r.cbt.status // ""),
      run_status: ($r.status // ""),
      summary_cbt: ($s.cbt.vm_state // ""),
      summary_state: ($s.lifecycle.state // ""),
      attempt_running: (((($r.recovery.attempts // $r.recovery_attempts // []) | map(
                          select((.preconditions // []) | any(.name == "vmi_running" and .passed == true)) or
                                 ((.vm.vmi_phase // "") == "Running" and (.vm.ready // "") == "True"))
                        | length) > 0)),
      attempt_cbt_state: (((($r.recovery.attempts // $r.recovery_attempts // []) | map(
                            select((.vm.cbt_state // "") == "Enabled") | .vm.cbt_state)) | first) // ""),
      attempt_cbt_enabled: (((($r.recovery.attempts // $r.recovery_attempts // []) | map(
                            select((.preconditions // []) | any(.name == "cbt_enabled" and .passed == true)))
                          | length) > 0))
    }')"

  local cbt=true running=true sources=()
  local cbt_check run_cbt summary_cbt running_check attempt_running run_status summary_state
  local attempt_cbt_state attempt_cbt_enabled
  cbt_check="$(jq -r '.cbt_check' <<<"$info")"
  running_check="$(jq -r '.running_check' <<<"$info")"
  run_cbt="$(jq -r '.run_cbt' <<<"$info")"
  summary_cbt="$(jq -r '.summary_cbt' <<<"$info")"
  attempt_running="$(jq -r '.attempt_running' <<<"$info")"
  attempt_cbt_state="$(jq -r '.attempt_cbt_state' <<<"$info")"
  attempt_cbt_enabled="$(jq -r '.attempt_cbt_enabled' <<<"$info")"
  run_status="$(jq -r '.run_status' <<<"$info")"
  summary_state="$(jq -r '.summary_state' <<<"$info")"

  if [[ "$cbt_check" == "true" ]]; then
    sources+=('report.json verification.vm_cbt_is_enabled')
  elif [[ "$cbt_check" == "false" ]]; then
    cbt=false
    sources+=('report.json verification.vm_cbt_is_enabled=false')
  elif [[ "$run_cbt" == "Enabled" ]]; then
    sources+=('run.json cbt.vm_state')
  elif [[ "$summary_cbt" == "Enabled" ]]; then
    sources+=('summary.json cbt.vm_state')
  elif [[ "$attempt_cbt_state" == "Enabled" ]]; then
    sources+=('run.json recovery.attempts[].vm.cbt_state')
  elif [[ "$attempt_cbt_enabled" == "true" ]]; then
    sources+=('run.json recovery.attempts[].preconditions.cbt_enabled')
  else
    cbt=null
  fi

  if [[ "$running_check" == "true" ]]; then
    sources+=('report.json verification.vmi_running')
  elif [[ "$running_check" == "false" ]]; then
    running=false
    sources+=('report.json verification.vmi_running=false')
  elif [[ "$attempt_running" == "true" ]]; then
    sources+=('run.json recovery.attempts[].preconditions.vmi_running')
  elif [[ "$run_status" == "complete" ]]; then
    sources+=('run.json status=complete')
  elif [[ "$summary_state" == "complete" ]]; then
    sources+=('summary.json lifecycle.state=complete')
  else
    running=null
  fi

  local actual="cbt=${cbt} vmi_running=${running} (sources: ${sources[*]:-none})"
  if [[ "$cbt" == true && "$running" == true ]]; then
    add_check cbt-recovered PASS "$expected" "$actual" "${evidence[@]}"
  elif [[ "$cbt" == false || "$running" == false ]]; then
    add_check cbt-recovered FAIL "$expected" "$actual" "${evidence[@]}"
  else
    add_check cbt-recovered UNKNOWN "$expected" "$actual" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 7. same-vm-recovery
# --------------------------------------------------------------------------
check_same_vm_recovery() {
  local expected='same-VM recovery attempt status success and its restore comparison matched the baseline (count/bytes/hash)'
  local evidence=("$LC_RUN" "$LC_SUMMARY")

  local count
  count="$(jq -r '(.recovery.attempts // .recovery_attempts // []) | length' <<<"$LC_RUN_JSON")"
  if [[ "$count" == "0" ]]; then
    add_check same-vm-recovery UNKNOWN "$expected" \
      'no same-VM recovery attempt recorded in the lifecycle run.json' "${evidence[@]}"
    return 0
  fi

  local info
  info="$(jq -cn "$JQ_DEFS"'
    (($JQ_RUN.recovery.attempts // $JQ_RUN.recovery_attempts // []) | (last // {})) as $a |
    {
      id: ($a.id // "<unknown>"),
      status: ($a.status // ""),
      restore_status: ($a.restore.status // ""),
      has_restore: (($a.restore | type) == "object"),
      vm_uid: ($a.vm.uid // ""),
      vm_name: ($a.vm.name // ""),
      run_vm_uid: ($JQ_RUN.vm_uid // ""),
      checks: (["file_count", "payload_bytes", "manifest"] | map(
        . as $k |
        {key: $k, value: ((($a.restore.checks // [])
                           | map(select((.name // "") | test("restore_" + $k + "_match$")))
                           | first) // null)}) | from_entries)
    }' --argjson JQ_RUN "$LC_RUN_JSON")"

  local id status restore_status has_restore vm_uid vm_name run_vm_uid
  id="$(jq -r '.id' <<<"$info")"
  status="$(jq -r '.status' <<<"$info")"
  restore_status="$(jq -r '.restore_status' <<<"$info")"
  has_restore="$(jq -r '.has_restore' <<<"$info")"
  vm_uid="$(jq -r '.vm_uid' <<<"$info")"
  vm_name="$(jq -r '.vm_name' <<<"$info")"
  run_vm_uid="$(jq -r '.run_vm_uid' <<<"$info")"

  local problems=() pending=()
  if [[ "$has_restore" != "true" ]]; then
    pending+=("no restore comparison recorded for attempt $id")
  fi
  if [[ "$status" != "success" ]]; then
    problems+=("attempt $id status=${status:-<absent>} (expected success)")
  fi
  if [[ "$has_restore" == "true" ]]; then
    if [[ "$restore_status" != "passed" && "$restore_status" != "PASS" ]]; then
      problems+=("restore.status=${restore_status:-<absent>} (expected passed)")
    fi
    local key check_json passed exp act
    for key in file_count payload_bytes manifest; do
      check_json="$(jq -c --arg k "$key" '.checks[$k]' <<<"$info")"
      if [[ "$check_json" == "null" ]]; then
        pending+=("restore check restore_${key}_match absent")
        continue
      fi
      passed="$(jq -r '.passed // false' <<<"$check_json")"
      exp="$(jq -r '.expected // ""' <<<"$check_json")"
      act="$(jq -r '.actual // ""' <<<"$check_json")"
      if [[ "$passed" != "true" ]]; then
        problems+=("restore_${key}_match failed (expected=${exp:-<none>} actual=${act:-<none>})")
      elif [[ -n "$exp" && -n "$act" && "$exp" != "$act" ]]; then
        problems+=("restore_${key}_match expected=$exp actual=$act")
      fi
    done
  fi
  if [[ -n "$vm_uid" && -n "$run_vm_uid" && "$vm_uid" != "$run_vm_uid" ]]; then
    problems+=("attempt $id targeted VM uid=$vm_uid, lifecycle VM uid=$run_vm_uid")
  fi

  local actual="attempt=$id status=${status:-<absent>} restore=${restore_status:-<absent>} vm=${vm_name:-<unnamed>}(${vm_uid:-<no uid>})"
  if ((${#problems[@]} > 0)); then
    add_check same-vm-recovery FAIL "$expected" "$actual; ${problems[*]}" "${evidence[@]}"
  elif ((${#pending[@]} > 0)); then
    add_check same-vm-recovery UNKNOWN "$expected" "$actual; ${pending[*]}" "${evidence[@]}"
  else
    add_check same-vm-recovery PASS "$expected" "$actual; baseline count/bytes/hash matched" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# 8. clean-lifecycle
# --------------------------------------------------------------------------
check_clean_lifecycle() {
  local expected='clean lifecycle summary verdict PASS with restore hashes verified'
  if [[ -z "$clean_lifecycle_run" ]]; then
    add_check clean-lifecycle NOT_APPLICABLE "$expected" \
      'no --clean-lifecycle-run supplied'
    return 0
  fi
  local evidence=("$CLEAN_SUMMARY")
  if [[ ! -s "$CLEAN_SUMMARY" ]]; then
    add_check clean-lifecycle UNKNOWN "$expected" \
      "no summary.json at runs/$clean_lifecycle_run/summary.json" "${evidence[@]}"
    return 0
  fi

  local clean_json
  clean_json="$(jq_doc "$CLEAN_SUMMARY")"
  local verdict rh_status rh_full actual
  verdict="$(jq -r '.verdict // ""' <<<"$clean_json")"
  rh_status="$(jq -r '.restore_hashes.status // ""' <<<"$clean_json")"
  rh_full="$(jq -r '.restore_hashes.full_only // ""' <<<"$clean_json")"
  actual="run=$clean_lifecycle_run verdict=${verdict:-<absent>} restore_hashes.status=${rh_status:-<absent>} restore_hashes.full_only=${rh_full:-<absent>}"

  if [[ "$verdict" == "PASS" && "$rh_status" == "PASS" && "$rh_full" == "PASS" ]]; then
    add_check clean-lifecycle PASS "$expected" "$actual" "${evidence[@]}"
  else
    add_check clean-lifecycle FAIL "$expected" "$actual" "${evidence[@]}"
  fi
}

# --------------------------------------------------------------------------
# Blocked-environment detection (observer + lifecycle evidence only)
# --------------------------------------------------------------------------
detect_blocked() {
  local marker json_file
  for marker in "$OBSERVER_DIR/BLOCKED" "$OBSERVER_DIR/WATCH-LOST" "$OBSERVER_DIR/preflight-failed"; do
    if [[ -e "$marker" ]]; then
      printf '%s' "$marker"
      return 0
    fi
  done
  if [[ -d "$OBSERVER_DIR" ]]; then
    while IFS= read -r json_file; do
      [[ -n "$json_file" ]] || continue
      if jq -e '(.verdict? == "BLOCKED") or (.result? == "BLOCKED") or (.blocked? == true) or (.status? == "BLOCKED")' \
        "$json_file" >/dev/null 2>&1; then
        printf '%s' "$json_file"
        return 0
      fi
    done < <(find "$OBSERVER_DIR" -type f -name '*.json' 2>/dev/null || true)
  fi
  local status summary_verdict
  status="$(jq -r '.status // ""' <<<"$LC_RUN_JSON")"
  if [[ "$status" == blocked* ]]; then
    printf '%s' "$LC_RUN (status=$status)"
    return 0
  fi
  summary_verdict="$(jq -r '.verdict // ""' <<<"$LC_SUMMARY_JSON")"
  if [[ "$summary_verdict" == "BLOCKED" ]]; then
    printf '%s (verdict=BLOCKED)' "$LC_SUMMARY"
    return 0
  fi
  printf ''
}

# --------------------------------------------------------------------------
# Evaluation
# --------------------------------------------------------------------------
printf '%-22s %-14s %s\n' 'check' 'status' 'detail' >&2
check_run_id_consistency
check_injection_signal
check_launcher_replacement
check_backup_interrupted
check_tracker_not_advanced
check_cbt_recovered
check_same_vm_recovery
check_clean_lifecycle

blocked_evidence="$(detect_blocked)"
verdict=''
verdict_reason=''
if [[ -n "$blocked_evidence" ]]; then
  verdict='BLOCKED'
  verdict_reason="observer/preflight recorded a blocked environment: $blocked_evidence"
else
  fail_ids=()
  unknown_ids=()
  for i in "${!CHECK_IDS[@]}"; do
    case "${CHECK_STATUSES[$i]}" in
      FAIL) fail_ids+=("${CHECK_IDS[$i]}") ;;
      UNKNOWN) unknown_ids+=("${CHECK_IDS[$i]}") ;;
    esac
  done
  c2="$(status_of injection-signal)"
  c3="$(status_of launcher-replacement)"
  if [[ -n "$WRONG_TARGET" ]]; then
    verdict='INVALID'
    verdict_reason="the injection targeted the wrong resource: the signal named launcher pod UID $WRONG_TARGET, but a different pod was removed"
  elif [[ ( "$c2" == "FAIL" || "$c2" == "UNKNOWN" ) &&
        ( "$c3" == "FAIL" || "$c3" == "UNKNOWN" ) &&
        "$FULL_BACKUP_SUCCEEDED" == true ]]; then
    verdict='INVALID'
    verdict_reason="the injected condition was never exercised: injection-signal=$c2 launcher-replacement=$c3 while the full backup succeeded (${FULL_BACKUP_REASON})"
  elif ((${#fail_ids[@]} > 0)); then
    verdict='FAIL'
    verdict_reason="failing checks: ${fail_ids[*]}"
  elif ((${#unknown_ids[@]} > 0)); then
    verdict='INCONCLUSIVE'
    verdict_reason="missing mandatory evidence: ${unknown_ids[*]}"
  elif [[ "$(status_of clean-lifecycle)" == "NOT_APPLICABLE" ]]; then
    verdict='INCONCLUSIVE'
    verdict_reason='no --clean-lifecycle-run supplied (clean-lifecycle NOT_APPLICABLE); verdict capped at INCONCLUSIVE'
  else
    verdict='PASS'
    verdict_reason='injection independently evidenced, the interrupted full backup failed cleanly, CBT recovered, and restore/clean-lifecycle checks passed'
  fi
fi

scenario_name="$(basename "$scenario_dir")"
checks_json="$(printf '%s\n' "${CHECK_JSONS[@]}" | jq -s '.')"
output="$(jq -cn \
  --arg scenario "$scenario_name" \
  --arg run_id "$run_id" \
  --arg verdict "$verdict" \
  --arg reason "$verdict_reason" \
  --argjson checks "$checks_json" \
  '{schema_version: 1, scenario: $scenario, run_id: $run_id, verdict: $verdict,
    verdict_reason: $reason, checks: $checks}')"

printf '%-22s %-14s %s\n' 'VERDICT' "$verdict" "$verdict_reason" >&2
printf '%s\n' "$output"

if [[ -n "$json_path" ]]; then
  json_tmp="$json_path.tmp.$$"
  trap 'rm -f "$json_tmp"' EXIT
  printf '%s\n' "$output" > "$json_tmp"
  mv -f "$json_tmp" "$json_path"
  trap - EXIT
fi

if [[ "$verdict" == "PASS" ]]; then
  exit 0
fi
exit 1
