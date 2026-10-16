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

# --- (e) --list-checks exits 0 without reading artifacts ---------------------
list_output=""
list_status=0
list_output="$(cd "$TEST_TMP" && "$VERDICT" --list-checks \
  --scenario-dir "$TEST_TMP/does-not-exist" --run-id missing-run 2>/dev/null)" || list_status=$?
[[ "$list_status" -eq 0 ]] || fail "--list-checks must exit 0, got $list_status"
[[ "$(printf '%s\n' "$list_output" | wc -l | tr -d ' ')" == "8" ]] ||
  fail "--list-checks must print 8 TSV rows"
[[ "$(printf '%s\n' "$list_output" | cut -f1 | tr '\n' ' ')" == \
  "run-id-consistency injection-signal launcher-replacement backup-interrupted tracker-not-advanced cbt-recovered same-vm-recovery clean-lifecycle " ]] ||
  fail "--list-checks must print the fixed check ids in order"

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

printf 'PASS: scenario-verdict evaluates the fixed check list deterministically (PASS/INVALID/INCONCLUSIVE/FAIL), caps clean-lifecycle-less verdicts, and reports the frozen JSON contract with exit codes 0/1/2.\n'
