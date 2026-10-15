#!/usr/bin/env bash
set -euo pipefail

# Hermetic checks for scripts/stage.sh, the single dispatcher every stage goes
# through, and for the Makefile wiring that funnels the individual targets into
# it. No cluster access: every command runs against a throwaway copy of the
# repository, with a stub `oc` on PATH that records any attempt to reach the
# cluster and a stub ./preflight that records the automatic preflight policy.
#
# Covered invariants:
#   1. `list` prints the 11 canonical stages, TAB separated, with the Makefile's
#      target names.
#   2. Legacy Make target names are aliases of the canonical stage names.
#   3. Usage errors exit 2 with actionable text (missing identity, unknown
#      stage, missing EXTEND_TO_PASS).
#   4. An existing lifecycle is required for non-setup stages, and a missing
#      runs/<id>/run.json names the exact `make vm-setup RUN_ID=<id>` remedy.
#   5. Dry runs never contact the cluster.
#   6. E2E_STAGE_WRAPPED=true is a byte-identical passthrough (stdout, stderr,
#      exit status).
#   7. Every stage target invokes ./scripts/stage.sh <expected stage>.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN="$TEST_TMP/bin"
TEST_ROOT="$TEST_TMP/repo"

# ---------------------------------------------------------------------------
# Assertions. Every failure names the invariant and the observed value, then
# dumps the stdout/stderr of the command that produced it.
# ---------------------------------------------------------------------------
die() {
  printf 'FAIL: %s\n' "$1" >&2
  printf '  last command: %s\n' "${LAST_CMD:-<none>}" >&2
  printf '  exit status:  %s\n' "${STATUS:-<none>}" >&2
  if [[ -n "${OUT_FILE:-}" && -f "${OUT_FILE:-}" ]]; then
    printf -- '--- stdout ---\n%s\n' "$(cat "$OUT_FILE")" >&2
    printf -- '--- stderr ---\n%s\n' "$(cat "$ERR_FILE")" >&2
  fi
  exit 1
}

assert_status() { # <description> <expected status> <observed status>
  [[ "$3" == "$2" ]] || die "$1: expected exit status $2, got $3"
}

assert_eq() { # <description> <expected> <observed>
  [[ "$3" == "$2" ]] || die "$1: expected [$2], got [$3]"
}

assert_contains() { # <description> <haystack> <needle>
  [[ "$2" == *"$3"* ]] || die "$1: expected output containing [$3], got [$2]"
}

assert_not_contains() { # <description> <haystack> <needle>
  [[ "$2" != *"$3"* ]] || die "$1: expected output WITHOUT [$3], got [$2]"
}

# Runs a command inside the throwaway repository with the stub binaries first on
# PATH and the workflow's identity variables cleared, so the result never
# depends on the caller's environment (or on `make test`'s exported variables).
BASE_ENV=(
  env -u RUN_ID -u VM -u VM_NAME -u NAME -u EXISTING_VM -u TYPE -u POOL
  -u EXTEND_TO_PASS -u STAGE_DRY_RUN -u STAGE_SKIP_PREFLIGHT -u E2E_STAGE_WRAPPED
  -u STAGE_RESULT -u DEBUG -u KUBECONFIG -u KUBECONFIG_PATH -u MAKEFLAGS -u MAKELEVEL -u MFLAGS
)
run_cmd() { # run_cmd <label> <command...>; sets STATUS, OUT, ERR
  local label="$1"
  shift
  LAST_CMD="$*"
  OUT_FILE="$TEST_TMP/$label.out"
  ERR_FILE="$TEST_TMP/$label.err"
  local status=0
  (cd "$TEST_ROOT" && PATH="$FAKE_BIN:$PATH" "${BASE_ENV[@]}" "$@") >"$OUT_FILE" 2>"$ERR_FILE" || status=$?
  STATUS="$status"
  OUT="$(cat "$OUT_FILE")"
  ERR="$(cat "$ERR_FILE")"
}

# ---------------------------------------------------------------------------
# Fixtures: throwaway repo copy + stubs.
# ---------------------------------------------------------------------------
mkdir -p "$FAKE_BIN" "$TEST_ROOT/scripts"
cp "$ROOT_DIR/scripts/stage.sh" "$ROOT_DIR/scripts/common.sh" "$ROOT_DIR/scripts/run-id.sh" \
  "$ROOT_DIR/scripts/monitor.sh" "$TEST_ROOT/scripts/"
cp "$ROOT_DIR/Makefile" "$TEST_ROOT/Makefile"
TEST_STAGE="$TEST_ROOT/scripts/stage.sh"

export CLUSTER_MARKER="$TEST_TMP/oc-invoked"
export PREFLIGHT_MARKER="$TEST_TMP/preflight-invoked"

# Stub oc: any cluster access is recorded and fails loudly.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
printf 'CLUSTER ACCESS ATTEMPTED\n'
printf 'oc %s\n' "$*" >> "$CLUSTER_MARKER"
exit 42
FAKE_OC
chmod +x "$FAKE_BIN/oc"

# Stub ./preflight: records that the dispatcher's automatic preflight policy ran.
cat > "$TEST_ROOT/preflight" <<'FAKE_PREFLIGHT'
#!/usr/bin/env bash
printf 'FAKE PREFLIGHT completed (args: %s)\n' "$*"
printf 'preflight %s\n' "$*" >> "$PREFLIGHT_MARKER"
exit 0
FAKE_PREFLIGHT
chmod +x "$TEST_ROOT/preflight"

RUN_ID="stage-dispatch-check"
OTHER_RUN_ID="stage-dispatch-other"
MISSING_RUN_ID="stage-dispatch-missing"
PASSTHRU_RUN_ID="stage-dispatch-passthru"

mkdir -p "$TEST_ROOT/runs/$RUN_ID" "$TEST_ROOT/runs/$OTHER_RUN_ID"
printf '{"run_id":"%s"}\n' "$RUN_ID" > "$TEST_ROOT/runs/$RUN_ID/run.json"
printf '{"run_id":"%s"}\n' "$OTHER_RUN_ID" > "$TEST_ROOT/runs/$OTHER_RUN_ID/run.json"

# Independent oracles: the documented canonical stages, their Makefile target
# names, and the accepted legacy aliases.
EXPECTED_STAGE_ORDER=(preflight setup full incremental extend recover reconcile verify restore-test monitor summary)
declare -A EXPECTED_TARGET=(
  [preflight]=preflight [setup]=vm-setup [full]=vm-backup [incremental]=vm-cbt-backup
  [extend]=vm-cbt-extend [recover]=vm-cbt-recover [reconcile]=vm-cbt-reconcile
  [verify]=vm-cbt-verify [restore-test]=vm-cbt-restore-test [monitor]=monitor
  [summary]=run-summary
)
declare -A EXPECTED_ALIAS=(
  [vm-setup]=setup [vm-backup]=full [vm-cbt-backup]=incremental [vm-cbt-extend]=extend
  [vm-cbt-recover]=recover [vm-cbt-reconcile]=reconcile [vm-cbt-verify]=verify
  [vm-cbt-restore-test]=restore-test
)

# ---------------------------------------------------------------------------
# 1. `list`: exactly the 11 canonical stages, TAB separated, target names from
#    the Makefile.
# ---------------------------------------------------------------------------
run_cmd list "$TEST_STAGE" list
assert_status "stage.sh list" 0 "$STATUS"

declare -A LIST_TARGET=()
declare -A LIST_REQUIRED=()
declare -A LIST_DESC=()
LIST_ORDER=()

while IFS= read -r line; do
  [[ -n "$line" ]] || die "stage.sh list: printed an empty line: [$OUT]"
  tabs="$(printf '%s' "$line" | tr -cd '\t' | wc -c | tr -d ' ')"
  ((tabs == 3)) || die "stage.sh list: row [$line] has $tabs TAB separators, expected 3"
done <<<"$OUT"

while IFS=$'\t' read -r stage target required_args description; do
  [[ -n "$stage" ]] || die "stage.sh list: empty stage column in [$OUT]"
  [[ "$stage" =~ ^[a-z][a-z-]*$ ]] || die "stage.sh list: stage [$stage] is not a lowercase stage name"
  [[ -n "$target" ]] || die "stage.sh list: empty make-target column for stage [$stage]"
  [[ -n "$required_args" ]] || die "stage.sh list: empty required-args column for stage [$stage]"
  [[ -n "$description" ]] || die "stage.sh list: empty description for stage [$stage]"
  [[ -z "${LIST_TARGET[$stage]:-}" ]] || die "stage.sh list: stage [$stage] listed twice"
  LIST_ORDER+=("$stage")
  LIST_TARGET["$stage"]="$target"
  LIST_REQUIRED["$stage"]="$required_args"
  LIST_DESC["$stage"]="$description"
done <<<"$OUT"

assert_eq "stage.sh list: stage count" "${#EXPECTED_STAGE_ORDER[@]}" "${#LIST_ORDER[@]}"
assert_eq "stage.sh list: canonical stage order/names" \
  "${EXPECTED_STAGE_ORDER[*]}" "${LIST_ORDER[*]}"

for stage in "${EXPECTED_STAGE_ORDER[@]}"; do
  assert_eq "stage.sh list: make target for stage [$stage]" \
    "${EXPECTED_TARGET[$stage]}" "${LIST_TARGET[$stage]}"
done

# Cross-check the target column against the Makefile's own recipes (one
# `./scripts/stage.sh <stage>` per target; `stage-list` targets `list`, which is
# not a stage).
makefile_pairs="$(
  awk '
    /^[A-Za-z][A-Za-z0-9_-]*:/ {
      target = $0
      sub(/:.*/, "", target)
    }
    {
      if (match($0, /\.\/scripts\/stage\.sh [a-z][a-z-]*/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/\.\/scripts\/stage\.sh /, "", s)
        if (s != "list") print target "|" s
      }
    }
  ' "$TEST_ROOT/Makefile"
)"
[[ -n "$makefile_pairs" ]] || die "Makefile: no './scripts/stage.sh <stage>' recipe lines found"

declare -A MAKEFILE_TARGETS=()
while IFS='|' read -r target stage; do
  [[ -n "$target" && -n "$stage" ]] || die "Makefile parse: malformed pair [$target|$stage]"
  MAKEFILE_TARGETS["$stage"]="${MAKEFILE_TARGETS[$stage]:+${MAKEFILE_TARGETS[$stage]} }$target"
done <<<"$makefile_pairs"

# A stage may be wired from more than one Make target as long as one code path
# serves them: the canonical target must be present, and every extra target must
# be a known entry point for that stage (for example the Windows setup target
# reuses the `setup` stage).
declare -A EXTRA_TARGETS=([setup]="windows-vm-setup")

stage_targets=""
canonical_target=""
for stage in "${EXPECTED_STAGE_ORDER[@]}"; do
  stage_targets="${MAKEFILE_TARGETS[$stage]:-}"
  [[ -n "$stage_targets" ]] || die "Makefile: no target runs ./scripts/stage.sh $stage"
  canonical_target="${LIST_TARGET[$stage]}"
  canonical_found=false
  for wired_target in $stage_targets; do
    [[ "$wired_target" == "$canonical_target" ]] && canonical_found=true
  done
  [[ "$canonical_found" == true ]] ||
    die "Makefile: stage [$stage] is not wired from its canonical target [$canonical_target] (found: $stage_targets)"
  for wired_target in $stage_targets; do
    [[ "$wired_target" == "$canonical_target" ]] && continue
    case " ${EXTRA_TARGETS[$stage]:-} " in
      *" $wired_target "*) ;;
      *) die "Makefile: stage [$stage] is also wired from unexpected target [$wired_target]" ;;
    esac
  done
done

# ---------------------------------------------------------------------------
# 2. Legacy names are aliases: alias and canonical stage produce identical
#    dry-run output.
# ---------------------------------------------------------------------------
assert_alias() { # <alias> <canonical> [extra env assignments...]
  local alias="$1" canonical="$2"
  shift 2
  local run_id_args=(RUN_ID="$RUN_ID")
  # `setup` resolves its own run ID, so exercise the unset case too.
  [[ "$canonical" == setup ]] && run_id_args=()

  run_cmd "alias-$alias" env "${run_id_args[@]}" "$@" "$TEST_STAGE" --dry-run "$alias"
  assert_status "alias $alias: dry run" 0 "$STATUS"
  local alias_out="$OUT" alias_err="$ERR"

  run_cmd "canonical-$canonical" env "${run_id_args[@]}" "$@" "$TEST_STAGE" --dry-run "$canonical"
  assert_status "stage $canonical: dry run" 0 "$STATUS"

  assert_contains "alias $alias: reported as stage [$canonical]" "$alias_out" "stage \"$canonical\""
  assert_eq "alias $alias: stdout vs $canonical" "$OUT" "$alias_out"
  assert_eq "alias $alias: stderr vs $canonical" "$ERR" "$alias_err"
}

assert_alias vm-setup setup
assert_alias vm-backup full
assert_alias vm-cbt-backup incremental
assert_alias vm-cbt-extend extend EXTEND_TO_PASS=2
assert_alias vm-cbt-recover recover
assert_alias vm-cbt-reconcile reconcile
assert_alias vm-cbt-verify verify
assert_alias vm-cbt-restore-test restore-test

# ---------------------------------------------------------------------------
# 3. Usage errors: exit 2 with actionable text.
# ---------------------------------------------------------------------------
# (a) Existing lifecycle required, and present lifecycles must be listed.
run_cmd usage-verify "$TEST_STAGE" verify
assert_status "verify without RUN_ID/VM" 2 "$STATUS"
assert_contains "verify without RUN_ID/VM: names RUN_ID" "$ERR" "RUN_ID"
assert_contains "verify without RUN_ID/VM: names VM=vm-<id>" "$ERR" "VM=vm-<id>"
assert_contains "verify without RUN_ID/VM: lists existing lifecycle $RUN_ID" "$ERR" "$RUN_ID"
assert_contains "verify without RUN_ID/VM: lists existing lifecycle $OTHER_RUN_ID" "$ERR" "$OTHER_RUN_ID"

# Same error with no lifecycles at all points at the setup stage.
mv "$TEST_ROOT/runs" "$TEST_ROOT/runs.aside"
run_cmd usage-verify-empty "$TEST_STAGE" verify
assert_status "verify without RUN_ID/VM (no runs/)" 2 "$STATUS"
assert_contains "verify without RUN_ID/VM (no runs/): points at make vm-setup" "$ERR" "make vm-setup"
mv "$TEST_ROOT/runs.aside" "$TEST_ROOT/runs"

# (b) Unknown stage names.
run_cmd usage-unknown "$TEST_STAGE" bogus-stage-name
assert_status "unknown stage" 2 "$STATUS"
assert_contains "unknown stage: says unknown" "$ERR" 'unknown stage "bogus-stage-name"'
assert_contains "unknown stage: lists the aliases" "$ERR" "vm-cbt-backup->incremental"
assert_contains "unknown stage: points at --help" "$ERR" "--help"

run_cmd usage-no-stage "$TEST_STAGE"
assert_status "no stage name" 2 "$STATUS"
assert_contains "no stage name: lists the stages" "$ERR" "missing stage name"

# (c) `extend` needs EXTEND_TO_PASS.
run_cmd usage-extend env RUN_ID="$RUN_ID" "$TEST_STAGE" --dry-run extend
assert_status "extend without EXTEND_TO_PASS" 2 "$STATUS"
assert_contains "extend without EXTEND_TO_PASS: names the variable" "$ERR" "EXTEND_TO_PASS"
assert_contains "extend without EXTEND_TO_PASS: shows an example" "$ERR" "extend RUN_ID=$RUN_ID EXTEND_TO_PASS=2"

run_cmd usage-extend-bad env RUN_ID="$RUN_ID" EXTEND_TO_PASS=1 "$TEST_STAGE" --dry-run extend
assert_status "extend with EXTEND_TO_PASS=1" 2 "$STATUS"
assert_contains "extend with EXTEND_TO_PASS=1: reports the value" "$ERR" "(got: 1)"

run_cmd usage-extend-ok env RUN_ID="$RUN_ID" EXTEND_TO_PASS=2 "$TEST_STAGE" --dry-run extend
assert_status "extend with EXTEND_TO_PASS=2" 0 "$STATUS"

# ---------------------------------------------------------------------------
# 4. Identity/existence guard: a missing runs/<id>/run.json names the remedy,
#    and the same command proceeds once it exists.
# ---------------------------------------------------------------------------
rm -f "$CLUSTER_MARKER" "$PREFLIGHT_MARKER"

run_cmd guard-missing env RUN_ID="$MISSING_RUN_ID" "$TEST_STAGE" full
assert_status "full with no run.json" 2 "$STATUS"
assert_contains "full with no run.json: names the missing file" "$ERR" "runs/$MISSING_RUN_ID/run.json is missing"
assert_contains "full with no run.json: names the remedy" "$ERR" "make vm-setup RUN_ID=$MISSING_RUN_ID"
[[ -s "$PREFLIGHT_MARKER" ]] &&
  die "full with no run.json: ran the automatic preflight before rejecting the missing lifecycle"
[[ -s "$CLUSTER_MARKER" ]] && die "full with no run.json: contacted the cluster (see $CLUSTER_MARKER)"

# Dry run reports the guard state without executing anything.
run_cmd guard-dry-missing env RUN_ID="$MISSING_RUN_ID" "$TEST_STAGE" --dry-run full
assert_status "full dry run with no run.json" 0 "$STATUS"
assert_contains "full dry run with no run.json: reports the missing file" "$OUT" "(missing;"
assert_contains "full dry run with no run.json: warns nothing ran" "$OUT" "nothing executed, no cluster access"

mkdir -p "$TEST_ROOT/runs/$MISSING_RUN_ID"
printf '{"run_id":"%s","namespace":"vm-cbt-demo"}\n' "$MISSING_RUN_ID" \
  > "$TEST_ROOT/runs/$MISSING_RUN_ID/run.json"

run_cmd guard-dry-present env RUN_ID="$MISSING_RUN_ID" "$TEST_STAGE" --dry-run full
assert_status "full dry run with run.json" 0 "$STATUS"
assert_contains "full dry run with run.json: sees the lifecycle" "$OUT" "run.json  runs/$MISSING_RUN_ID/run.json (present)"
assert_not_contains "full dry run with run.json: no missing-file warning" "$OUT" "(missing;"
assert_contains "full dry run with run.json: prints the child command" "$OUT" "vm-backup.sh"

# The real command now proceeds: stub preflight runs first, then the stage.
cat > "$TEST_ROOT/scripts/vm-backup.sh" <<'FAKE_FULL'
#!/usr/bin/env bash
printf 'FAKE FULL BACKUP run_id=%s\n' "${RUN_ID:-}"
exit 0
FAKE_FULL
chmod +x "$TEST_ROOT/scripts/vm-backup.sh"

run_cmd guard-proceeds env RUN_ID="$MISSING_RUN_ID" "$TEST_STAGE" full
assert_status "full with run.json present" 0 "$STATUS"
assert_contains "full with run.json present: automatic preflight ran" "$OUT" "FAKE PREFLIGHT completed"
assert_contains "full with run.json present: stage ran" "$OUT" "FAKE FULL BACKUP run_id=$MISSING_RUN_ID"
assert_contains "full with run.json present: prints the next step" "$ERR" "make vm-cbt-backup RUN_ID=$MISSING_RUN_ID"
[[ -s "$PREFLIGHT_MARKER" ]] || die "full with run.json present: automatic preflight did not run"

rm -f "$PREFLIGHT_MARKER"

# ---------------------------------------------------------------------------
# 5. Dry runs never contact the cluster.
# ---------------------------------------------------------------------------
rm -f "$CLUSTER_MARKER"

run_cmd dry-policy-mutating env RUN_ID="$RUN_ID" "$TEST_STAGE" --dry-run incremental
assert_status "incremental dry run" 0 "$STATUS"
assert_contains "incremental dry run: preflight policy is reported" "$OUT" "would run first:"
assert_contains "incremental dry run: prints the child command" "$OUT" "vm-cbt-backup.sh"

run_cmd dry-policy-readonly env RUN_ID="$RUN_ID" "$TEST_STAGE" --dry-run verify
assert_status "verify dry run" 0 "$STATUS"
assert_contains "verify dry run: read-only stages skip preflight" "$OUT" 'not required for the read-only "verify" stage'
assert_contains "verify dry run: prints the child command" "$OUT" "vm-cbt-verify.sh"

for stage in full extend recover reconcile restore-test monitor summary; do
  run_cmd "dry-$stage" env RUN_ID="$RUN_ID" EXTEND_TO_PASS=2 "$TEST_STAGE" --dry-run "$stage"
  assert_status "$stage dry run" 0 "$STATUS"
  assert_contains "$stage dry run: reports the resolved identity" "$OUT" "RUN_ID    $RUN_ID"
done

run_cmd dry-monitor-command env RUN_ID="$RUN_ID" "$TEST_STAGE" --dry-run monitor
assert_contains "monitor dry run: prints monitor.sh with the VM name" "$OUT" "monitor.sh vm-$RUN_ID"

if [[ -s "$CLUSTER_MARKER" ]]; then
  die "dry runs contacted the cluster: $(cat "$CLUSTER_MARKER")"
fi

# ---------------------------------------------------------------------------
# 6. Wrapped mode is a byte-identical passthrough.
# ---------------------------------------------------------------------------
# (a) Real stage script: a lifecycle that does not exist fails inside
#     scripts/monitor.sh, identically with and without the dispatcher.
run_cmd wrapped-monitor env E2E_STAGE_WRAPPED=true RUN_ID="$PASSTHRU_RUN_ID" "$TEST_STAGE" monitor
wrapped_status="$STATUS"
wrapped_out="$OUT"
wrapped_err="$ERR"

run_cmd direct-monitor "$TEST_ROOT/scripts/monitor.sh" "vm-$PASSTHRU_RUN_ID"
direct_status="$STATUS"

assert_status "wrapped monitor: same exit status as scripts/monitor.sh" "$direct_status" "$wrapped_status"
assert_eq "wrapped monitor: same stdout as scripts/monitor.sh" "$OUT" "$wrapped_out"
assert_eq "wrapped monitor: same stderr as scripts/monitor.sh" "$ERR" "$wrapped_err"
assert_contains "wrapped monitor: the stage itself reported the missing lifecycle" \
  "$wrapped_err" "No VM lifecycle state found for VM vm-$PASSTHRU_RUN_ID"
assert_not_contains "wrapped monitor: no dispatcher noise on stderr" "$wrapped_err" "stage.sh"
assert_not_contains "wrapped monitor: no dispatcher noise on stdout" "$wrapped_out" "stage.sh"

# (b) Exit statuses other than 0 pass through untouched.
cat > "$TEST_ROOT/scripts/vm-cbt-verify.sh" <<'FAKE_VERIFY'
#!/usr/bin/env bash
printf 'STUB VERIFY stdout run_id=%s\n' "${RUN_ID:-}"
printf 'STUB VERIFY stderr\n' >&2
exit 7
FAKE_VERIFY
chmod +x "$TEST_ROOT/scripts/vm-cbt-verify.sh"

run_cmd wrapped-verify env E2E_STAGE_WRAPPED=true RUN_ID="$RUN_ID" "$TEST_STAGE" verify
wrapped_status="$STATUS"
wrapped_out="$OUT"
wrapped_err="$ERR"

run_cmd direct-verify env RUN_ID="$RUN_ID" "$TEST_ROOT/scripts/vm-cbt-verify.sh"
direct_status="$STATUS"

assert_status "wrapped verify: exit status passthrough" 7 "$wrapped_status"
assert_status "wrapped verify: direct invocation exits 7 too" 7 "$direct_status"
assert_eq "wrapped verify: same stdout as the stage" "$OUT" "$wrapped_out"
assert_eq "wrapped verify: same stderr as the stage" "$ERR" "$wrapped_err"

# ---------------------------------------------------------------------------
# 7. Makefile wiring: each target invokes ./scripts/stage.sh <expected stage>.
# ---------------------------------------------------------------------------
for stage in "${EXPECTED_STAGE_ORDER[@]}"; do
  target="${EXPECTED_TARGET[$stage]}"
  run_cmd "make-$target" make -n -f Makefile "$target" RUN_ID="$RUN_ID" EXTEND_TO_PASS=2
  assert_status "make -n $target" 0 "$STATUS"
  assert_contains "make -n $target: invokes ./scripts/stage.sh $stage" \
    "$OUT" "./scripts/stage.sh $stage"
done

run_cmd make-stage-list make -n -f Makefile stage-list
assert_status "make -n stage-list" 0 "$STATUS"
assert_contains "make -n stage-list: invokes ./scripts/stage.sh list" "$OUT" "./scripts/stage.sh list"

# make -n must not have executed anything.
if [[ -s "$CLUSTER_MARKER" ]]; then
  die "make -n contacted the cluster: $(cat "$CLUSTER_MARKER")"
fi
[[ -s "$PREFLIGHT_MARKER" ]] && die "make -n ran the preflight stub: $(cat "$PREFLIGHT_MARKER")"

printf 'PASS: scripts/stage.sh lists the 11 canonical stages and their Makefile targets, maps every legacy alias to its stage, rejects usage/identity errors with exit 2 and actionable text, keeps dry runs off the cluster, passes bytes and exit statuses through in E2E_STAGE_WRAPPED mode, and every Makefile target routes into the expected stage.\n'
