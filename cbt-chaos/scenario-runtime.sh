#!/usr/bin/env bash
# Shared runtime helpers for CBT chaos v2 scenario bundles.
# Source this from a scenario's run.sh/inject.sh instead of re-authoring
# these primitives per scenario; see cbt-chaos-trigger-preparer-v2 and
# cbt-chaos/template/chaos-trigger-pattern-v2.md. Every function takes its
# directories/labels/deadlines as arguments; nothing here reads or sets
# scenario-global variables, so callers keep their own naming.
set -uo pipefail

ccv2_tlog() {
  # ccv2_tlog <evidence-dir> <message>
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$1/trigger.log"
}

ccv2_stage_mark() {
  # ccv2_stage_mark <work-dir> <evidence-dir> <stage-name>
  date -u +%Y-%m-%dT%H:%M:%SZ > "$1/stage-$3.utc"
  ccv2_tlog "$2" "stage $3"
}

ccv2_budget_remaining() {
  # ccv2_budget_remaining <deadline-seconds-on-this-shell's-SECONDS-counter>
  # Caller sets DEADLINE=$((SECONDS + TOTAL_TIMEOUT)) once and passes it here.
  local deadline="$1" remaining
  remaining=$((deadline - SECONDS))
  if (( remaining <= 0 )); then
    printf 'wall-clock budget exhausted\n' >&2
    exit 124
  fi
  printf '%s' "$remaining"
}

ccv2_oc() {
  # ccv2_oc <deadline> -- <oc args...>
  local deadline="$1" remaining limit=15
  shift
  remaining="$(ccv2_budget_remaining "$deadline")"
  ((limit <= remaining)) || limit="$remaining"
  timeout -k 2 "$limit" oc --request-timeout=10s "$@"
}

ccv2_record() {
  # ccv2_record <work-dir> <deadline> <name> <limit-seconds> -- <cmd...>
  # Runs a bounded command, capturing combined stdout/stderr to <name>.log and
  # its exit status to <name>.status.json. Never masks the real exit status.
  local work="$1" deadline="$2" name="$3" limit="$4" rc remaining child_pid
  shift 4
  remaining="$(ccv2_budget_remaining "$deadline")"
  ((limit <= remaining)) || limit="$remaining"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$work/$name.started.utc"
  timeout -k 10 "$limit" "$@" > "$work/$name.log" 2>&1 & child_pid=$!
  if wait "$child_pid"; then rc=0; else rc=$?; fi
  jq -n --argjson rc "$rc" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{child_rc:$rc,ended_at:$at}' \
    > "$work/$name.status.json"
  return "$rc"
}

ccv2_capture() {
  # ccv2_capture <work-dir> <deadline> <name> <limit-seconds> <dest-file> -- <cmd...>
  # Like ccv2_record but writes stdout atomically to <dest-file> instead of a log.
  local work="$1" deadline="$2" name="$3" limit="$4" dest="$5" rc remaining
  shift 5
  remaining="$(ccv2_budget_remaining "$deadline")"
  ((limit <= remaining)) || limit="$remaining"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$work/$name.started.utc"
  if timeout -k 10 "$limit" "$@" > "$dest.tmp.$$" 2> "$work/$name.stderr"; then rc=0; else rc=$?; fi
  mv -f "$dest.tmp.$$" "$dest"
  jq -n --argjson rc "$rc" --arg dest "$dest" '{child_rc:$rc,dest:$dest}' \
    > "$work/$name.capture.status.json"
  return "$rc"
}

ccv2_require_uid() {
  # ccv2_require_uid <label> <value>
  # Fails closed on an empty/"null"/non-UID-shaped value instead of letting a
  # degraded operand silently never match a later comparison.
  local label="$1" value="${2:-}"
  [[ -n "$value" && "$value" != "null" ]] ||
    { printf '%s is empty or null; refusing to compare a degraded UID operand\n' "$label" >&2; exit 2; }
  [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    { printf '%s is not a UID (%s); refusing to compare a degraded UID operand\n' "$label" "$value" >&2; exit 2; }
}

ccv2_stop_group() {
  # ccv2_stop_group <work-dir> <pid> <label>
  # Bounded TERM-then-KILL of one process group this invocation owns.
  local work="$1" pid="$2" label="$3" waited=0 rc=0
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do sleep 1; waited=$((waited+1)); done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  if wait "$pid"; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" > "$work/$label.rc"
  return "$rc"
}

ccv2_check_permissions() {
  # ccv2_check_permissions <namespace> <deadline> "<resource> <verb>" ...
  # Prints a JSON array of failing {resource,verb} pairs ("[]" if none) to stdout.
  local namespace="$1" deadline="$2" failures='[]' scope resource verb
  shift 2
  for scope in "$@"; do
    read -r resource verb <<< "$scope"
    if [[ "$(ccv2_oc "$deadline" auth can-i "$verb" "$resource" -n "$namespace" 2>/dev/null)" != yes ]]; then
      failures="$(jq -c --arg r "$resource" --arg v "$verb" '. + [{resource:$r,verb:$v}]' <<<"$failures")"
    fi
  done
  printf '%s\n' "$failures"
}

ccv2_check_name_collisions() {
  # ccv2_check_name_collisions <namespace> <deadline> "<kind>:<name>" ...
  # Prints a JSON array of non-absent {kind,name,state} entries ("[]" if clear).
  local namespace="$1" deadline="$2" collisions='[]' pair kind name output state
  shift 2
  for pair in "$@"; do
    kind="${pair%%:*}"; name="${pair#*:}"
    if output="$(ccv2_oc "$deadline" get "$kind" "$name" -n "$namespace" -o name 2>&1)"; then
      state=present
    elif [[ "$output" == *NotFound* || "$output" == *'not found'* ]]; then
      state=absent
    else
      state=unknown
    fi
    if [[ "$state" != absent ]]; then
      collisions="$(jq -c --arg k "$kind" --arg n "$name" --arg s "$state" '. + [{kind:$k,name:$n,state:$s}]' <<<"$collisions")"
    fi
  done
  printf '%s\n' "$collisions"
}

ccv2_assert_canonical_jq() {
  # ccv2_assert_canonical_jq <work-dir>
  # Bundle fingerprints are SHA-256 over `jq -cS .` output; a non-canonical jq
  # implementation (e.g. a jaq shim) can emit different bytes for logically
  # identical JSON and silently break fingerprint comparison (see
  # .agents/skills/cbt-chaos-lead-v2/improvement.md). Fail closed instead of
  # discovering the divergence mid-run.
  local work="$1" version
  version="$(jq --version 2>&1)" || { printf 'jq is not runnable\n' >&2; exit 2; }
  [[ "$version" == jq-* ]] ||
    { printf 'jq --version reported "%s", not a jq-<version> string; refusing a non-canonical jq for fingerprinting\n' "$version" >&2; exit 2; }
  printf '%s\n' "$version" > "$work/jq-version.txt"
}
