#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/run-id.sh
source "$ROOT_DIR/scripts/run-id.sh"
RUNS_ROOT_DIR="${RUNS_ROOT_DIR:-$ROOT_DIR/runs}"

run_id="${1:-${RUN_ID:-}}"
invocation_type="${2:-unknown}"
invocation_result="${3:-}"
if [[ -z "$run_id" ]] || ! valid_run_id "$run_id"; then
  printf 'Usage: %s <run-id> [stage] [PASS|FAIL|INCOMPLETE]\n' "$0" >&2
  exit 2
fi

run_dir="$RUNS_ROOT_DIR/$run_id"
run_path="$run_dir/run.json"
report_path="$run_dir/report.json"
summary_path="$run_dir/summary.json"
if [[ ! -r "$run_path" ]]; then
  printf 'Run metadata is unavailable: %s\n' "$run_path" >&2
  exit 1
fi

run_json="$(jq -c '.' "$run_path")"
report_json='{}'
if [[ -r "$report_path" ]]; then
  report_json="$(jq -c '.' "$report_path")"
fi
summary_tmp="$summary_path.tmp.$$"
trap 'rm -f "$summary_tmp"' EXIT

jq -n \
  --argjson run "$run_json" \
  --argjson report "$report_json" \
  --arg invocation_type "$invocation_type" \
  --arg invocation_result "$invocation_result" '
  def check($checks; $name):
    ([$checks[]? | select(.name == $name) | .passed]) as $matches
    | if ($matches | length) > 0 then $matches[0] else null end;
  def check_status($checks; $name):
    (check($checks; $name)) as $value
    | if $value == true then "PASS" elif $value == false then "FAIL" else "PENDING" end;
  def backup_status($backup; $expected_type):
    if ($backup | type) != "object" or ($backup.name // "") == "" then "PENDING"
    elif ($backup.type // "") != $expected_type then "FAIL"
    elif (($backup.done_reason // "") | startswith("Backup has failed")) then "FAIL"
    elif ($backup.done_reason // "") == "" then "PENDING"
    elif ($backup.checkpoint_name // "") == "" then "FAIL"
    else "PASS" end;

  ($run.status // "unknown") as $run_status |
  ($report.verification.overall_passed) as $overall_passed |
  ($report.verification.checks // []) as $checks |
  ($report.backups // $run.backups // {}) as $backups |
  ($report.backup_timings // $run.backup_timings // {}) as $timings |
  ($report.guest.workload // {}) as $workload |
  ($workload.baseline // $run.guest.baseline // {}) as $baseline |
  ($backups.incrementals // []) as $incrementals |
  ($incrementals | if length > 0 then .[-1] else {} end) as $last_incremental |
  ($workload.combined // {}) as $combined |
  ($checks | map(select((.name | startswith("full_restore_")) or
                        (.name | test("^pass_[0-9]+_restore_"))))) as $restore_checks |
  ($restore_checks | map(select(.name == "full_restore_manifest_match" or
                                (.name | test("^pass_[0-9]+_restore_manifest_match$"))))) as $hash_checks |
  ($hash_checks | map(select(.name | test("^pass_[0-9]+_restore_manifest_match$")))) as $prefix_hash_checks |
  ($checks | map(select(.name == "vm_cbt_is_enabled" or
                        .name == "full_backup_is_complete" or
                        .name == "incremental_pass_count_matches_plan" or
                        .name == "tracker_matches_final_incremental_checkpoint" or
                        (.name | test("^incremental_pass_[0-9]+_(is_complete|checkpoint_matches_state|checkpoint_is_distinct)$"))))) as $cbt_checks |
  (if $overall_passed == true and $run_status == "complete" then "PASS"
   elif $overall_passed == false or ($run_status | test("(^|_)failed$")) then "FAIL"
   else "INCOMPLETE" end) as $verdict |
  (if ($restore_checks | length) == 0 then "PENDING"
   elif all($restore_checks[]; .passed == true) then "PASS"
   else "FAIL" end) as $restore_status |
  (if ($hash_checks | length) == (($incrementals | length) + 1) and ($hash_checks | length) > 0
   then (if all($hash_checks[]; .passed == true) then "PASS" else "FAIL" end)
   else "PENDING" end) as $all_hash_status |
  (if ($incrementals | length) == 0 or ($prefix_hash_checks | length) != ($incrementals | length) then "PENDING"
   elif all($prefix_hash_checks[]; .passed == true) then "PASS"
   else "FAIL" end) as $prefix_hash_status |
  (if ($cbt_checks | length) == 0 then "PENDING"
   elif all($cbt_checks[]; .passed == true) then "PASS"
   else "FAIL" end) as $cbt_status |
  {
    schema_version: 1,
    run_id: $run.run_id,
    generated_by: "scripts/write-run-summary.sh",
    data_sources: (if $report.run_id != null then ["run.json", "report.json"] else ["run.json"] end),
    scope: "Workflow summary; does not independently inspect qcow2 allocation maps.",
    verdict: $verdict,
    verdict_reason:
      (if $verdict == "PASS" then "All planned incremental passes completed; CBT chain and restore checks passed."
       elif $verdict == "FAIL" then "The lifecycle or verification failed; inspect report.json and workflow.log."
       else "\($run.incremental_passes_completed // 0)/\($run.incremental_passes_total // 0) planned incremental passes complete; final verification is pending." end),
    last_invocation: {
      stage: $invocation_type,
      result: (if $invocation_result == "" then $verdict else $invocation_result end)
    },
    vm: {
      name: ($report.vm_name // $run.vm_name),
      namespace: ($report.namespace // $run.namespace),
      os_profile: ($report.os_profile // $run.os_profile)
    },
    lifecycle: {
      state: $run_status,
      passes_completed: ($run.incremental_passes_completed // 0),
      passes_planned: ($run.incremental_passes_total // 0)
    },
    cbt: {
      status: $cbt_status,
      vm_state: (if check($checks; "vm_cbt_is_enabled") == true then "Enabled"
                 elif check($checks; "vm_cbt_is_enabled") == false then "NotEnabled"
                 else "PENDING" end),
      full_checkpoint: ($backups.full.checkpoint_name // null),
      incremental_checkpoints: [$incrementals[]? | .checkpoint_name],
      tracker_latest_checkpoint: ($report.tracker.latest_checkpoint // $run.tracker.latest_checkpoint // null),
      tracker_matches_final_checkpoint: check($checks; "tracker_matches_final_incremental_checkpoint")
    },
    backups: {
      full: {
        status: backup_status($backups.full; "Full"),
        pvc_capacity: ($backups.full.pvc_capacity // null),
        duration_seconds: ($timings.full.duration_seconds // null)
      },
      incremental_passes: [
        $incrementals[] as $backup |
        ([$timings.incrementals[]? | select(.pass == $backup.pass)] | .[0] // {}) as $timing |
        {
          pass: $backup.pass,
          status: backup_status($backup; "Incremental"),
          files_added: ($backup.files_added // null),
          files_modified: ($backup.files_modified // null),
          payload_bytes_added: ($backup.added_payload_bytes // null),
          pvc_capacity: ($backup.pvc_capacity // null),
          duration_seconds: ($timing.duration_seconds // null)
        }
      ]
    },
    guest_payload: {
      before_full: {
        files: ($baseline.file_count // null),
        bytes: ($baseline.total_payload_bytes // null),
        manifest_sha256: ($baseline.manifest_sha256 // null)
      },
      after_final_incremental: {
        files: ($combined.total_file_count // $last_incremental.total_file_count // $baseline.file_count // null),
        bytes: ($combined.total_payload_bytes // $last_incremental.total_payload_bytes // $baseline.total_payload_bytes // null),
        manifest_sha256: ($combined.manifest_sha256 // $last_incremental.manifest_sha256 // $baseline.manifest_sha256 // null)
      },
      bytes_added: ([$incrementals[]? | (.added_payload_bytes // 0)] | add // 0),
      files_added: ([$incrementals[]? | (.files_added // 0)] | add // 0),
      files_modified: ([$incrementals[]? | (.files_modified // 0)] | add // 0)
    },
    restore_hashes: {
      status: $restore_status,
      full_only: check_status($checks; "full_restore_manifest_match"),
      incremental_prefixes: $prefix_hash_status,
      all: $all_hash_status,
      failed_restore_check_count: ([$restore_checks[] | select(.passed != true)] | length),
      failed_hash_check_count: ([$hash_checks[] | select(.passed != true)] | length),
      algorithm: "SHA-256"
    },
    details: {
      report_json: "report.json",
      restore_log: ($report.verification.restore_log_path // "logs/restore-verify-pod.log")
    }
  }
' > "$summary_tmp"
mv -f "$summary_tmp" "$summary_path"
trap - EXIT
printf 'runs/%s/summary.json\n' "$run_id"
