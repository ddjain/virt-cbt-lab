#!/usr/bin/env bash
set -euo pipefail

# One entry point for the lifecycle stages. It owns three things the stage
# scripts deliberately do not: run identity resolution for existing lifecycles,
# the preflight policy, and the standalone "what do I run next" hints.
#
# `make e2e` (scripts/e2e-stage.sh) sets E2E_STAGE_WRAPPED=true: in that mode
# this script must be invisible, so it only builds the stage's argv and `exec`s
# it. stdout, stderr, and the exit status are then identical to calling the
# stage script directly, which is what keeps the pipeline's output stable.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
SELF="scripts/stage.sh"

# run-id.sh is path-only (no kubeconfig, no cluster, no profile validation), so
# the planning paths -- list, --help, and --dry-run -- resolve identity and
# build their command from it without paying for scripts/common.sh. Real
# execution sources common.sh below, exactly as the stage scripts do.
# shellcheck source=scripts/run-id.sh
source "$SCRIPT_DIR/run-id.sh"

# Stage metadata is written once, as "stage|make target|required args|purpose".
# `list` renders it TAB separated, and the same table answers "which make
# target runs this stage?" for the usage hints.
STAGE_TABLE=(
  "preflight|preflight|none|Run the read-only cluster preflight checks (./preflight)"
  "setup|vm-setup|RUN_ID=<id> or NAME=<id> (both optional; generated when unset)|Create a new VM lifecycle and its baseline workload (scripts/windows-vm-setup.sh when VM_OS=windows)"
  "full|vm-backup|RUN_ID or VM=vm-<run-id>|Create the full (baseline) backup and enable CBT on the tracker"
  "incremental|vm-cbt-backup|RUN_ID or VM=vm-<run-id>|Create the next incremental CBT backup pass"
  "extend|vm-cbt-extend|RUN_ID or VM=vm-<run-id>, EXTEND_TO_PASS|Extend the saved lifecycle plan by one incremental pass"
  "recover|vm-cbt-recover|RUN_ID or VM=vm-<run-id>|Recover a failed lifecycle with a forced full backup on the same tracker"
  "reconcile|vm-cbt-reconcile|RUN_ID or VM=vm-<run-id>|Reconcile tracker and checkpoint state with the API"
  "verify|vm-cbt-verify|RUN_ID or VM=vm-<run-id>|Verify the incremental chain file sets against the tracker"
  "restore-test|vm-cbt-restore-test|RUN_ID or VM=vm-<run-id>|Restore the full backup into a test PVC and verify the workload"
  "monitor|monitor|RUN_ID or VM=vm-<run-id>|Print API-recorded backup start/done timings (read-only)"
  "summary|run-summary|RUN_ID or VM=vm-<run-id>|Write runs/<id>/summary.json with the lifecycle verdict"
)

# Stages that change cluster or run state; these run preflight first unless it
# is skipped explicitly. verify/restore-test/monitor/summary are read-only and
# never pay for it (make e2e runs preflight once up front).
MUTATING_STAGES=(setup full incremental extend recover reconcile)
# Every other stage operates on an existing lifecycle: it needs RUN_ID or VM
# plus the runs/<id>/run.json written by the setup stage.
# Stage -> stage script aliases accepted on the command line.
STAGE_ALIASES="vm-setup->setup, vm-backup->full, vm-cbt-backup->incremental, vm-cbt-extend->extend, vm-cbt-recover->recover, vm-cbt-reconcile->reconcile, vm-cbt-verify->verify, vm-cbt-restore-test->restore-test"

CHILD_CMD=()
PREFLIGHT_CMD=()

usage_error() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  printf 'Run "%s --help" for usage.\n' "$SELF" >&2
  exit 2
}

print_help() {
  cat >&2 <<EOF
Usage: $SELF <stage> [--dry-run]
       $SELF --dry-run <stage>
       $SELF list
       $SELF -h|--help

Stages (aliases in parentheses):
  preflight                        run ./preflight (adds --verbose when DEBUG=true)
  setup        (vm-setup)          create a new VM lifecycle + baseline workload
  full         (vm-backup)         create the full (baseline) backup
  incremental  (vm-cbt-backup)     create the next incremental backup pass
  extend       (vm-cbt-extend)     add one incremental pass beyond the plan
  recover      (vm-cbt-recover)    recover with a forced full backup
  reconcile    (vm-cbt-reconcile)  reconcile tracker/checkpoint state
  verify       (vm-cbt-verify)     verify the incremental chain file sets
  restore-test (vm-cbt-restore-test) restore the full backup and verify it
  monitor                          print API-recorded backup timings
  summary                          write runs/<id>/summary.json

  list                             print the stage table (TAB separated)

Inputs (environment, exported by the Makefile):
  RUN_ID, NAME, VM, EXISTING_VM, VM_OS, NAMESPACE, DEBUG, KUBECONFIG_PATH,
  MANIFEST_VARIANT, GUEST_*, EXTEND_TO_PASS, TYPE, STAGE_RESULT

  RUN_ID or VM=vm-<run-id> selects an existing lifecycle for every stage except
  setup/preflight. setup starts the lifecycle instead: RUN_ID=<id> (or its
  documented NAME=<id> selector, promoted to RUN_ID here) fixes the ID, else
  new_run_id generates one. summary labels its verdict with \${TYPE:-all} and
  \${STAGE_RESULT:-INCOMPLETE}.

Knobs:
  STAGE_DRY_RUN=true          print the resolved identity and the exact command
                              that would run, then exit 0 (no cluster access)
  STAGE_SKIP_PREFLIGHT=true   skip the automatic preflight before mutating stages
  E2E_STAGE_WRAPPED=true      passthrough mode used by make e2e: no preflight,
                              no identity errors, no post-stage hints

Exit codes: 2 for usage/identity errors, otherwise the stage's own exit status.
EOF
}

print_stage_list() {
  local row stage target required_args description
  for row in "${STAGE_TABLE[@]}"; do
    IFS='|' read -r stage target required_args description <<<"$row"
    printf '%s\t%s\t%s\t%s\n' "$stage" "$target" "$required_args" "$description"
  done
}

stage_make_target() {
  local row stage target
  for row in "${STAGE_TABLE[@]}"; do
    IFS='|' read -r stage target _ _ <<<"$row"
    if [[ "$stage" == "$1" ]]; then
      printf '%s' "$target"
      return 0
    fi
  done
  return 1
}

is_canonical_stage() {
  local row stage
  for row in "${STAGE_TABLE[@]}"; do
    IFS='|' read -r stage _ _ _ <<<"$row"
    [[ "$stage" == "$1" ]] && return 0
  done
  return 1
}

stage_names_csv() {
  local row stage names=""
  for row in "${STAGE_TABLE[@]}"; do
    IFS='|' read -r stage _ _ _ <<<"$row"
    names+="${names:+, }$stage"
  done
  printf '%s' "$names"
}

canonical_stage() {
  case "$1" in
    vm-setup) printf 'setup' ;;
    vm-backup) printf 'full' ;;
    vm-cbt-backup) printf 'incremental' ;;
    vm-cbt-extend) printf 'extend' ;;
    vm-cbt-recover) printf 'recover' ;;
    vm-cbt-reconcile) printf 'reconcile' ;;
    vm-cbt-verify) printf 'verify' ;;
    vm-cbt-restore-test) printf 'restore-test' ;;
    *) printf '%s' "$1" ;;
  esac
}

in_list() {
  local candidate="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$candidate" ]] && return 0
  done
  return 1
}

stage_is_mutating() { in_list "$1" "${MUTATING_STAGES[@]}"; }

# Non-wrapped mode: RUN_ID wins over VM (same acceptance rules as load_run_id),
# and the identity becomes part of the child's environment.
resolve_identity() {
  local stage="$1"
  if [[ -z "${RUN_ID:-}" && -n "${VM:-}" ]]; then
    if [[ "$VM" != vm-* ]]; then
      printf '%s: VM must be a workflow VM name in the form vm-<run-id> (got: %s).\n' "$SELF" "$VM" >&2
      exit 2
    fi
    RUN_ID="${VM#vm-}"
  fi
  if [[ -z "${RUN_ID:-}" ]]; then
    identity_usage_error "$stage"
  fi
  if ! valid_run_id "$RUN_ID"; then
    printf '%s: Run ID must be lowercase alphanumeric with internal hyphens and at most 40 characters (got: %s).\n' \
      "$SELF" "$RUN_ID" >&2
    exit 2
  fi
  set_resource_names
  export RUN_ID VM_NAME
}

# The setup stage is the only stage that accepts NAME as a run-id selector, but
# vm-setup.sh/new_run_id read RUN_ID only: without this promotion `NAME=foo`
# would silently generate a random run ID. RUN_ID always wins when both are set.
apply_setup_name() {
  if [[ -n "${RUN_ID:-}" || -z "${NAME:-}" ]]; then
    return 0
  fi
  if ! valid_run_id "$NAME"; then
    printf '%s: stage "setup" takes NAME=<id> as its run ID, but NAME is not a legal run ID: lowercase alphanumeric with internal hyphens, at most 40 characters (got: %s).\n' \
      "$SELF" "$NAME" >&2
    printf '  %s setup NAME=<id>\n' "$SELF" >&2
    exit 2
  fi
  RUN_ID="$NAME"
  export RUN_ID
}

# Lenient variant for wrapped mode and for the stages that resolve their own
# identity: derive what the child's argv needs, never fail.
resolve_identity_lenient() {
  # Export derived values only: an unset RUN_ID must stay unset, so every stage
  # script keeps seeing exactly the environment it was handed.
  if [[ -z "${RUN_ID:-}" && -n "${VM:-}" && "$VM" == vm-* ]]; then
    RUN_ID="${VM#vm-}"
    export RUN_ID
  fi
  if [[ -z "${VM_NAME:-}" && -n "${RUN_ID:-}" ]]; then
    VM_NAME="vm-$RUN_ID"
    export VM_NAME
  elif [[ -z "${VM_NAME:-}" && -n "${VM:-}" ]]; then
    VM_NAME="$VM"
    export VM_NAME
  fi
}

# Up to 5 existing lifecycles, newest first (the run ID is the directory name).
# `ls -1t` is the portable way to order by mtime; run IDs are validated as
# lowercase alphanumeric with hyphens, so no name can be split by word splitting.
existing_run_ids() {
  local name
  for name in $(ls -1t "$RUNS_ROOT_DIR" 2>/dev/null); do
    [[ -f "$RUNS_ROOT_DIR/$name/run.json" ]] || continue
    printf '%s\n' "$name"
  done
}

identity_usage_error() {
  local stage="$1" target run_id shown=0
  local -a run_ids=()
  target="$(stage_make_target "$stage")"
  while IFS= read -r run_id; do
    run_ids+=("$run_id")
  done < <(existing_run_ids)

  {
    printf '%s: stage "%s" needs an existing lifecycle: set RUN_ID=<id> or VM=vm-<id>.\n' "$SELF" "$stage"
    printf '  %s %s RUN_ID=<id>\n' "$SELF" "$stage"
    printf '  %s %s VM=vm-<id>\n' "$SELF" "$stage"
    printf '  make %s RUN_ID=<id>\n' "$target"
    if ((${#run_ids[@]} == 0)); then
      printf 'No recorded lifecycles under runs/ (no runs/*/run.json yet); create one first:\n'
      printf '  make vm-setup\n'
    else
      printf 'Existing lifecycles (showing %d of %d, newest first):\n' \
        "$(( ${#run_ids[@]} < 5 ? ${#run_ids[@]} : 5 ))" "${#run_ids[@]}"
      for run_id in "${run_ids[@]}"; do
        printf '  %s\n' "$run_id"
        shown=$((shown + 1))
        ((shown < 5)) || break
      done
    fi
  } >&2
  exit 2
}

require_run_metadata() {
  if [[ -r "$VM_INFO_PATH" ]]; then
    return 0
  fi
  {
    printf '%s: run "%s" has no recorded setup: %s is missing.\n' \
      "$SELF" "$RUN_ID" "${VM_INFO_PATH#"$ROOT_DIR/"}"
    printf 'Create the lifecycle first:\n'
    printf '  make vm-setup RUN_ID=%s\n' "$RUN_ID"
  } >&2
  exit 2
}

require_extend_to_pass() {
  local target="${EXTEND_TO_PASS:-}"
  if [[ ! "$target" =~ ^[1-9][0-9]?$ ]] || ((target < 2 || target > 99)); then
    {
      printf '%s: stage "extend" requires EXTEND_TO_PASS to be the target total from 2 to 99' "$SELF"
      if [[ -n "$target" ]]; then printf ' (got: %s)' "$target"; fi
      printf '.\n'
      printf 'Set it to the saved completed-pass count plus one, for example:\n'
      printf '  %s extend RUN_ID=%s EXTEND_TO_PASS=2\n' "$SELF" "${RUN_ID:-<id>}"
      printf '  make vm-cbt-extend RUN_ID=%s EXTEND_TO_PASS=2\n' "${RUN_ID:-<id>}"
    } >&2
    exit 2
  fi
}

build_preflight_command() {
  PREFLIGHT_CMD=("$ROOT_DIR/preflight")
  # make preflight shows verbose output when DEBUG=true; keep that here.
  if [[ "$DEBUG" == true ]]; then
    PREFLIGHT_CMD+=(--verbose)
  fi
}

build_child_command() {
  local stage="$1"
  CHILD_CMD=()
  case "$stage" in
    preflight) CHILD_CMD=("${PREFLIGHT_CMD[@]}") ;;
    setup)
      if [[ "$VM_OS" == windows ]]; then
        CHILD_CMD=("$SCRIPT_DIR/windows-vm-setup.sh")
      else
        CHILD_CMD=("$SCRIPT_DIR/vm-setup.sh")
      fi
      ;;
    full) CHILD_CMD=("$SCRIPT_DIR/vm-backup.sh") ;;
    incremental) CHILD_CMD=("$SCRIPT_DIR/vm-cbt-backup.sh") ;;
    extend) CHILD_CMD=("$SCRIPT_DIR/vm-cbt-extend.sh") ;;
    recover) CHILD_CMD=("$SCRIPT_DIR/vm-cbt-recover.sh") ;;
    reconcile) CHILD_CMD=("$SCRIPT_DIR/vm-cbt-reconcile.sh") ;;
    verify) CHILD_CMD=("$SCRIPT_DIR/vm-cbt-verify.sh") ;;
    restore-test) CHILD_CMD=("$SCRIPT_DIR/vm-cbt-restore-test.sh") ;;
    monitor) CHILD_CMD=("$SCRIPT_DIR/monitor.sh" "${VM_NAME:-}") ;;
    summary)
      CHILD_CMD=("$SCRIPT_DIR/write-run-summary.sh" "$RUN_ID" "${TYPE:-all}" "${STAGE_RESULT:-INCOMPLETE}")
      ;;
    *) return 1 ;;
  esac
}

# Repository-relative evidence path, so the hints stay copy-pasteable.
relative_to_repo() {
  printf '%s' "${1#"$ROOT_DIR/"}"
}

print_success_hints() {
  local stage="$1" next run_id path
  run_id="${RUN_ID:-}"
  {
    printf '\n%s: stage "%s" completed.\n' "$SELF" "$stage"
  } >&2
  if [[ -n "$run_id" ]]; then
    printf '  run id    %s\n' "$run_id" >&2
    for path in "$RUNS_ROOT_DIR/$run_id/run.json" "$RUNS_ROOT_DIR/$run_id/logs/workflow.log" \
      "$RUNS_ROOT_DIR/$run_id/report.json" "$RUNS_ROOT_DIR/$run_id/summary.json"; do
      # run.json and the workflow log are created by the lifecycle; the reports
      # only exist once a stage writes them.
      if [[ -e "$path" ]]; then
        printf '  evidence  %s\n' "$(relative_to_repo "$path")" >&2
      fi
    done
  else
    if [[ "$stage" == preflight ]]; then
      printf '  run id    (not applicable: preflight reads the cluster, not a run)\n' >&2
    else
      printf '  run id    (generated by the setup stage: the newest directory under runs/)\n' >&2
    fi
  fi
  next="$(next_stage_command "$stage")"
  if [[ -n "$next" ]]; then
    printf '  next      %s\n' "$next" >&2
  else
    printf '  next      none; lifecycle complete\n' >&2
  fi
}

next_stage_command() {
  case "$1" in
    preflight) printf 'make vm-setup' ;;
    setup) printf 'make vm-backup RUN_ID=%s' "${RUN_ID:-<id>}" ;;
    full) printf 'make vm-cbt-backup RUN_ID=%s' "$RUN_ID" ;;
    incremental) printf 'make vm-cbt-verify RUN_ID=%s' "$RUN_ID" ;;
    extend) printf 'make vm-cbt-verify RUN_ID=%s' "$RUN_ID" ;;
    recover) printf 'make vm-cbt-reconcile RUN_ID=%s' "$RUN_ID" ;;
    reconcile) printf 'make vm-cbt-verify RUN_ID=%s' "$RUN_ID" ;;
    verify) printf 'make run-summary RUN_ID=%s' "$RUN_ID" ;;
    restore-test) printf 'make run-summary RUN_ID=%s' "$RUN_ID" ;;
    monitor) printf 'make run-summary RUN_ID=%s' "$RUN_ID" ;;
    *) printf '' ;;
  esac
}

# "Would preflight run?" for the dry-run report. Wrapped mode reports skipped
# because the stage would not get this far: e2e-stage.sh runs preflight itself.
describe_preflight_policy() {
  local stage="$1"
  if [[ "$stage" == preflight ]]; then
    printf 'is the stage (see the command below)'
  elif ! stage_is_mutating "$stage"; then
    printf 'not required for the read-only "%s" stage' "$stage"
  elif [[ "$STAGE_SKIP_PREFLIGHT" == true ]]; then
    printf 'skipped (STAGE_SKIP_PREFLIGHT=true)'
  elif [[ "$E2E_STAGE_WRAPPED" == true ]]; then
    printf 'skipped (E2E_STAGE_WRAPPED=true: make e2e runs preflight once up front)'
  else
    printf 'would run first:'
    printf ' %q' "${PREFLIGHT_CMD[@]}"
  fi
}

detect_new_run_id() {
  local before="$1" after="$2" dir
  # Report the lifecycle this stage just created, for setup runs that did not
  # name their own run ID. Names never contain whitespace.
  for dir in $after; do
    case " $before " in
      *" $dir "*) continue ;;
    esac
    printf '%s\n' "${dir##*/}"
  done
}

snapshot_run_dirs() {
  local path
  for path in "$RUNS_ROOT_DIR"/*/run.json; do
    [[ -e "$path" ]] || continue
    printf '%s ' "${path%/run.json}"
  done
}

print_dry_run() {
  local stage="$1"
  printf '%s: dry run for stage "%s" (nothing executed, no cluster access).\n' "$SELF" "$stage"
  if [[ -n "${RUN_ID:-}" ]]; then
    printf '  RUN_ID    %s\n' "$RUN_ID"
    if [[ -n "${VM_NAME:-}" ]]; then
      printf '  VM_NAME   %s\n' "$VM_NAME"
    fi
    if [[ -n "${VM_INFO_PATH:-}" ]]; then
      if [[ -r "$VM_INFO_PATH" ]]; then
        printf '  run.json  %s (present)\n' "$(relative_to_repo "$VM_INFO_PATH")"
      else
        printf '  run.json  %s (missing; a real %s run needs: make vm-setup RUN_ID=%s)\n' \
          "$(relative_to_repo "$VM_INFO_PATH")" "$stage" "$RUN_ID"
      fi
    fi
  else
    if [[ "$stage" == preflight ]]; then
      printf '  RUN_ID    unset (preflight reads the cluster, not a run)\n'
    else
      printf '  RUN_ID    unset; the "%s" stage resolves its own run ID (new_run_id)\n' "$stage"
    fi
  fi
  printf '  preflight %s\n' "$(describe_preflight_policy "$stage")"
  printf '  command'
  printf ' %q' "${CHILD_CMD[@]}"
  printf '\n'
}

require_extend_to_pass_if_needed() {
  if [[ "$1" == extend ]]; then
    require_extend_to_pass
  fi
}

# Shares scripts/e2e-stage.sh's checkout-wide lock so a standalone mutating
# stage (e.g. a direct `make vm-backup`) cannot race another standalone
# mutating stage or a concurrent `make e2e` in the same checkout. Not called in
# E2E_STAGE_WRAPPED mode: the wrapping e2e-stage.sh already holds this lock for
# the whole pipeline.
acquire_checkout_lock() {
  local lock_dir="$ROOT_DIR/state/e2e.lock" lock_pid
  mkdir -p "$ROOT_DIR/state"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
      printf '%s: another E2E/stage operation is active in this checkout (PID %s); run lifecycle commands sequentially.\n' \
        "$SELF" "$lock_pid" >&2
      exit 1
    fi
    rm -rf "$lock_dir"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      printf '%s: could not acquire checkout lock at %s.\n' "$SELF" "$lock_dir" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$$" > "$lock_dir/pid"
  printf -v _release_lock_cmd 'rm -rf %q' "$lock_dir"
  trap "$_release_lock_cmd" EXIT
}

main() {
  local stage_arg="" dry_run="${STAGE_DRY_RUN:-false}" arg stage status setup_dirs_before=""

  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      -h | --help)
        print_help
        exit 0
        ;;
      -*) usage_error "unknown option: $arg" ;;
      *)
        if [[ -n "$stage_arg" ]]; then
          usage_error "unexpected extra argument: $arg"
        fi
        stage_arg="$arg"
        ;;
    esac
  done

  case "$dry_run" in
    true | false) ;;
    *) usage_error "STAGE_DRY_RUN must be true or false (got: $dry_run)." ;;
  esac

  if [[ -z "$stage_arg" ]]; then
    usage_error "missing stage name; expected one of: $(stage_names_csv) (or list)"
  fi

  # list stays usable with any environment: it needs neither the shared helpers
  # nor a run (and --dry-run is a no-op for it).
  if [[ "$stage_arg" == "list" ]]; then
    print_stage_list
    exit 0
  fi

  stage="$(canonical_stage "$stage_arg")"
  if ! is_canonical_stage "$stage"; then
    usage_error "unknown stage \"$stage_arg\"; aliases: $STAGE_ALIASES"
  fi

  STAGE_SKIP_PREFLIGHT="${STAGE_SKIP_PREFLIGHT:-false}"
  E2E_STAGE_WRAPPED="${E2E_STAGE_WRAPPED:-false}"

  if [[ "$dry_run" == true ]]; then
    # Planning only: resolve identity from run-id.sh and the local runs/ tree,
    # never from common.sh, so an unreadable kubeconfig or an invalid guest
    # profile cannot block a report that promises to touch nothing. Preflight is
    # described, a missing run.json is reported instead of fatal, and a missing
    # preflight/DEBUG/VM_OS value is only needed to render the command.
    RUNS_ROOT_DIR="$ROOT_DIR/runs"
    VM_OS="${VM_OS:-rhel9}"
    DEBUG="${DEBUG:-false}"
    build_preflight_command
    if ! in_list "$stage" preflight setup; then
      resolve_identity "$stage"
      require_extend_to_pass_if_needed "$stage"
    elif [[ "$stage" == setup ]]; then
      # NAME is the setup stage's documented run-id selector; promote it so the
      # report names the run the stage will actually use.
      apply_setup_name
      if [[ -n "${RUN_ID:-}" ]]; then
        set_resource_names
      fi
    fi
    build_child_command "$stage"
    print_dry_run "$stage"
    exit 0
  fi

  # Real execution reads the shared workflow defaults and helpers, exactly as
  # the stage scripts do (VM_OS/MANIFEST_VARIANT/GUEST_* and kubeconfig checks
  # included).
  # shellcheck source=scripts/common.sh
  source "$ROOT_DIR/scripts/common.sh"
  # The dispatcher reports its own errors; common.sh's ERR trap would label any
  # failure "workflow startup failed", which is wrong here and would be noise in
  # wrapped mode. Stage scripts re-install their own trap in their own process.
  trap - ERR
  build_preflight_command

  if [[ "$E2E_STAGE_WRAPPED" == true ]]; then
    # Passthrough: the caller already resolved identity and ran preflight (and,
    # for mutating stages, already holds the checkout lock below). Keep this
    # branch free of our own diagnostics so the child's output and exit status
    # are exactly what a direct invocation produces.
    resolve_identity_lenient
    build_child_command "$stage"
    exec "${CHILD_CMD[@]}"
  fi

  if stage_is_mutating "$stage"; then
    acquire_checkout_lock
  fi

  if [[ "$stage" == preflight || "$stage" == setup ]]; then
    # Neither stage resolves an identity here: preflight reads the cluster, and
    # setup calls new_run_id itself (RUN_ID/NAME/EXISTING_VM are passed straight
    # through, except NAME, which becomes RUN_ID because that is the only
    # variable new_run_id reads).
    if [[ "$stage" == setup ]]; then
      apply_setup_name
      # The snapshot only lets the hints name a run the stage generated itself.
      if [[ -z "${RUN_ID:-}" ]]; then
        setup_dirs_before="$(snapshot_run_dirs)"
      fi
    fi
    build_child_command "$stage"
  else
    resolve_identity "$stage"
    require_extend_to_pass_if_needed "$stage"
    require_run_metadata
    build_child_command "$stage"
  fi

  if stage_is_mutating "$stage" && [[ "$STAGE_SKIP_PREFLIGHT" != true ]]; then
    printf '%s: running %q before the "%s" stage (STAGE_SKIP_PREFLIGHT=true to skip).\n' \
      "$SELF" "${PREFLIGHT_CMD[0]}" "$stage" >&2
    # Propagate preflight's status and stop: the stage must not run.
    "${PREFLIGHT_CMD[@]}" || exit $?
  fi

  if "${CHILD_CMD[@]}"; then
    if [[ "$stage" == setup && -z "${RUN_ID:-}" ]]; then
      RUN_ID="$(detect_new_run_id "$setup_dirs_before" "$(snapshot_run_dirs)")"
      # More than one lifecycle appeared: do not guess which one is ours.
      if [[ "$RUN_ID" == *$'\n'* ]]; then
        RUN_ID=""
      fi
    fi
    print_success_hints "$stage"
    exit 0
  else
    status=$?
    exit "$status"
  fi
}

main "$@"
