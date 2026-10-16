#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERDICT_SRC="$ROOT_DIR/cbt-chaos/scenario-verdict.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The evaluator derives the repository root from its own location (the parent of
# cbt-chaos/), so the fixture is a throwaway root that exposes the real script
# under <root>/cbt-chaos/. That keeps lifecycle runs
# (<root>/runs/<name>/...) out of the live repository while still exercising the
# real script bytes and the real root derivation.
ROOT="$TEST_TMP/root"
SCENARIO="CBT-F-01"
RUN_ID="20261016-cbtf01-t01"
CLEAN_RUN="20261016-cbtf01-t01-clean"
mkdir -p "$ROOT/cbt-chaos/scenarios_v2/$SCENARIO" "$ROOT/runs"
ln -s "$VERDICT_SRC" "$ROOT/cbt-chaos/scenario-verdict.sh"
VERDICT="$ROOT/cbt-chaos/scenario-verdict.sh"
SCENARIO_DIR="$ROOT/cbt-chaos/scenarios_v2/$SCENARIO"
# The check-set registry is repository text resolved next to the evaluator's own
# bytes (never from the run's pack), so the throwaway root exposes it the same
# way the real root does.
REGISTRY_SRC="$ROOT_DIR/cbt-chaos/scenario-check-sets.tsv"
ln -s "$REGISTRY_SRC" "$ROOT/cbt-chaos/scenario-check-sets.tsv"

# The frozen CBT-EXP-06 pack is the regression fixture for the check-set
# registry (`evaluator-out-of-shape`, third occurrence). Both the pack and the
# lifecycle records are git-ignored (cbt-chaos/scenarios_v2/*/runs/**, /runs/),
# so a checkout that never ran it has no fixture: the regression is skipped
# there rather than failed.
EXP06_SCENARIO="CBT-EXP-06"
EXP06_RUN="20261016-exp06-r02"
PACK_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/$EXP06_SCENARIO/runs/$EXP06_RUN"
LIFECYCLE_PACK_DIR="$ROOT_DIR/runs/$EXP06_RUN"
EXP06_SCENARIO_DIR="$ROOT/cbt-chaos/scenarios_v2/$EXP06_SCENARIO"
EXP06_RUN_DIR="$EXP06_SCENARIO_DIR/runs/$EXP06_RUN"
EXP06_PACK_AVAILABLE=false
if [[ -s "$PACK_DIR/trigger/exit-statuses.json" && -s "$PACK_DIR/observer/effect/qmp-nodes-post.json" &&
      -s "$LIFECYCLE_PACK_DIR/run.json" && -s "$LIFECYCLE_PACK_DIR/report.json" &&
      -s "$LIFECYCLE_PACK_DIR/summary.json" ]]; then
  EXP06_PACK_AVAILABLE=true
fi

write_lifecycle() { # run_name kind run_id_override
  local name="$1" kind="$2" rid="${3:-$1}"
  local dir="$ROOT/runs/$name"
  mkdir -p "$dir"
  local reason='Backup has failed: VMI backup status was lost'
  if [[ "$kind" == "failed" ]]; then
    jq -n --arg rid "$rid" --arg vm "vm-$rid" --arg reason "$reason" '
      {schema_version:1, run_id:$rid, vm_name:$vm,
       vm_uid:"11111111-1111-1111-1111-111111111111", namespace:"vm-cbt-demo",
       os_profile:"rhel9", manifest_variant:"large-odf", status:"complete",
       backups:{
         full:null,
         incrementals:[],
         full_failure:{name:("vm-backup-"+$rid), type:"Full", done_status:"True",
           done_reason:$reason,
           checkpoint_name:("vm-backup-"+$rid+"-2026-10-16_10-00-00"),
           pvc_name:("vm-backup-pvc-"+$rid), pvc_phase:"Bound",
           tracker_checkpoint_at_failure:""}},
       recovery:{attempts:[{
         id:"r001", status:"success",
         vm:{name:$vm, uid:"11111111-1111-1111-1111-111111111111", ready:"True",
             vmi_phase:"Running", cbt_state:"Enabled"},
         failed_full:{name:("vm-backup-"+$rid), type:"Full", done_status:"True",
           done_reason:$reason,
           checkpoint_name:("vm-backup-"+$rid+"-2026-10-16_10-00-00"),
           pvc_name:("vm-backup-pvc-"+$rid), pvc_phase:"Bound"},
         tracker:{name:("vm-tracker-"+$rid), checkpoint_before:""},
         recovery_full:{name:("vm-recovery-full-"+$rid+"-r001"), type:"Full", done_status:"True",
           done_reason:"Successfully completed VirtualMachineBackup",
           checkpoint_name:("vm-recovery-full-"+$rid+"-r001-2026-10-16_10-04-00"),
           pvc_name:("vm-recovery-pvc-"+$rid+"-r001"), pvc_phase:"Bound",
           force_full_backup:true,
           tracker_checkpoint_after:("vm-recovery-full-"+$rid+"-r001-2026-10-16_10-04-00")},
         preconditions:[{name:"vmi_running",passed:true,actual:"Running"},
                        {name:"cbt_enabled",passed:true,actual:"Enabled"}],
         restore:{status:"passed", checks:[
           {name:"recovery_full_restore_file_count_match",passed:true,
            expected:"8", actual:"8"},
           {name:"recovery_full_restore_payload_bytes_match",passed:true,
            expected:"8589934592", actual:"8589934592"},
           {name:"recovery_full_restore_manifest_match",passed:true,
            expected:"baseline-sha", actual:"baseline-sha"}]}}]}
    }' > "$dir/run.json"
  else
    # The full backup succeeded: the injected disruption never happened.
    jq -n --arg rid "$rid" --arg vm "vm-$rid" '
      {schema_version:1, run_id:$rid, vm_name:$vm,
       vm_uid:"11111111-1111-1111-1111-111111111111", namespace:"vm-cbt-demo",
       os_profile:"rhel9", manifest_variant:"large-odf", status:"complete",
       backups:{
         full:{name:("vm-backup-"+$rid), type:"Full", done_status:"True",
           done_reason:"Successfully completed VirtualMachineBackup",
           checkpoint_name:("vm-backup-"+$rid+"-2026-10-16_10-00-00"),
           pvc_name:("vm-backup-pvc-"+$rid), pvc_phase:"Bound"},
         incrementals:[]},
       recovery:{attempts:[{
         id:"r001", status:"success",
         vm:{name:$vm, uid:"11111111-1111-1111-1111-111111111111", ready:"True",
             vmi_phase:"Running", cbt_state:"Enabled"},
         tracker:{name:("vm-tracker-"+$rid), checkpoint_before:""},
         preconditions:[{name:"vmi_running",passed:true,actual:"Running"}],
         restore:{status:"passed", checks:[
           {name:"recovery_full_restore_file_count_match",passed:true,
            expected:"8", actual:"8"},
           {name:"recovery_full_restore_payload_bytes_match",passed:true,
            expected:"8589934592", actual:"8589934592"},
           {name:"recovery_full_restore_manifest_match",passed:true,
            expected:"baseline-sha", actual:"baseline-sha"}]}}]}
    }' > "$dir/run.json"
  fi
}

write_lifecycle_records() { # run_name
  local name="$1"
  local dir="$ROOT/runs/$name"
  mkdir -p "$dir"
  jq -n --arg rid "$name" --arg ckpt "vm-recovery-full-$name-r001-2026-10-16_10-04-00" '
    {run_id:$rid, vm_name:("vm-"+$rid), namespace:"vm-cbt-demo", os_profile:"rhel9",
     tracker:{latest_checkpoint:$ckpt},
     verification:{overall_passed:true, checks:[
       {name:"vm_cbt_is_enabled",passed:true},
       {name:"vmi_running",passed:true}]}}' > "$dir/report.json"
  jq -n --arg rid "$name" '
    {schema_version:1, run_id:$rid, generated_by:"scripts/write-run-summary.sh",
     verdict:"PASS", verdict_reason:"lifecycle complete",
     lifecycle:{state:"complete", passes_completed:1, passes_planned:1},
     cbt:{status:"PASS", vm_state:"Enabled", tracker_latest_checkpoint:null},
     restore_hashes:{status:"PASS", full_only:"PASS", incremental_prefixes:"PASS",
                     failed_restore_check_count:0}}' > "$dir/summary.json"
}

write_trigger() { # run_id
  local rid="$1"
  local dir="$SCENARIO_DIR/runs/$rid/trigger"
  mkdir -p "$dir"
  # An independent observer must be armed: the injector is never the sole
  # authority for its own injection, so a fixture without this marker must be
  # judged INCONCLUSIVE rather than PASS.
  mkdir -p "$SCENARIO_DIR/runs/$rid/observer/watches"
  printf '{"utc":"2026-10-16T10:00:01Z","watch_pids":[4242],"target":"vm-%s"}\n' "$rid" \
    > "$SCENARIO_DIR/runs/$rid/observer/ARMED"
  local pod="virt-launcher-vm-$rid-abcde"
  local uid="aaaaaaaa-1111-2222-3333-444444444444"
  local new_pod="virt-launcher-vm-$rid-fghij"
  local new_uid="bbbbbbbb-5555-6666-7777-888888888888"
  jq -n --arg rid "$rid" --arg pod "$pod" --arg uid "$uid" '
    {utc_action_request:"2026-10-16T10:00:05Z", launcher_pod:$pod, launcher_pod_uid:$uid,
     vm:("vm-"+$rid), backup:("vm-backup-"+$rid), leader:"virt-controller-9876-abcde",
     signal_line:("Active-copy signal: "+$pod+" Backup started for vm-backup-"+$rid)}' \
    > "$dir/action-request.json"
  jq -n --arg pod "$pod" --arg uid "$uid" --arg npod "$new_pod" --arg nuid "$new_uid" '
    {old_pod:{name:$pod, uid:$uid}, old_pod_gone:true,
     replacement_pod:{name:$npod, uid:$nuid, ready:true}}' > "$dir/effect-check.json"
  printf 'Active-copy signal: %s Backup started for vm-backup-%s\n' "$pod" "$rid" > "$dir/trigger.log"
  printf 'make e2e TYPE=full NAME=%s\n' "$rid" > "$dir/command.txt"
  printf '{"workflow":0,"trigger":0}\n' > "$dir/exit-statuses.json"
}

write_clean_summary() { # run_name
  local name="$1"
  local dir="$ROOT/runs/$name"
  mkdir -p "$dir"
  jq -n --arg rid "$name" '
    {schema_version:1, run_id:$rid, verdict:"PASS",
     verdict_reason:"All planned incremental passes completed; CBT chain and restore checks passed.",
     restore_hashes:{status:"PASS", full_only:"PASS", incremental_prefixes:"PASS",
                     all:"PASS", failed_restore_check_count:0}}' > "$dir/summary.json"
}

reset_fixture() {
  rm -rf "$SCENARIO_DIR/runs" "$ROOT/runs"
  mkdir -p "$SCENARIO_DIR/runs" "$ROOT/runs"
}

write_exp06_fixture() { # copies the frozen r02 artifacts the evaluator reads
  rm -rf "$EXP06_RUN_DIR" "$ROOT/runs/$EXP06_RUN"
  mkdir -p "$EXP06_RUN_DIR/trigger" "$EXP06_RUN_DIR/observer/effect" "$ROOT/runs/$EXP06_RUN"
  local rel
  for rel in action-request.json bitmaps-before.json bitmaps-after.json \
             query-named-block-nodes-after.json exit-statuses.json legB-incremental-backup.yaml; do
    cp "$PACK_DIR/trigger/$rel" "$EXP06_RUN_DIR/trigger/$rel"
  done
  for rel in qmp-nodes-post.json qmp-nodes-post-late.json pre-bitmap-history.jsonl; do
    cp "$PACK_DIR/observer/effect/$rel" "$EXP06_RUN_DIR/observer/effect/$rel"
  done
  # The legacy family needs the observer's own handoff marker: without it
  # injection-signal degrades to UNKNOWN ("the injector is the sole authority")
  # instead of the FAIL the frozen pack produced.
  cp "$PACK_DIR/observer/ARMED" "$EXP06_RUN_DIR/observer/ARMED"
  for rel in run.json report.json summary.json; do
    cp "$LIFECYCLE_PACK_DIR/$rel" "$ROOT/runs/$EXP06_RUN/$rel"
  done
}

# Runs the evaluator over the CBT-F-01 fixture under an explicitly named set and
# prints one check's status; used by the check-set cases that need no pack.
check_status_under_set() { # <check-set> <check-id>
  local set="$1" id="$2" out
  out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
    --check-set "$set" 2>/dev/null)" || true
  jq -r --arg id "$id" '.checks[] | select(.id == $id) | .status' <<<"$out"
}

# --- (a) fully populated happy path yields PASS and exit 0 -------------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
json_out="$TEST_TMP/verdict.json"
stderr_file="$TEST_TMP/stderr.txt"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" --json "$json_out" 2>"$stderr_file")" || verdict_status=$?
[[ "$verdict_status" -eq 0 ]] || fail "happy path must exit 0, got $verdict_status"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "PASS" ]] ||
  fail "happy path must yield PASS, got $(jq -r '.verdict' <<<"$stdout_out")"
jq -e '
  .schema_version == 1 and .scenario == "CBT-F-01" and .run_id == "20261016-cbtf01-t01" and
  (.checks | length) == 8 and
  ([.checks[].id] == ["run-id-consistency","injection-signal","launcher-replacement",
                      "backup-interrupted","tracker-not-advanced","cbt-recovered",
                      "same-vm-recovery","clean-lifecycle"]) and
  ([.checks[].status] | all(. == "PASS")) and
  ([.checks[] | select((.expected | length) == 0 or (.evidence | length) == 0)] | length) == 0 and
  (.verdict_reason | length) > 0
' <<<"$stdout_out" >/dev/null || fail "happy path JSON contract is incomplete: $stdout_out"
[[ "$(jq -S -c '.' <<<"$stdout_out")" == "$(jq -S -c '.' "$json_out")" ]] ||
  fail "--json must contain the same verdict document as stdout"
[[ "$(<"$stderr_file")" == *'VERDICT'* && "$(<"$stderr_file")" == *'PASS'* ]] ||
  fail "a short human-readable table must be printed to stderr"

# --- (a2) without --clean-lifecycle-run the verdict is capped at INCONCLUSIVE -
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -ne 0 ]] || fail "a verdict without the clean lifecycle must not exit 0"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "INCONCLUSIVE" ]] ||
  fail "clean-lifecycle NOT_APPLICABLE must cap the verdict at INCONCLUSIVE"
[[ "$(jq -r '.checks[] | select(.id == "clean-lifecycle") | .status' <<<"$stdout_out")" == "NOT_APPLICABLE" ]] ||
  fail "clean-lifecycle must be NOT_APPLICABLE when --clean-lifecycle-run is omitted"

# --- (a3) the interrupted lifecycle records CBT only in its recovery attempt
#         (no vm-cbt-verify checks and no summary cbt block): the evaluator
#         must still resolve cbt-recovered from the recorded attempt state ----
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
jq -n --arg rid "$RUN_ID" '
  {run_id:$rid, vm_name:("vm-"+$rid), namespace:"vm-cbt-demo", os_profile:"rhel9",
   tracker:{latest_checkpoint:null},
   verification:{overall_passed:false, checks:[]}}' >"$ROOT/runs/$RUN_ID/report.json"
jq -n --arg rid "$RUN_ID" '
  {schema_version:1, run_id:$rid, generated_by:"scripts/write-run-summary.sh",
   verdict:"FAIL", verdict_reason:"interrupted full backup",
   lifecycle:{state:"incomplete", passes_completed:0, passes_planned:1},
   restore_hashes:{status:"PASS", full_only:"PASS", incremental_prefixes:"PASS",
                   failed_restore_check_count:0}}' >"$ROOT/runs/$RUN_ID/summary.json"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
recovered_status="$(jq -r '.checks[] | select(.id == "cbt-recovered") | .status' <<<"$stdout_out")"
[[ "$recovered_status" == "PASS" ]] ||
  fail "cbt-recovered must resolve from recovery.attempts[].vm.cbt_state (got $recovered_status)"
[[ "$verdict_status" -eq 0 ]] ||
  fail "a healthy run whose lifecycle only records attempt state must still PASS, got $(jq -r '.verdict' <<<"$stdout_out")"

# --- (b) an uninterrupted (successful) full backup yields INVALID ------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" succeeded
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -ne 0 ]] || fail "an unexercised injection must not exit 0"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "INVALID" ]] ||
  fail "a successful full backup with no injection evidence must be INVALID, got $(jq -r '.verdict' <<<"$stdout_out")"

# --- (c) missing trigger artifacts yield INCONCLUSIVE, never PASS ------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -ne 0 ]] || fail "missing trigger artifacts must not exit 0"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "INCONCLUSIVE" ]] ||
  fail "missing trigger artifacts must be INCONCLUSIVE, got $(jq -r '.verdict' <<<"$stdout_out")"
jq -e '
  (.checks[] | select(.id == "injection-signal") | .status) == "UNKNOWN" and
  (.checks[] | select(.id == "launcher-replacement") | .status) == "UNKNOWN" and
  (.checks[] | select(.id == "backup-interrupted") | .status) == "PASS"
' <<<"$stdout_out" >/dev/null || fail "missing trigger evidence must be UNKNOWN, not PASS"

# --- (c2) malformed trigger evidence degrades to UNKNOWN, never PASS --------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
printf 'not json at all\n' > "$SCENARIO_DIR/runs/$RUN_ID/trigger/effect-check.json"
printf 'not json at all\n' > "$SCENARIO_DIR/runs/$RUN_ID/trigger/action-request.json"
printf 'nothing useful recorded here\n' > "$SCENARIO_DIR/runs/$RUN_ID/trigger/trigger.log"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -ne 0 ]] || fail "malformed trigger evidence must not exit 0"
jq -e '
  .verdict == "INCONCLUSIVE" and
  (.checks[] | select(.id == "injection-signal") | .status) == "UNKNOWN" and
  (.checks[] | select(.id == "launcher-replacement") | .status) == "UNKNOWN"
' <<<"$stdout_out" >/dev/null ||
  fail "malformed trigger evidence must degrade to UNKNOWN/INCONCLUSIVE, got $stdout_out"

# --- (d) a run-id mismatch yields FAIL --------------------------------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed "20261016-cbtf01-other"
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "a run-id mismatch must exit 1, got $verdict_status"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "FAIL" ]] ||
  fail "a run-id mismatch must be FAIL, got $(jq -r '.verdict' <<<"$stdout_out")"
[[ "$(jq -r '.checks[] | select(.id == "run-id-consistency") | .status' <<<"$stdout_out")" == "FAIL" ]] ||
  fail "run-id-consistency must FAIL on a mismatched run id"

# --- (d2) observer blocked evidence yields BLOCKED ---------------------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID/observer"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
printf 'watch lost before the injection boundary\n' > "$SCENARIO_DIR/runs/$RUN_ID/observer/WATCH-LOST"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "blocked evidence must exit 1, got $verdict_status"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "BLOCKED" ]] ||
  fail "observer blocked evidence must yield BLOCKED, got $(jq -r '.verdict' <<<"$stdout_out")"

# --- (d3) an injection that removed a different pod is INVALID --------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
jq '.old_pod.uid = "99999999-9999-9999-9999-999999999999"' \
  "$SCENARIO_DIR/runs/$RUN_ID/trigger/effect-check.json" > "$TEST_TMP/wrong-target.json"
mv "$TEST_TMP/wrong-target.json" "$SCENARIO_DIR/runs/$RUN_ID/trigger/effect-check.json"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "a wrong-target injection must exit 1, got $verdict_status"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "INVALID" ]] ||
  fail "a wrong-target injection must be INVALID, got $(jq -r '.verdict' <<<"$stdout_out")"
[[ "$(jq -r '.checks[] | select(.id == "launcher-replacement") | .status' <<<"$stdout_out")" == "FAIL" ]] ||
  fail "launcher-replacement must FAIL when a different pod was removed"

# --- (d4) an observer-less run is INCONCLUSIVE, never PASS -------------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
rm -rf "$SCENARIO_DIR/runs/$RUN_ID/observer"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "a run without observer evidence must not exit 0"
[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "INCONCLUSIVE" ]] ||
  fail "a run without observer evidence must be INCONCLUSIVE, got $(jq -r '.verdict' <<<"$stdout_out")"
[[ "$(jq -r '.checks[] | select(.id == "injection-signal") | .status' <<<"$stdout_out")" == "UNKNOWN" ]] ||
  fail "injection-signal must be UNKNOWN when the injector is the sole authority"

# --- (d5) a signal recorded before the observer armed is contradictory -------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
jq '.utc_observer_armed = "2026-10-16T10:00:30Z" | .signal_utc = "2026-10-16T10:00:05Z"' \
  "$SCENARIO_DIR/runs/$RUN_ID/trigger/action-request.json" > "$TEST_TMP/stale-signal.json"
mv "$TEST_TMP/stale-signal.json" "$SCENARIO_DIR/runs/$RUN_ID/trigger/action-request.json"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "a stale-signal timing contradiction must not exit 0"
jq -e '
  .verdict == "INCONCLUSIVE" and
  (.checks[] | select(.id == "injection-signal") | .status) == "UNKNOWN" and
  (.checks[] | select(.id == "injection-signal") | .actual | contains("contradictory timing"))
' <<<"$stdout_out" >/dev/null ||
  fail "a signal predating the observer arming window must be UNKNOWN/contradictory, got $stdout_out"

# --- (d6) a tracker that advanced during the failure FAILs --------------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
jq '.backups.full_failure.tracker_checkpoint_at_failure = "vm-backup-advanced-cp"' \
  "$ROOT/runs/$RUN_ID/run.json" > "$TEST_TMP/advanced.json"
mv "$TEST_TMP/advanced.json" "$ROOT/runs/$RUN_ID/run.json"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "an advanced tracker must exit 1, got $verdict_status"
jq -e '
  .verdict == "FAIL" and
  (.checks[] | select(.id == "tracker-not-advanced") | .status) == "FAIL" and
  (.checks[] | select(.id == "tracker-not-advanced") | .actual | contains("had already advanced"))
' <<<"$stdout_out" >/dev/null ||
  fail "a tracker checkpoint at failure must FAIL tracker-not-advanced, got $stdout_out"

# --- (d7) a checkpoint attributed to the interrupted copy FAILs ---------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
interrupted_cp="$(jq -r '.backups.full_failure.checkpoint_name' "$ROOT/runs/$RUN_ID/run.json")"
jq --arg cp "$interrupted_cp" '.tracker.latest_checkpoint = $cp' \
  "$ROOT/runs/$RUN_ID/report.json" > "$TEST_TMP/attributed.json"
mv "$TEST_TMP/attributed.json" "$ROOT/runs/$RUN_ID/report.json"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "an attributed interrupted checkpoint must exit 1, got $verdict_status"
jq -e '
  .verdict == "FAIL" and
  (.checks[] | select(.id == "tracker-not-advanced") | .status) == "FAIL" and
  (.checks[] | select(.id == "tracker-not-advanced") | .actual | contains("usable checkpoint is attributed"))
' <<<"$stdout_out" >/dev/null ||
  fail "a usable checkpoint attributed to the interrupted copy must FAIL, got $stdout_out"

# --- (e) --list-checks exits 0 without reading artifacts ---------------------
list_output=""
list_status=0
list_output="$(cd "$TEST_TMP" && "$VERDICT" --list-checks \
  --scenario-dir "$TEST_TMP/does-not-exist" --run-id missing-run 2>/dev/null)" || list_status=$?
[[ "$list_status" -eq 0 ]] || fail "--list-checks must exit 0, got $list_status"
[[ "$(printf '%s\n' "$list_output" | wc -l | tr -d ' ')" == "11" ]] ||
  fail "--list-checks must print 11 TSV rows (the 8 legacy ids plus the 3 new ones)"
[[ "$(printf '%s\n' "$list_output" | cut -f1 | tr '\n' ' ')" == \
  "run-id-consistency injection-signal launcher-replacement backup-interrupted tracker-not-advanced injection-pre-state injection-effect affected-pass-outcome cbt-recovered same-vm-recovery clean-lifecycle " ]] ||
  fail "--list-checks must print the implemented check ids in fixed order"

# --- (f) usage errors exit 2 -------------------------------------------------
usage_status=0
"$VERDICT" >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] || fail "missing required arguments must exit 2, got $usage_status"
usage_status=0
"$VERDICT" --scenario-dir "$SCENARIO_DIR" >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] || fail "missing --run-id must exit 2, got $usage_status"
usage_status=0
"$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" --bogus >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] || fail "an unknown argument must exit 2, got $usage_status"
usage_status=0
"$VERDICT" --scenario-dir "$TEST_TMP/does-not-exist" --run-id "$RUN_ID" >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] || fail "a missing scenario directory must exit 2, got $usage_status"
usage_status=0
"$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --json "$TEST_TMP/does-not-exist/verdict.json" >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] || fail "a missing --json parent directory must exit 2, got $usage_status"
usage_status=0
"$VERDICT" --help >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 0 ]] || fail "--help must exit 0, got $usage_status"

# --- (g) --list-check-sets exposes the registry, read-only -------------------
list_output=""
list_status=0
list_output="$(cd "$TEST_TMP" && "$VERDICT" --list-check-sets \
  --scenario-dir "$TEST_TMP/does-not-exist" --run-id missing-run 2>/dev/null)" || list_status=$?
[[ "$list_status" -eq 0 ]] || fail "--list-check-sets must exit 0, got $list_status"
[[ "$(printf '%s\n' "$list_output" | wc -l | tr -d ' ')" == "2" ]] ||
  fail "--list-check-sets must print exactly the two registry rows, got: $list_output"
[[ "$(printf '%s\n' "$list_output" | cut -f1 | tr '\n' ' ')" == "default CBT-EXP-06 " ]] ||
  fail "--list-check-sets must print the registry keys in file order, got: $list_output"
[[ "$(printf '%s\n' "$list_output" | awk -F'\t' '$1 == "default" {print $2}')" == \
  "run-id-consistency,injection-signal,launcher-replacement,backup-interrupted,tracker-not-advanced,cbt-recovered,same-vm-recovery,clean-lifecycle" ]] ||
  fail "the default row must stay byte-identical to the legacy fixed table"
[[ "$(printf '%s\n' "$list_output" | awk -F'\t' '$1 == "CBT-EXP-06" {print $2}')" == \
  "run-id-consistency,injection-pre-state,injection-effect,affected-pass-outcome,cbt-recovered,same-vm-recovery,clean-lifecycle" ]] ||
  fail "the CBT-EXP-06 row must name the surgery-family checks"

# --- (h) the CBT-EXP-06 set regrades the frozen r02 pack ---------------------
# Pins the `evaluator-out-of-shape` class (third occurrence): checks written for
# the interrupted-full/launcher-kill family must stop failing a surgery scenario
# whose pack has no launcher-pod signal and whose affected pass is an
# incremental, while --check-set default must grade that same pack as before.
if [[ "$EXP06_PACK_AVAILABLE" != true ]]; then
  printf 'SKIP: the CBT-EXP-06 check-set regression needs the frozen pack (%s) and its lifecycle records (%s), which are git-ignored and absent here.\n' \
    "$PACK_DIR" "$LIFECYCLE_PACK_DIR"
else
  write_exp06_fixture
  verdict_status=0
  stdout_out="$("$VERDICT" --scenario-dir "$EXP06_SCENARIO_DIR" --run-id "$EXP06_RUN" 2>/dev/null)" || verdict_status=$?
  [[ "$verdict_status" -eq 1 ]] ||
    fail "the CBT-EXP-06 set must not exit 0 on the frozen pack, got $verdict_status"
  jq -e '
    (.checks | length) == 7 and
    ([.checks[].id] == ["run-id-consistency","injection-pre-state","injection-effect",
                        "affected-pass-outcome","cbt-recovered","same-vm-recovery","clean-lifecycle"]) and
    (.checks[] | select(.id == "injection-effect") | .status) == "PASS" and
    (.checks[] | select(.id == "injection-pre-state") | .status) == "UNKNOWN" and
    (.checks[] | select(.id == "affected-pass-outcome") | .status) == "UNKNOWN" and
    .verdict == "INCONCLUSIVE"
  ' <<<"$stdout_out" >/dev/null ||
    fail "the CBT-EXP-06 set must grade the frozen r02 pack INCONCLUSIVE with injection-effect PASS, got $stdout_out"

  verdict_status=0
  stdout_out="$("$VERDICT" --scenario-dir "$EXP06_SCENARIO_DIR" --run-id "$EXP06_RUN" \
    --check-set default 2>/dev/null)" || verdict_status=$?
  [[ "$verdict_status" -eq 1 ]] || fail "--check-set default must exit 1 on the frozen pack, got $verdict_status"
  jq -e '
    (.checks | length) == 8 and
    .verdict == "FAIL" and
    (.checks[] | select(.id == "injection-signal") | .status) == "FAIL" and
    (.verdict_reason | contains("injection-signal"))
  ' <<<"$stdout_out" >/dev/null ||
    fail "--check-set default must still grade the frozen pack FAIL on injection-signal, got $stdout_out"
fi

# --- (i) a check id named by a set but not implemented is UNKNOWN ------------
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID"
write_lifecycle "$RUN_ID" failed
write_lifecycle_records "$RUN_ID"
write_clean_summary "$CLEAN_RUN"
write_trigger "$RUN_ID"
printf 'default\trun-id-consistency,no-such-check-id\n' > "$TEST_TMP/registry-unknown.tsv"
verdict_status=0
stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --check-set-file "$TEST_TMP/registry-unknown.tsv" \
  --clean-lifecycle-run "$CLEAN_RUN" 2>/dev/null)" || verdict_status=$?
[[ "$verdict_status" -eq 1 ]] || fail "a registry naming an unimplemented check must not exit 0, got $verdict_status"
jq -e --arg reg "$TEST_TMP/registry-unknown.tsv" '
  .verdict == "INCONCLUSIVE" and
  ([.checks[].id] == ["run-id-consistency","no-such-check-id"]) and
  (.checks[] | select(.id == "no-such-check-id") | .status) == "UNKNOWN" and
  (.checks[] | select(.id == "no-such-check-id") | .actual | contains($reg))
' <<<"$stdout_out" >/dev/null ||
  fail "an unimplemented check id must be UNKNOWN (fail-closed) and name the registry, got $stdout_out"

# --- (j) an undefined check-set name, and a registry without a fallback ------
reset_fixture
usage_status=0
"$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" --check-set bogus >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] || fail "--check-set for an undefined name must exit 2, got $usage_status"
printf 'other-set\trun-id-consistency\n' > "$TEST_TMP/registry-nodefault.tsv"
usage_status=0
"$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
  --check-set-file "$TEST_TMP/registry-nodefault.tsv" >/dev/null 2>&1 || usage_status=$?
[[ "$usage_status" -eq 2 ]] ||
  fail "a registry with no default row and no scenario row must exit 2, got $usage_status"

# --- (k) affected-pass-outcome models every recorded outcome shape -----------
# exit-statuses.json alone, graded through the CBT-EXP-06 set.
outcome_status() { # <exit-statuses.json body>
  reset_fixture
  mkdir -p "$SCENARIO_DIR/runs/$RUN_ID/trigger"
  printf '%s\n' "$1" > "$SCENARIO_DIR/runs/$RUN_ID/trigger/exit-statuses.json"
  check_status_under_set CBT-EXP-06 affected-pass-outcome
}
status="$(outcome_status '{"pass_wait_bound_seconds":1200,"surgery_incremental":{"name":"vm-incremental-demo-p01","type":"Incremental","done":"True","reason":"Successfully completed VirtualMachineBackup","included_volumes":"rootdisk datadisk","terminal":true,"waited_seconds":300}}')"
[[ "$status" == "PASS" ]] || fail "a terminal Done=True pass must be PASS, got $status"
status="$(outcome_status '{"pass_wait_bound_seconds":1200,"surgery_incremental":{"name":"vm-incremental-demo-p01","type":"Incremental","done":"False","reason":"Backup has failed: VMI backup status was lost","terminal":true,"waited_seconds":600}}')"
[[ "$status" == "PASS" ]] || fail "a terminal done=False pass must be PASS, got $status"
status="$(outcome_status '{"pass_wait_bound_seconds":1200,"surgery_incremental":{"name":"vm-incremental-demo-p01","done":"","terminal":false,"waited_seconds":1235}}')"
[[ "$status" == "PASS" ]] || fail "a non-terminal stall past the wait bound must be PASS, got $status"
status="$(outcome_status '{"surgery_incremental":{"name":"vm-incremental-demo-p01","done":"","terminal":false,"waited_seconds":1235}}')"
[[ "$status" == "UNKNOWN" ]] || fail "a non-terminal record with no wait bound must be UNKNOWN, got $status"

# --- (l) injection-effect is per-disk, not merely "the bitmap is gone" -------
effect_status() { # <query-named-block-nodes-after.json body>
  reset_fixture
  mkdir -p "$SCENARIO_DIR/runs/$RUN_ID/trigger"
  printf '%s\n' '{"utc":"2026-10-16T04:28:20Z","checkpoint":"vm-backup-demo-ckpt","disk":"datadisk","qemu_node":"libvirt-2-format"}' \
    > "$SCENARIO_DIR/runs/$RUN_ID/trigger/surgery-target.json"
  printf '%s\n' "$1" > "$SCENARIO_DIR/runs/$RUN_ID/trigger/query-named-block-nodes-after.json"
  check_status_under_set CBT-EXP-06 injection-effect
}
target_kept='{"node-name":"libvirt-2-format","file":"/cbt/datadisk.qcow2","dirty-bitmaps":[{"name":"vm-backup-demo-ckpt","recording":true}]}'
target_gone='{"node-name":"libvirt-2-format","file":"/cbt/datadisk.qcow2","dirty-bitmaps":[]}'
sibling_keeps='{"node-name":"libvirt-4-format","file":"/cbt/rootdisk.qcow2","dirty-bitmaps":[{"name":"vm-backup-demo-ckpt","recording":true}]}'
sibling_empty='{"node-name":"libvirt-4-format","file":"/cbt/rootdisk.qcow2","dirty-bitmaps":[]}'
status="$(effect_status "{\"return\":[$target_kept,$sibling_empty]}")"
[[ "$status" == "FAIL" ]] || fail "a surviving target bitmap must FAIL injection-effect, got $status"
status="$(effect_status "{\"return\":[$target_gone,$sibling_keeps]}")"
[[ "$status" == "PASS" ]] || fail "a per-disk removal must PASS injection-effect, got $status"
status="$(effect_status "{\"return\":[$target_gone,$sibling_empty]}")"
[[ "$status" == "UNKNOWN" ]] || fail "a removal no sibling bitmap can contrast must be UNKNOWN, got $status"

# --- (m) cbt-recovered falls back to the observer's own live VMI read --------
# Pins the observer-corroboration branch where the lifecycle resolves neither
# half (no verify checks, no attempt state, no summary cbt block).
reset_fixture
mkdir -p "$SCENARIO_DIR/runs/$RUN_ID/observer/effect" "$ROOT/runs/$RUN_ID"
jq -n --arg rid "$RUN_ID" '{run_id:$rid, vm_name:("vm-"+$rid), status:"incomplete"}' \
  > "$ROOT/runs/$RUN_ID/run.json"
printf '{"run_id":"%s","verification":{"checks":[]}}\n' "$RUN_ID" > "$ROOT/runs/$RUN_ID/report.json"
printf '{"run_id":"%s"}\n' "$RUN_ID" > "$ROOT/runs/$RUN_ID/summary.json"
printf '{"changedBlockTracking":{"state":"Enabled"}}\n' \
  > "$SCENARIO_DIR/runs/$RUN_ID/observer/effect/post-vmi-cbt.json"
printf '{"status":{"phase":"Running"}}\n' \
  > "$SCENARIO_DIR/runs/$RUN_ID/observer/effect/post-vmi-now.json"
status="$(check_status_under_set default cbt-recovered)"
[[ "$status" == "PASS" ]] ||
  fail "cbt-recovered must fall back to the observer's post-window VMI read, got $status"

printf 'PASS: scenario-verdict evaluates the selected check list deterministically (PASS/INVALID/INCONCLUSIVE/FAIL), resolves check sets from the registry fail-closed, caps clean-lifecycle-less verdicts, and reports the frozen JSON contract with exit codes 0/1/2.\n'
