#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
RUNS_ROOT_DIR="$TEST_TMP/runs"
mkdir -p "$RUNS_ROOT_DIR"

make_run_state() {
  local run_id="$1" status="$2" completed="$3" total="$4"
  mkdir -p "$RUNS_ROOT_DIR/$run_id"
  jq -n \
    --arg run_id "$run_id" \
    --arg status "$status" \
    --argjson completed "$completed" \
    --argjson total "$total" \
    '{schema_version:1, run_id:$run_id, vm_name:("vm-"+$run_id), namespace:"vm-cbt-demo",
      os_profile:"rhel9", manifest_variant:"large-odf", status:$status,
      incremental_passes_completed:$completed, incremental_passes_total:$total,
      guest:{baseline:{file_count:8,total_payload_bytes:1024,manifest_sha256:"baseline-sha"}},
      backups:{full:{name:("vm-backup-"+$run_id),type:"Full",
                      checkpoint_name:("full-"+$run_id),
                      done_reason:"Successfully completed VirtualMachineBackup",
                      pvc_name:("full-pvc-"+$run_id),pvc_capacity:"8Gi"},
               incrementals:[]}}' > "$RUNS_ROOT_DIR/$run_id/run.json"
}

write_summary() {
  local run_id="$1" stage="$2" stage_result="$3"
  RUNS_ROOT_DIR="$RUNS_ROOT_DIR" bash "$ROOT_DIR/scripts/write-run-summary.sh" \
    "$run_id" "$stage" "$stage_result" >/dev/null
}

passed_run=summary-pass
make_run_state "$passed_run" complete 1 1
jq --arg run_id "$passed_run" '
  .backups.incrementals = [{pass:1,name:("vm-incremental-"+$run_id+"-p01"),
    type:"Incremental",checkpoint_name:("inc-"+$run_id),
    done_reason:"Successfully completed VirtualMachineBackup",pvc_capacity:"4Gi",
    files_added:4,files_modified:1,added_payload_bytes:2048,total_file_count:12,
    total_payload_bytes:3072,manifest_sha256:"final-sha"}] |
  .backup_timings = {full:{duration_seconds:7},incrementals:[{pass:1,duration_seconds:3}]}' \
  "$RUNS_ROOT_DIR/$passed_run/run.json" > "$RUNS_ROOT_DIR/$passed_run/run.json.tmp"
mv "$RUNS_ROOT_DIR/$passed_run/run.json.tmp" "$RUNS_ROOT_DIR/$passed_run/run.json"
jq -n --arg run_id "$passed_run" '
  {run_id:$run_id,vm_name:("vm-"+$run_id),namespace:"vm-cbt-demo",os_profile:"rhel9",
   backups:{full:{name:("vm-backup-"+$run_id),type:"Full",checkpoint_name:("full-"+$run_id),
                   done_reason:"Successfully completed VirtualMachineBackup",pvc_capacity:"8Gi"},
            incrementals:[{pass:1,name:("vm-incremental-"+$run_id+"-p01"),type:"Incremental",
                           checkpoint_name:("inc-"+$run_id),done_reason:"Successfully completed VirtualMachineBackup",
                           files_added:4,files_modified:1,added_payload_bytes:2048,total_file_count:12,
                           total_payload_bytes:3072,manifest_sha256:"final-sha",pvc_capacity:"4Gi"}]},
   backup_timings:{full:{duration_seconds:7},incrementals:[{pass:1,duration_seconds:3}]},
   guest:{workload:{baseline:{file_count:8,total_payload_bytes:1024,manifest_sha256:"baseline-sha"},
                    combined:{total_file_count:12,total_payload_bytes:3072,manifest_sha256:"final-sha"}}},
   tracker:{latest_checkpoint:("inc-"+$run_id)},
   verification:{overall_passed:true,checks:[
     {name:"vm_cbt_is_enabled",passed:true},
     {name:"full_backup_is_complete",passed:true},
     {name:"incremental_pass_count_matches_plan",passed:true},
     {name:"incremental_pass_01_is_complete",passed:true},
     {name:"incremental_pass_01_checkpoint_matches_state",passed:true},
     {name:"incremental_pass_01_checkpoint_is_distinct",passed:true},
     {name:"tracker_matches_final_incremental_checkpoint",passed:true},
     {name:"full_restore_file_count_match",passed:true},
     {name:"full_restore_payload_bytes_match",passed:true},
     {name:"full_restore_manifest_match",passed:true},
     {name:"pass_01_restore_file_count_match",passed:true},
     {name:"pass_01_restore_payload_bytes_match",passed:true},
     {name:"pass_01_restore_manifest_match",passed:true}]}}' > "$RUNS_ROOT_DIR/$passed_run/report.json"
write_summary "$passed_run" incremental PASS
jq -e '
  .verdict == "PASS" and .last_invocation.result == "PASS" and
  .verdict_scope == "lifecycle" and .lifecycle.verdict == "PASS" and
  .lifecycle.passes_completed == 1 and
  .cbt.status == "PASS" and .cbt.tracker_matches_final_checkpoint == true and
  .backups.full.status == "PASS" and .backups.full.duration_seconds == 7 and
  .backups.incremental_passes[0].duration_seconds == 3 and .backups.incremental_passes[0].pvc_capacity == "4Gi" and
  .guest_payload.before_full.files == 8 and .guest_payload.after_final_incremental.files == 12 and
  .guest_payload.bytes_added == 2048 and .guest_payload.files_modified == 1 and
  .restore_hashes.status == "PASS" and
  .restore_hashes.full_only == "PASS" and
  .restore_hashes.incremental_prefixes == "PASS" and
  .restore_hashes.failed_restore_check_count == 0 and
  .details.report_json == "report.json" and .data_sources == ["run.json", "report.json"] and
  .phases == [] and .total_elapsed_seconds == null and
  (.scope | contains("does not independently inspect")) and (has("checks") | not)
' "$RUNS_ROOT_DIR/$passed_run/summary.json" >/dev/null

incomplete_run=summary-incomplete
make_run_state "$incomplete_run" incremental_ready 0 1
write_summary "$incomplete_run" full INCOMPLETE
jq -e '
  .verdict == "INCOMPLETE" and .last_invocation.result == "INCOMPLETE" and
  .verdict_scope == "lifecycle" and .lifecycle.verdict == "INCOMPLETE" and
  .backups.full.status == "PASS" and .cbt.status == "PENDING" and
  .guest_payload.before_full.files == 8 and .guest_payload.after_final_incremental.files == 8 and
  .restore_hashes.status == "PENDING" and .restore_hashes.full_only == "PENDING" and
  .restore_hashes.incremental_prefixes == "PENDING" and
  .lifecycle.passes_completed == 0
' "$RUNS_ROOT_DIR/$incomplete_run/summary.json" >/dev/null

failed_run=summary-failed
make_run_state "$failed_run" verification_failed 1 1
jq --arg run_id "$failed_run" '
  .backups.incrementals = [{pass:1,name:("vm-incremental-"+$run_id+"-p01"),
    type:"Incremental",checkpoint_name:("inc-"+$run_id),
    done_reason:"Successfully completed VirtualMachineBackup",total_file_count:12,
    total_payload_bytes:3072,manifest_sha256:"final-sha"}]' \
  "$RUNS_ROOT_DIR/$failed_run/run.json" > "$RUNS_ROOT_DIR/$failed_run/run.json.tmp"
mv "$RUNS_ROOT_DIR/$failed_run/run.json.tmp" "$RUNS_ROOT_DIR/$failed_run/run.json"
jq -n --arg run_id "$failed_run" '
  {run_id:$run_id,verification:{overall_passed:false,checks:[
    {name:"full_restore_manifest_match",passed:true},
    {name:"pass_01_restore_manifest_match",passed:false}]}}' \
  > "$RUNS_ROOT_DIR/$failed_run/report.json"
write_summary "$failed_run" verify FAIL
jq -e '
  .verdict == "FAIL" and .last_invocation.result == "FAIL" and
  .restore_hashes.status == "FAIL" and
  .restore_hashes.incremental_prefixes == "FAIL" and
  .restore_hashes.failed_hash_check_count == 1
' "$RUNS_ROOT_DIR/$failed_run/summary.json" >/dev/null

phases_run=summary-phases
make_run_state "$phases_run" incremental_ready 0 2
jq '
  .stage_timings = [{target:"preflight",seconds:3,at:"2026-10-16T00:00:03Z"},
                    {target:"vm-cbt-backup",seconds:12,at:"2026-10-16T00:00:15Z"},
                    {seconds:5,at:"2026-10-16T00:00:20Z"}] |
  .total_elapsed_seconds = 42' \
  "$RUNS_ROOT_DIR/$phases_run/run.json" > "$RUNS_ROOT_DIR/$phases_run/run.json.tmp"
mv "$RUNS_ROOT_DIR/$phases_run/run.json.tmp" "$RUNS_ROOT_DIR/$phases_run/run.json"
write_summary "$phases_run" incremental INCOMPLETE
jq -e '
  .verdict == "INCOMPLETE" and .lifecycle.state == "incremental_ready" and
  .phases == [{stage:"preflight",seconds:3},{stage:"vm-cbt-backup",seconds:12}] and
  .total_elapsed_seconds == 42
' "$RUNS_ROOT_DIR/$phases_run/summary.json" >/dev/null

# A recovery invocation can be a legitimate PASS while the interrupted
# lifecycle is not: the two scopes must stay distinguishable in the summary.
recover_run=summary-recover-scope
make_run_state "$recover_run" incremental_failed 0 2
jq '.recovery = {attempts:[{id:"r001",status:"success",resources_applied:true,
      failed_full:{name:"vm-backup-failed",checkpoint_name:"failed-cp"},
      recovery_full:{name:"vm-recovery-full",type:"Full",
        done_reason:"Successfully completed VirtualMachineBackup",
        checkpoint_name:"recovered-cp",pvc_name:"recovery-pvc",pvc_phase:"Bound",
        force_full_backup:true},
      restore:{status:"PASS",checks:[{name:"full_restore_manifest_match",passed:true}]}}]}' \
  "$RUNS_ROOT_DIR/$recover_run/run.json" > "$RUNS_ROOT_DIR/$recover_run/run.json.tmp"
mv "$RUNS_ROOT_DIR/$recover_run/run.json.tmp" "$RUNS_ROOT_DIR/$recover_run/run.json"
write_summary "$recover_run" recover PASS
jq -e '
  .verdict == "PASS" and .verdict_scope == "recovery_invocation" and
  .lifecycle.verdict == "FAIL" and .lifecycle.state == "incremental_failed" and
  .last_invocation.stage == "recover" and .last_invocation.result == "PASS" and
  (.verdict_reason | contains("recovery"))
' "$RUNS_ROOT_DIR/$recover_run/summary.json" >/dev/null

printf 'PASS: summary.json reports compact PASS, INCOMPLETE, and FAIL lifecycle states with guest payload, hash-match evidence, and the persisted per-stage phase timings.\n'
