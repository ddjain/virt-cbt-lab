#!/usr/bin/env bash
set -euo pipefail
# Use a scoped direct oc delete: Krkn startup exceeds this short copy window.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  printf 'Usage: bash %s [--plan]\n' "${BASH_SOURCE[0]}" >&2
  printf '  --plan   Resolve the run identity and print the planned invocation, environment\n' >&2
  printf '           passthrough and injection mechanism without contacting the cluster,\n' >&2
  printf '           mutating anything or creating directories.\n' >&2
}

PLAN_MODE=false
for arg in "$@"; do
  case "$arg" in
    --plan) PLAN_MODE=true ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      usage
      exit 2
      ;;
  esac
done

# Every execution must use a fresh unique run id; the caller supplies RUN_ID and
# the fallback is derived from the current UTC time so a forgotten RUN_ID cannot
# silently reuse an existing run's identities.
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-cbt-f-01-%H%M%S)}"
LIFECYCLE_ID="$RUN_ID"
VM_NAME="vm-${RUN_ID}"
NAMESPACE=vm-cbt-demo
SCENARIO_RUN_DIR="$SCRIPT_DIR/runs/$RUN_ID"
EVIDENCE_DIR="$SCENARIO_RUN_DIR/trigger"
LIFECYCLE_RUN_DIR="$ROOT_DIR/runs/$LIFECYCLE_ID"

ENV_PASSTHROUGH_VARS=(VM_OS GUEST_BASE_FILE_COUNT GUEST_FILE_SIZE_MIN_MIB \
  GUEST_FILE_SIZE_MAX_MIB GUEST_EXEC_POLL_INTERVAL GUEST_EXEC_POLL_ATTEMPTS)

# The kubeconfig value is never printed or persisted: the planned argv carries a
# placeholder that is substituted only at exec time.
E2E_ARGS=(TYPE=full NAME="$LIFECYCLE_ID" KUBECONFIG_PATH=__KUBECONFIG__)
for var in "${ENV_PASSTHROUGH_VARS[@]}"; do
  if [[ -n "${!var:-}" ]]; then E2E_ARGS+=("$var=${!var}"); fi
done

# Prints an argv with the kubeconfig value (and the placeholder) redacted.
redacted() {
  local out=() a
  for a in "$@"; do
    if [[ "$a" == 'KUBECONFIG_PATH=__KUBECONFIG__' ]]; then
      a='KUBECONFIG_PATH=<redacted>'
    fi
    if [[ -n "${KUBECONFIG_PATH:-}" && "$a" == *"$KUBECONFIG_PATH"* ]]; then
      a="${a//"$KUBECONFIG_PATH"/<redacted>}"
    fi
    out+=("$a")
  done
  printf '%s' "${out[*]}"
}

env_passthrough_line() {
  local name="$1"
  if [[ "$name" == KUBECONFIG_PATH ]]; then
    if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
      printf 'KUBECONFIG_PATH=<redacted: set>'
    else
      printf 'KUBECONFIG_PATH=<unset>'
    fi
    return 0
  fi
  if [[ -n "${!name:-}" ]]; then
    printf '%s=%s' "$name" "${!name}"
  else
    printf '%s=<unset>' "$name"
  fi
}

if [[ "$PLAN_MODE" == true ]]; then
  printf '=== CBT-F-01 plan rehearsal: no cluster contact, no mutation, no directory creation ===\n'
  printf 'scenario:          CBT-F-01\n'
  printf 'RUN_ID:            %s\n' "$RUN_ID"
  printf 'lifecycle id:      %s\n' "$LIFECYCLE_ID"
  printf 'NAMESPACE:         %s\n' "$NAMESPACE"
  printf 'VM_NAME:           %s\n' "$VM_NAME"
  printf 'tracker name:      vm-tracker-%s\n' "$RUN_ID"
  printf 'script dir:        %s\n' "$SCRIPT_DIR"
  printf 'scenario run dir:  %s\n' "$SCENARIO_RUN_DIR"
  printf 'evidence dir:      %s\n' "$EVIDENCE_DIR"
  printf 'lifecycle run dir: %s\n' "$LIFECYCLE_RUN_DIR"
  collision=false
  if [[ -e "$LIFECYCLE_RUN_DIR" ]]; then
    printf 'Run ID %s already exists in this checkout; refusing to reuse it.\n' "$RUN_ID" >&2
    collision=true
  fi
  if [[ -e "$SCENARIO_RUN_DIR" ]]; then
    # The observer arms before the trigger (and the Lead pre-creates contracts/,
    # observer/, trigger/, recovery/, checkers/, reports/), so an existing
    # scenario run directory is the normal pre-armed state, not a collision.
    # This mirrors the live path, which only refuses on real trigger evidence.
    unexpected=()
    nonempty=()
    for entry in "$SCENARIO_RUN_DIR"/*; do
      [[ -e "$entry" ]] || continue
      case "${entry##*/}" in
        contracts|observer|trigger) ;;
        recovery|checkers|reports)
          # Lead-owned scaffolding is fine; output inside it is not.
          if [[ -n "$(ls -A "$entry" 2>/dev/null || true)" ]]; then nonempty+=("${entry##*/}"); fi
          ;;
        ledger.jsonl|state.json|evidence-index.json|preflight.json) ;;
        *) unexpected+=("${entry##*/}") ;;
      esac
    done
    if [[ ! -d "$SCENARIO_RUN_DIR/observer" ]]; then
      printf 'Scenario run dir exists without the pre-armed observer directory: %s\n' "$SCENARIO_RUN_DIR" >&2
      collision=true
    fi
    if ((${#unexpected[@]} > 0)); then
      printf 'Scenario artifact directory %s already holds run output (%s) for run ID %s; refusing to reuse it.\n' \
        "$SCENARIO_RUN_DIR" "${unexpected[*]}" "$RUN_ID" >&2
      collision=true
    elif ((${#nonempty[@]} > 0)); then
      printf 'Scenario artifact directory %s already holds post-trigger output in %s for run ID %s; refusing to reuse it.\n' \
        "$SCENARIO_RUN_DIR" "${nonempty[*]}" "$RUN_ID" >&2
      collision=true
    elif [[ -d "$EVIDENCE_DIR" ]] && [[ -n "$(ls -A "$EVIDENCE_DIR" 2>/dev/null || true)" ]]; then
      printf 'Trigger evidence for run ID %s already exists in %s; refusing to reuse it.\n' \
        "$RUN_ID" "$EVIDENCE_DIR" >&2
      collision=true
    elif [[ "$collision" != true ]]; then
      printf 'scenario run dir: pre-armed (only run scaffolding/observer output present, no trigger evidence)\n'
    fi
  fi
  if [[ "$collision" == true ]]; then
    printf 'local precondition check: COLLISION (pick a fresh RUN_ID)\n'
    exit 1
  fi
  printf 'local precondition check: clear\n'
  printf 'planned argv:      make e2e %s\n' "$(redacted "${E2E_ARGS[@]}")"
  printf 'environment passthrough (read from the trigger environment):\n'
  printf '  RUN_ID=%s\n' "$RUN_ID"
  for passthrough_var in "${ENV_PASSTHROUGH_VARS[@]}"; do
    printf '  %s\n' "$(env_passthrough_line "$passthrough_var")"
  done
  printf '  %s\n' "$(env_passthrough_line KUBECONFIG_PATH)"
  printf 'live collision check (oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume): skipped in --plan mode\n'
  printf 'injection mechanism:\n'
  printf '  1. baseline precondition: capture the pre-backup libvirt checkpoint tree on the run\n'
  printf '     launcher and require vm-tracker-%s to be absent; refuse to inject otherwise.\n' "$RUN_ID"
  printf '  2. signal gate: follow the launcher compute log with\n'
  printf '     `oc logs --follow --since-time=<observer-armed UTC>` and match the first\n'
  printf "     'Backup started' line at or after arming (stale earlier copies on a long-lived pod\n"
  printf '     cannot fire the trigger).\n'
  printf '  3. action: resolve the pod UID after the match, then delete exactly that pod with\n'
  printf '     `oc delete pod <pod> -n %s --wait=false` (Krkn startup would outlast the copy window).\n' "$NAMESPACE"
  printf '  4. effect check: old UID gone and a replacement launcher Running+Ready within 120s\n'
  printf '     (informational evidence only; it never changes the exit status).\n'
  printf '  5. observer deadline: 3600s waiting for baseline+signal.\n'
  printf 'exit arbitration (unchanged): observer status first; then 1 when the E2E unexpectedly\n'
  printf '     succeeded; otherwise the E2E status (the expected nonzero).\n'
  printf 'evidence written by a real run (nothing is written by --plan):\n'
  printf '  %s/{command.txt,action-request.json,effect-check.json,exit-statuses.json,trigger.log}\n' "$EVIDENCE_DIR"
  printf 'deterministic verdict: cbt-chaos/scenario-verdict.sh --scenario-dir %s --run-id %s\n' \
    "$SCRIPT_DIR" "$RUN_ID"
  exit 0
fi

: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
export KUBECONFIG_PATH
export KUBECONFIG="$KUBECONFIG_PATH"

if [[ -e "$LIFECYCLE_RUN_DIR" ]]; then
  printf 'Run ID %s already exists in this checkout; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]] && [[ -n "$(ls -A "$EVIDENCE_DIR" 2>/dev/null || true)" ]]; then
  printf 'Trigger evidence for run ID %s already exists in %s; refusing to reuse it.\n' \
    "$RUN_ID" "$EVIDENCE_DIR" >&2
  exit 1
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi

TRIGGER_LOG=
EVIDENCE_ENABLED=false

# Every script-owned stderr line is mirrored into trigger.log; evidence writing
# is best-effort and must never fail the run.
log() {
  printf '%s\n' "$*" >&2
  if [[ -n "$TRIGGER_LOG" ]]; then
    printf '%s\n' "$*" >> "$TRIGGER_LOG" 2>/dev/null || true
  fi
}

atomic_write() {
  local path="$1" content="$2" tmp
  [[ "$EVIDENCE_ENABLED" == true ]] || return 0
  tmp="$(mktemp "$EVIDENCE_DIR/.$(basename "$path").XXXXXX" 2>/dev/null)" || {
    printf 'Warning: cannot create a temporary evidence file for %s; evidence not written.\n' \
      "$path" >&2
    return 0
  }
  if printf '%s\n' "$content" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  printf 'Warning: could not write evidence file %s; continuing.\n' "$path" >&2
}

# Writes one JSON object built by jq, atomically (tmp+mv).
write_json() {
  local path="$1"; shift
  [[ "$EVIDENCE_ENABLED" == true ]] || return 0
  local payload
  if ! payload="$(jq -n "$@" 2>/dev/null)" || [[ -z "$payload" ]]; then
    printf 'Warning: jq could not build %s; continuing without it.\n' "$(basename "$path")" >&2
    return 0
  fi
  atomic_write "$path" "$payload"
}

init_evidence_dir() {
  if mkdir -p "$EVIDENCE_DIR" 2>/dev/null; then
    EVIDENCE_ENABLED=true
    TRIGGER_LOG="$EVIDENCE_DIR/trigger.log"
    if ! : >>"$TRIGGER_LOG" 2>/dev/null; then
      printf 'Warning: could not open %s; evidence files will not be mirrored.\n' \
        "$TRIGGER_LOG" >&2
      TRIGGER_LOG=
    fi
  else
    printf 'Warning: cannot create evidence directory %s; continuing without trigger evidence files.\n' \
      "$EVIDENCE_DIR" >&2
  fi
}

write_command_txt() {
  [[ "$EVIDENCE_ENABLED" == true ]] || return 0
  local content
  content="$(printf 'cwd: %s\ninvocation: %s\nrun id: %s\nlifecycle id: %s\nnamespace: %s\nvm name: %s\ntracker name: %s\ntimestamp: %s\nmake argv: %s\nenvironment passthrough:\n  RUN_ID=%s\n' \
    "$ROOT_DIR" "$(redacted bash "$0" "$@")" "$RUN_ID" "$LIFECYCLE_ID" "$NAMESPACE" \
    "$VM_NAME" "vm-tracker-$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(redacted make e2e "${E2E_ARGS[@]}")" "$RUN_ID")"
  local passthrough_var
  for passthrough_var in "${ENV_PASSTHROUGH_VARS[@]}" KUBECONFIG_PATH; do
    content+="$(printf '\n  %s' "$(env_passthrough_line "$passthrough_var")")"
  done
  atomic_write "$EVIDENCE_DIR/command.txt" "$content"
}

init_evidence_dir
write_command_txt
log "Trigger started for run $RUN_ID (lifecycle $LIFECYCLE_ID, VM $VM_NAME, namespace $NAMESPACE)."
log "Evidence directory: $EVIDENCE_DIR"

SIGNAL_FILE="$(mktemp)"
observer_pid=

cleanup_observer() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
  rm -f "$SIGNAL_FILE"
}
trap cleanup_observer EXIT INT TERM

# `oc delete --wait=false` only proves the delete request was accepted, not that
# the launcher pod was actually removed or that KubeVirt replaced it; this check
# independently confirms the effect and logs it as informational evidence only
# (it never changes the trigger's exit status, which stays governed by the
# existing backup-outcome logic below).
verify_launcher_disruption_and_recovery() {
  local old_pod="$1" old_uid="$2" start=$SECONDS deadline=$((SECONDS + 120))
  local old_pod_json old_pod_gone=false replacement_ready=false elapsed within_120s=false
  local replacement_pods_json replacement replacement_name='' replacement_uid=''
  while ((SECONDS < deadline)); do
    old_pod_json="$(oc get pod "$old_pod" -n "$NAMESPACE" -o json --ignore-not-found 2>/dev/null || true)"
    if [[ -z "$old_pod_json" ]] || [[ "$(jq -r '.metadata.uid // empty' <<<"$old_pod_json")" != "$old_uid" ]]; then
      old_pod_gone=true
    fi
    if [[ "$old_pod_gone" == true ]]; then
      replacement_pods_json="$(oc get pods -n "$NAMESPACE" \
        -l "vm.kubevirt.io/name=${VM_NAME}" -o json 2>/dev/null || true)"
      replacement=''
      if [[ -n "$replacement_pods_json" ]]; then
        replacement="$(jq -r --arg uid "$old_uid" '
          [.items[] | select(.metadata.uid != $uid and .status.phase == "Running" and
            any((.status.conditions // [])[]?; .type == "Ready" and .status == "True"))]
          | first
          | if . == null then "" else [(.metadata.name // ""), (.metadata.uid // "")] | @tsv end' \
          <<<"$replacement_pods_json" 2>/dev/null || true)"
      fi
      replacement_name="${replacement%%$'\t'*}"
      replacement_uid="${replacement##*$'\t'}"
      # A replacement only counts once its identity is recorded: an empty match
      # must keep polling rather than report readiness without a UID.
      if [[ -n "$replacement_name" && -n "$replacement_uid" ]]; then
        replacement_ready=true
        break
      fi
      replacement_name=''
      replacement_uid=''
    fi
    sleep 1
  done
  elapsed=$((SECONDS - start))
  if [[ "$old_pod_gone" == true && "$replacement_ready" == true ]]; then
    within_120s=true
    log "Independent effect check: launcher pod $old_pod (UID $old_uid) was replaced and the new launcher is Ready (${elapsed}s)."
  else
    log "Independent effect check: could not confirm launcher-pod replacement/readiness within 120s (old_pod_gone=$old_pod_gone, replacement_ready=$replacement_ready); treat the injection effect as unverified beyond the delete request."
  fi
  write_json "$EVIDENCE_DIR/effect-check.json" \
    --arg run_id "$RUN_ID" \
    --arg namespace "$NAMESPACE" \
    --arg old_pod "$old_pod" \
    --arg old_pod_uid "$old_uid" \
    --arg replacement_name "$replacement_name" \
    --arg replacement_uid "$replacement_uid" \
    --argjson old_pod_gone "$old_pod_gone" \
    --argjson replacement_ready "$replacement_ready" \
    --argjson elapsed_seconds "$elapsed" \
    --argjson within_120s "$within_120s" \
    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id:$run_id, namespace:$namespace, utc:$utc,
      old_pod:{name:$old_pod, uid:$old_pod_uid},
      old_pod_gone:$old_pod_gone,
      replacement_pod:{name:$replacement_name, uid:$replacement_uid, ready:$replacement_ready},
      elapsed_seconds:$elapsed_seconds, within_120s:$within_120s}'
}

observe_copy_then_disrupt() {
  local deadline=$((SECONDS + 3600)) pod pod_uid baseline_tree existing_tracker
  local baseline_captured=false baseline_status=0 baseline_lines=0 signal_line signal_utc
  # Arming time: the log follow may only match `Backup started` lines emitted at
  # or after this instant, so a stale line from an earlier backup on a long-lived
  # pod cannot fire a false injection.
  local armed_utc
  armed_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "Observer armed at $armed_utc; the log follow uses --since-time=$armed_utc."
  while ((SECONDS < deadline)); do
    pod="$(oc get pods -n "$NAMESPACE" \
      -l "vm.kubevirt.io/name=${VM_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      if [[ "$baseline_captured" == false ]]; then
        baseline_status=0
        baseline_tree="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
          virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree 2>/dev/null)" || baseline_status=$?
        baseline_lines="$(printf '%s\n' "$baseline_tree" | awk 'NF { count++ } END { print count + 0 }')"
        if ((baseline_status != 0)); then
          # A failed capture must not look like a fresh VM's empty tree: record
          # the exit status and retry on the next poll instead of logging a
          # blank block that reads as "no checkpoints yet".
          log "Checkpoint tree capture failed (exit=$baseline_status, lines=$baseline_lines); retrying on the next poll."
        else
          existing_tracker="$(oc get vmbackuptracker "vm-tracker-${RUN_ID}" \
            -n "$NAMESPACE" --ignore-not-found -o name)"
          if [[ -n "$existing_tracker" ]]; then
            log 'Tracker already exists before this run; refusing to inject.'
            return 1
          fi
          log "$(printf 'Pre-backup tracker: absent\nPre-backup checkpoint tree (exit=0, lines=%s; empty is expected on a fresh lifecycle):\n%s' \
            "$baseline_lines" "$baseline_tree")"
          baseline_captured=true
        fi
      fi
      if [[ "$baseline_captured" == true ]]; then
        signal_line=""
        signal_line="$(set +o pipefail
          oc logs --follow --since-time="$armed_utc" -n "$NAMESPACE" "$pod" -c compute 2>/dev/null |
            grep -F -m1 'Backup started')" || true
        if [[ -n "$signal_line" ]]; then
          signal_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          pod_uid="$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
          log "Active-copy signal from launcher pod $pod (UID $pod_uid) at $signal_utc: $signal_line"
          write_json "$EVIDENCE_DIR/action-request.json" \
            --arg run_id "$RUN_ID" \
            --arg lifecycle_id "$LIFECYCLE_ID" \
            --arg utc_action_request "$signal_utc" \
            --arg namespace "$NAMESPACE" \
            --arg vm "$VM_NAME" \
            --arg pod "$pod" \
            --arg pod_uid "$pod_uid" \
            --arg signal_line "$signal_line" \
            --arg signal_utc "$signal_utc" \
            --arg utc_observer_armed "$armed_utc" \
            --arg since_time "$armed_utc" \
            '{run_id:$run_id, lifecycle_id:$lifecycle_id, utc_action_request:$utc_action_request,
              namespace:$namespace, vm:$vm, pod:$pod, pod_uid:$pod_uid, signal_line:$signal_line,
              signal_utc:$signal_utc, utc_observer_armed:$utc_observer_armed, since_time:$since_time}'
          : > "$SIGNAL_FILE"
          oc delete pod "$pod" -n "$NAMESPACE" --wait=false
          verify_launcher_disruption_and_recovery "$pod" "$pod_uid"
          return
        fi
      fi
    fi
    sleep 1
  done
  log 'Timed out waiting for the pre-backup baseline and active-copy log signal.'
  return 1
}

observe_copy_then_disrupt &
observer_pid=$!

e2e_args=()
for e2e_arg in "${E2E_ARGS[@]}"; do
  if [[ "$e2e_arg" == 'KUBECONFIG_PATH=__KUBECONFIG__' ]]; then
    e2e_arg="KUBECONFIG_PATH=$KUBECONFIG_PATH"
  fi
  e2e_args+=("$e2e_arg")
done
if make e2e "${e2e_args[@]}"; then
  e2e_status=0
else
  e2e_status=$?
fi

if [[ ! -e "$SIGNAL_FILE" ]]; then
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
observer_pid=
trap - EXIT INT TERM
rm -f "$SIGNAL_FILE"

write_json "$EVIDENCE_DIR/exit-statuses.json" \
  --argjson e2e_status "$e2e_status" \
  --argjson observer_status "$observer_status" \
  --arg expectation 'e2e_nonzero_expected' \
  --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{e2e_status:$e2e_status, observer_status:$observer_status, expectation:$expectation, utc:$utc}'

log "E2E exit status: $e2e_status; event observer/Krkn exit status: $observer_status"
if ((observer_status != 0)); then
  log "Arbitration: the observer did not establish the injection boundary (status $observer_status); exiting with the observer status $observer_status."
  exit "$observer_status"
fi
if ((e2e_status == 0)); then
  log 'The full backup succeeded; CBT-F-01 expected interruption to fail it.'
  log 'Arbitration: the E2E unexpectedly succeeded (status 0) after the injection was requested; exiting 1.'
  exit 1
fi
log "Arbitration: the E2E failed as expected (status $e2e_status) after the injection; exiting with the E2E status $e2e_status."
exit "$e2e_status"
