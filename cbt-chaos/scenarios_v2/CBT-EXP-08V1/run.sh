#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# CBT-EXP-08V1 — delete the run's own VirtualMachineBackupTracker while the full
# backup's copy is in flight
# (spec: cbt-chaos/scenarios_v2/CBT-EXP-08V1/scenario-spec.md, Jira contract in
# jira-issue.md next to it). v2 re-host of EXP-8: same fault, same resolved
# mechanism, freshly re-derived bundle under the mandatory two-file split.
#
# Skill: cbt-chaos-trigger-preparer-v2. Preparation only: this bundle never
# approves itself, never grades its own injection, and never repairs product
# state beyond the approved actions below.
#
# Ownership: run.sh owns the WHOLE sequence (setup, backup creation + window, the
# arming/timing of condition and evidence collection, the stuck-threshold
# measurement, the recovery leg, the summary). No other stage is started by hand.
#   * Lead: allocates CHAOS_RUN_ID/LIFECYCLE_ID, pre-creates the run root and
#     matching run.json, approves the bundle (file hashes + effective parameters
#     + cluster UID) in approval.json, runs --preflight, then --execute, and
#     reports. The Lead starts no stage by hand.
#   * run.sh: make vm-setup -> arm watches -> make vm-backup (background) ->
#     active-copy condition (backup + tracker) -> +15s dwell -> same-instant
#     re-validation -> start the owned oc proxy -> invoke inject.sh for ONE
#     UID-guarded DELETE of the run's tracker -> fail-closed tracker GET must be
#     404 -> sample the backup and the tracker to terminal or the 900s stuck
#     threshold -> virt-controller log window from both replicas (pinned to the
#     delete instant, the wedged-CR delete instant and recovery-done) ->
#     post-fault probes -> join the full stage -> recovery leg (conditional
#     wedged-CR delete, tracker recreation, fresh recovery PVC + backup, operand
#     checks) -> make run-summary.
#   * inject.sh: the fault action only — resolve/guard the target operands, send
#     the single UID-preconditioned DELETE through the owned proxy, report that
#     invocation's status. Everything around it is owned here.
#
# Fault action mechanism: Pattern C (documented oc/kubectl fault action). The
# installed krknctl v0.14.2-beta (+dirty, verified from its module metadata) has
# no scenario that deletes a named custom resource on a condition, and its
# installed --triggers-on-timeout default is `skip` (a timeout would silently
# skip the fault). The run re-records the inspected metadata under
# execution/krkn-metadata.json and treats a missing krknctl as non-fatal, since
# the approved action does not use it. The action is one Kubernetes DELETE with
# DeleteOptions.preconditions.uid through an owned local `oc proxy`; an
# unguarded delete-by-name is never used.
#
# Exit codes are orchestration only, never a product verdict:
#   0   injection proven on the approved object AND the recovery leg reached its
#       verified terminal state
#   1   sequence completed but injection or recovery leg not proven/terminal
#       (raw evidence preserved; e.g. a wedged CR that could not be released)
#   2   BLOCKED: guard/precondition/environment/action failure, no injection
#   4   window miss, or the fail-closed postcondition of the approved injection
#       (tracker GET 404) was not met (harness-invalid window/action)
#   124 wall-clock budget exhausted
# =============================================================================
SCENARIO_ID='CBT-EXP-08V1'
BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$BUNDLE/../../.." && pwd)"
cd "$ROOT"
mode="${1:---plan}"
[[ $# -le 1 ]] || { printf 'expected one mode\n' >&2; exit 2; }
fail() { printf '%s BLOCKED: %s\n' "$SCENARIO_ID" "$*" >&2; exit 2; }
# Identity guard: a copied bundle that kept another scenario's directory must
# fail here instead of writing evidence into the wrong scenario.
[[ "$(basename "$BUNDLE")" == "$SCENARIO_ID" ]] ||
  { printf 'bundle directory %s does not match scenario %s\n' "$(basename "$BUNDLE")" "$SCENARIO_ID" >&2; exit 2; }
if [[ "$mode" == --manifest ]]; then cat "$BUNDLE/bundle-files.txt"; exit 0; fi
case "$mode" in --plan|--check-root|--preflight|--execute) ;; *) fail 'use --plan, --manifest, --check-root, --preflight or --execute';; esac
# This entrypoint is non-interactive: nothing here, or in the stages it calls,
# reads answers or data from the caller's terminal. Detach stdin once so a
# filter that forgets an input operand reaches EOF instead of blocking on an
# inherited open stdin (a live attempt once hung ~64 min that way, and the
# wall-clock budget cannot fire during a blocked read). Every herestring,
# heredoc, pipe and file operand below still supplies its own stdin.
exec </dev/null
: "${CHAOS_RUN_ID:?Lead must allocate the chaos attempt ID with cbt-chaos/run-id.sh}"
: "${LIFECYCLE_ID:?Lead must allocate a separate short lifecycle ID}"
source "$ROOT/scripts/run-id.sh"
# Shell primitives (budget/oc/record/capture/UID guard/stop/RBAC/collision/
# canonical-jq) come from the shared runtime instead of being re-authored here.
# shellcheck source=../../../cbt-chaos/scenario-runtime.sh
source "$ROOT/cbt-chaos/scenario-runtime.sh"
valid_run_id "$LIFECYCLE_ID" || fail 'invalid lifecycle ID'
# The note slug is fixed by this scenario (tracker-delete); the attempt ID must
# name exactly this lifecycle's VM and keep the full digest, never truncated.
CHAOS_RUN_ID_RE="^[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-vm-${LIFECYCLE_ID}-tracker-delete-iteration-[1-9][0-9]*$"
[[ "$CHAOS_RUN_ID" =~ $CHAOS_RUN_ID_RE && ${#CHAOS_RUN_ID} -le 255 ]] ||
  fail 'attempt ID must be generated for the exact planned VM by cbt-chaos/run-id.sh with note slug tracker-delete'
[[ "$(basename "$(dirname "$BUNDLE")")" == 'scenarios_v2' &&
   "$(basename "$(dirname "$(dirname "$BUNDLE")")")" == 'cbt-chaos' ]] ||
  fail 'bundle is not under cbt-chaos/scenarios_v2/<ID>'
export RUN_ID="$LIFECYCLE_ID"
# Read by scripts/run-id.sh's set_resource_names (sourced below).
# shellcheck disable=SC2034
RUNS_ROOT_DIR="$ROOT/runs"
set_resource_names
EVIDENCE="$BUNDLE/runs/$CHAOS_RUN_ID"
CONTROL_VM="${CONTROL_VM:-vm-cbt-demo}"
RECOVERY_ATTEMPT_ID='r001'
RECOVERY_BACKUP_NAME="vm-recovery-full-${LIFECYCLE_ID}-${RECOVERY_ATTEMPT_ID}"
RECOVERY_PVC_NAME="vm-recovery-pvc-${LIFECYCLE_ID}-${RECOVERY_ATTEMPT_ID}"
# Approved test windows (seconds). Windows are observation bounds, not product SLAs.
SETUP_TIMEOUT=2400
FULL_TIMEOUT=1500
CONDITION_TIMEOUT=600
CONDITION_POLL_SECONDS=1
DWELL_SECONDS=15
REVALIDATE_TIMEOUT=15
PROBE_OFFSET_SECONDS=5
TRACKER_GONE_TIMEOUT=60
TRACKER_GONE_POLL_SECONDS=1
STUCK_THRESHOLD_SECONDS=900
OBSERVATION_SAMPLE_SECONDS=15
CONTROLLER_PULL_TIMEOUT=120
FULL_JOIN_GRACE=30
WEDGED_DELETE_TIMEOUT=300
WEDGED_DELETE_POLL_SECONDS=2
WEDGED_RELEASE_AFTER_TRACKER_TIMEOUT=180
TRACKER_RECREATE_TIMEOUT=60
RECOVERY_READY_TIMEOUT=300
RECOVERY_PVC_TIMEOUT=900
RECOVERY_BACKUP_TIMEOUT=1500
TRACKER_ADVANCE_TIMEOUT=60
SUMMARY_TIMEOUT=120
TOTAL_TIMEOUT=10800
WATCH_MAX_SECONDS=10800

check_root() {
  # Accept the Lead's pre-armed root (identity + non-terminal phase, verdict
  # null); refuse any prior action/effect output and any reused lifecycle.
  [[ -d "$EVIDENCE" && ! -L "$EVIDENCE" && -r "$EVIDENCE/run.json" ]] || fail 'Lead must pre-create a fresh real run root with run.json'
  jq -e --arg id "$CHAOS_RUN_ID" --arg life "$LIFECYCLE_ID" --arg vm "$VM_NAME" '
      .scenario_id == "CBT-EXP-08V1" and .run_id == $id and .lifecycle_id == $life
      and .vm_name == $vm and (.phase == "started" or .phase == "running")
      and (.verdict // null) == null' "$EVIDENCE/run.json" >/dev/null ||
    fail 'run.json must carry scenario_id=CBT-EXP-08V1, the exact run_id/lifecycle_id/vm_name, phase started|running and verdict null'
  local path
  for path in execution trigger observer action action.json effect effect.json condition.json \
              inject-result.txt inject-result.json tracker-samples.json backup-samples.json \
              tracker-deletion.json controller-window.log controller-window.json \
              backup-final.yaml tracker-final.yaml wedged-deletion.json tracker-recreation.json \
              recovery-backup.yaml recovery-operand-checks.json injection-confirmation.json \
              analysis.json trigger.log; do
    [[ ! -e "$EVIDENCE/$path" && ! -L "$EVIDENCE/$path" ]] || fail "prior output exists: $path"
  done
  [[ ! -e "$ROOT/runs/$LIFECYCLE_ID" ]] || fail 'lifecycle artifacts already exist for this lifecycle ID'
}

if [[ "$mode" == --check-root ]]; then check_root; exit 0; fi
if [[ "$mode" == --plan ]]; then
  jq -n --arg id "$CHAOS_RUN_ID" --arg life "$LIFECYCLE_ID" --arg vm "$VM_NAME" \
        --arg scenario "$SCENARIO_ID" --arg id_regex "$CHAOS_RUN_ID_RE" \
        --arg rec_backup "$RECOVERY_BACKUP_NAME" --arg rec_pvc "$RECOVERY_PVC_NAME" \
        --arg control "$CONTROL_VM" \
        --argjson total "$TOTAL_TIMEOUT" --argjson setup "$SETUP_TIMEOUT" --argjson full "$FULL_TIMEOUT" \
        --argjson condition_timeout "$CONDITION_TIMEOUT" --argjson condition_poll "$CONDITION_POLL_SECONDS" \
        --argjson dwell "$DWELL_SECONDS" --argjson revalidate "$REVALIDATE_TIMEOUT" \
        --argjson probe_offset "$PROBE_OFFSET_SECONDS" --argjson gone "$TRACKER_GONE_TIMEOUT" \
        --argjson stuck "$STUCK_THRESHOLD_SECONDS" --argjson sample "$OBSERVATION_SAMPLE_SECONDS" \
        --argjson controller_pull "$CONTROLLER_PULL_TIMEOUT" --argjson join_grace "$FULL_JOIN_GRACE" \
        --argjson wedged "$WEDGED_DELETE_TIMEOUT" --argjson release "$WEDGED_RELEASE_AFTER_TRACKER_TIMEOUT" \
        --argjson recreate "$TRACKER_RECREATE_TIMEOUT" --argjson rec_ready "$RECOVERY_READY_TIMEOUT" \
        --argjson rec_pvc_bound "$RECOVERY_PVC_TIMEOUT" --argjson rec_backup_bound "$RECOVERY_BACKUP_TIMEOUT" \
        --argjson advance "$TRACKER_ADVANCE_TIMEOUT" --argjson summary "$SUMMARY_TIMEOUT" '
    {scenario:$scenario,
     title:"Delete the run full-backup VirtualMachineBackupTracker mid-copy (API-side entry to the no-deadline wedge)",
     chaos_run_id:$id, lifecycle_id:$life, vm:$vm, owner:"run.sh (whole sequence)",
     chaos_run_id_regex:$id_regex,
     run_json_contract:{scenario_id:$scenario, run_id:$id, lifecycle_id:$life, vm_name:$vm,
       phase:"started|running", verdict:null},
     body_root:("cbt-chaos/scenarios_v2/" + $scenario),
     stages:[
       "run.sh: make vm-setup RUN_ID=<lifecycle> (setup, " + ($life) + ")",
       "run.sh: capture baseline identities + arm scoped read-only watches (vm, vmi, target vmbackup, all vmbackups, target tracker, launchers, vm/backup/tracker events)",
       "run.sh: start make vm-backup RUN_ID=<lifecycle> as a recorded background child (do not wait)",
       "run.sh: active-copy compound condition (1s poll, bounded 600s): backup Progressing=True, Done!=True, no deletionTimestamp, run-scoped labels/source/pvc, launcher Backup-started log line, live QMP backup job 0<offset<len, VMI Running on the same UID, and the run tracker present with the exact UID, spec.source = this VM and no checkpoint yet",
       "run.sh: +15s mid-copy dwell, then same-instant re-validation of the backup (UID, not Done, not deleting, run-scoped) AND the tracker (UID, checkpoint still unset, not deleting)",
       "run.sh: start the owned local oc proxy, then invoke inject.sh (the separate mandatory fault-action file) with the revalidated NAMESPACE/TRACKER_NAME/TRACKER_UID/API_BASE/API_GROUP/BODY_FILE operands; inject.sh sends exactly one UID-preconditioned DELETE (DeleteOptions.preconditions.uid) and reports its own status",
       "run.sh: fail-closed postcondition: the tracker GET must return HTTP 404 within " + ($gone|tostring) + "s; every GET response code is recorded",
       "run.sh: sample the backup and the tracker every " + ($sample|tostring) + "s to terminal or the " + ($stuck|tostring) + "s stuck threshold (raw + projected snapshots with resourceVersion; a stuck object is a product measurement, never auto-repaired)",
       "run.sh: collect the virt-controller log window from BOTH replicas (label kubevirt.io=virt-controller, namespace openshift-cnv, all containers, --timestamps) in three pinned pulls: `end` since the delete instant, `wedged` since the wedged-CR delete instant, `recovery-done` since the recovery leg start; controller-window.log is rebuilt from every phase with ANSI escapes stripped before the machine line counts",
       "run.sh: +" + "5" + "s post-fault probes (VMI phase/Paused/volumeStatus, launcher domblklist + QMP jobs/block-nodes + checkpoint-list, VM CBT backupStatus, wedged backup, tracker) and a settled re-probe after the bound",
       "run.sh: destination-PVC identity correlation (PVC/PV/CSI handle/VolumeAttachment, API-level) and blast-radius exclusion comparison (name->UID maps before vs after; control VM unchanged)",
       "run.sh: recovery leg: (a) if not terminal, one UID-guarded DELETE of the wedged VirtualMachineBackup via the owned proxy, bounded " + ($wedged|tostring) + "s, never forced; (b) recreate the tracker by re-applying the tracker manifest shape when absent, bounded " + ($recreate|tostring) + "s; (c) observe the wedged CR again for up to " + ($release|tostring) + "s; (d) fresh " + $rec_pvc + " + " + $rec_backup + " with forceFullBackup=true, bounded Done wait, operand + tracker-advance checks; run.json recovery.attempts r001",
       "run.sh: make run-summary RUN_ID=<lifecycle> (read-only)"],
     profile:{VM_OS:"rhel9", MANIFEST_VARIANT:"large-odf", namespace:"vm-cbt-demo",
       baseline_files:1000, incremental_files:1000, incremental_passes:1,
       file_size_min_mib:15, file_size_max_mib:20, inventory_verify:"full",
       incremental_pvc_size:"30Gi", full_destination_disk:"80Gi",
       profile_source:"explicitly set in run.sh and passed on the make command line, matching the approved execution-host .env values",
       restore_image:"digest-pinned RESTORE_HELPER_IMAGE (the run rejects a non-digest reference)"},
     fault:{kind:"custom_resource_delete", target_kind:"VirtualMachineBackupTracker",
       target_name:("vm-tracker-" + $life),
       target_selection:"exact name + virt-cbt-lab/run-id label + spec.source.kind=VirtualMachine + spec.source.name=<run VM>, then the live UID as the DELETE precondition",
       mechanism:"uid_preconditioned_DeleteOptions_via_owned_local_oc_proxy",
       action_file:"inject.sh",
       action_contract:{argv:["bash","<bundle>/inject.sh"],
         inputs:["NAMESPACE","TRACKER_NAME","TRACKER_UID","API_BASE (loopback oc proxy)","API_GROUP=backup.kubevirt.io/v1alpha1","BODY_FILE"],
         scope:"one DELETE request and its own status; no probe/retry/rollback/recovery",
         exits:{"0":"DELETE accepted (200/202)","1":"API answered with another status","2":"malformed operand, nothing sent","3":"transport failure"}},
       uses_krkn:false,
       krkn_metadata_checked:["krknctl list available","krknctl describe pod-scenarios",
         "krknctl describe kubevirt-outage","krknctl run pod-scenarios --help",
         "krknctl run kubevirt-outage --help"],
       krkn_version:"v0.14.2-beta+dirty (module version from `go version -m`; the binary has no `version` subcommand)",
       krkn_gap:"no installed scenario deletes a named custom resource on a condition",
       krkn_trigger_note:"the installed --triggers-on-timeout default is skip, so a krkn trigger timeout would silently skip the fault; this bundle acts itself with an explicit fail-closed window instead",
       grace_period_seconds:0, max_deletions:1,
       fail_closed:"after the DELETE the tracker GET must return HTTP 404 inside the bounded window; otherwise the attempt stops with the raw evidence preserved and no recovery leg",
       window:("active-copy compound condition, then +" + ($dwell|tostring) + "s dwell, then same-instant re-validation of the backup and the tracker"),
       on_window_miss:"exit 4 with evidence preserved; never retried silently"},
     recovery:{attempt_id:"r001", pvc:$rec_pvc, backup:$rec_backup, force_full_backup:true,
       wedged_cr_delete:{mechanism:"uid_preconditioned_DeleteOptions_via_owned_local_oc_proxy",
         bounded_seconds:$wedged, forced:false,
         note:"a retained finalizer/deletionTimestamp is recorded as a product measurement; it is never removed or bypassed"},
       tracker_recreation:{method:"re-apply the tracker manifest shape (spec.source = the run VM) only when the tracker is absent, bounded",
         bounded_seconds:$recreate},
       wedged_release_after_tracker_seconds:$release,
       fresh_backup_bounded_seconds:1500,
       tracker_advance_bounded_seconds:$advance,
       restore_test:"NOT_INCLUDED: the spec recovery criterion is a fresh backup plus tracker recreation; no restore pod or restore test is part of this bundle",
       not_used:["make vm-cbt-verify","make vm-cbt-recover","make vm-cbt-restore-test"],
       reason:"vm-cbt-recover requires a Done=True failed backup CR and vm-cbt-verify requires .backups.full; a tracker-deleted mid-copy backup satisfies neither"},
     bounds_seconds:{total:$total, setup:$setup, condition:$condition_timeout,
       dwell:$dwell, revalidate:$revalidate, full_stage:$full,
       tracker_gone:$gone, stuck_threshold:$stuck,
       observation_sample:$sample, controller_pull:$controller_pull,
       full_join_grace:$join_grace, post_fault_probe_offset:$probe_offset,
       wedged_delete:$wedged, wedged_release_after_tracker:$release,
       tracker_recreate:$recreate, recovery_ready:$rec_ready,
       recovery_pvc_bound:$rec_pvc_bound, recovery_backup:$rec_backup_bound,
       tracker_advance:$advance, run_summary:$summary},
     exit_codes:{"0":"injection proven AND recovery leg terminal (backup_verified)","1":"completed but not proven",
       "2":"BLOCKED guard/precondition/action failure","4":"window miss or unconfirmed fail-closed postcondition","124":"wall-clock exhausted"},
     exclusions:{control_vm:$control,
       scope:"one VM, one tracker (deliberately deleted), one destination PVC retained as evidence; the recovery leg may delete the run own wedged backup CR once and adds one re-applied tracker, one PVC and one backup on the same VM",
       comparison:"name->UID maps for vm/vmi/vmbackup/vmbackuptracker/pvc before vs after, this attempt own names excluded"},
     evidence_root:("cbt-chaos/scenarios_v2/" + $scenario + "/runs/" + $id),
     lifecycle_evidence:("runs/" + $life),
     write_scope:{creates_or_deletes:["the run own VM/disk/service/tracker/destination PVC via make vm-setup and make vm-backup",
       "the one approved VirtualMachineBackupTracker (delete)",
       "at most one UID-guarded delete of the run own wedged VirtualMachineBackup during the recovery leg",
       "one re-applied tracker manifest for the same run when the tracker is absent",
       "one recovery PVC and one recovery backup"],
       never:["no inspector/debug pod","no finalizer edit and no forced delete","no cleanup of retained artifacts",
         "no other run resources","no cluster-scoped mutation"]},
     evaluator:{status:"NOT_APPLICABLE",
       reason:"no clause-set evaluator maps to a mid-copy tracker deletion; the independent Analyst grades the raw evidence"},
     named_criteria:["active-copy-window-proven","same-instant-backup-and-tracker-revalidation",
       "uid-guarded-tracker-delete-accepted","fail-closed-tracker-get-404","backup-terminal-or-stuck-at-threshold",
       "controller-window-both-replicas","controller-window-pinned-to-delete-wedged-and-recovery",
       "stuck-sample-resource-version-surfaced",
       "vmi-healthy-unfrozen","hotplug-attachment-recorded",
       "wedged-cr-deletion-outcome","tracker-recreation-recorded","recovery-full-backup-operands",
       "blast-radius-exclusions"],
     product_verdict:"independent Analyst; this bundle writes machine observations only"}
  '
  exit 0
fi
check_root
[[ "${STAGE_SKIP_PREFLIGHT:-false}" != true && "${E2E_STAGE_WRAPPED:-false}" != true && "${STAGE_DRY_RUN:-false}" != true ]] || fail 'stage preflight bypass/dry-run environment is forbidden'
source "$ROOT/scripts/dotenv.sh"
load_dotenv_defaults "$ROOT/.env"
: "${KUBECONFIG_PATH:?host-local kubeconfig required}"
: "${RESTORE_HELPER_IMAGE:?existing restore helper image required}"
[[ "$RESTORE_HELPER_IMAGE" == *@sha256:* ]] || fail 'pin RESTORE_HELPER_IMAGE to its approved digest (@sha256:...) in .env before approval'
GUEST_KEY="${GUEST_KEY:-$ROOT/keys/id_ed25519}"
[[ "$GUEST_KEY" == /* ]] || GUEST_KEY="$ROOT/$GUEST_KEY"
export GUEST_KEY
# The profile is explicit here and repeated on every make command line, so the
# effective parameters cannot drift from what the stages receive.
export VM_OS=rhel9 MANIFEST_VARIANT=large-odf NAMESPACE=vm-cbt-demo
export GUEST_BASE_FILE_COUNT=1000 GUEST_INCREMENTAL_FILE_COUNT=1000 GUEST_INCREMENTAL_PASSES=1
export GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20 GUEST_INVENTORY_VERIFY=full
export STAGE_SKIP_PREFLIGHT=false E2E_STAGE_WRAPPED=false STAGE_DRY_RUN=false
export INCREMENTAL_PVC_SIZE=30Gi
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
set_resource_names
make_cmd=(make --no-print-directory VM_OS=rhel9 MANIFEST_VARIANT=large-odf
  NAMESPACE=vm-cbt-demo GUEST_BASE_FILE_COUNT=1000 GUEST_INCREMENTAL_FILE_COUNT=1000
  GUEST_INCREMENTAL_PASSES=1 GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20
  GUEST_INVENTORY_VERIFY=full STAGE_SKIP_PREFLIGHT=false E2E_STAGE_WRAPPED=false
  STAGE_DRY_RUN=false INCREMENTAL_PVC_SIZE=30Gi "RESTORE_HELPER_IMAGE=$RESTORE_HELPER_IMAGE"
  "KUBECONFIG_PATH=$KUBECONFIG_PATH" "GUEST_KEY=$GUEST_KEY")
# Every external tool this entrypoint and inject.sh rely on (sed/grep/find are on
# the log-strip and evidence-copy path, not only in the stages).
for tool in oc jq timeout sha256sum make curl setsid sed grep find; do command -v "$tool" >/dev/null || fail "missing $tool"; done
[[ -r "$KUBECONFIG_PATH" ]] || fail 'unreadable kubeconfig'
source "$BUNDLE/guest-key-approval.sh"
guest_key_approval="$(guest_key_approval_parameters "$GUEST_KEY")" || fail 'configured guest key is unreadable or not a regular file'
guest_key_mode="$(jq -er '.mode | select(.=="existing-pair" or .=="setup-managed")' <<<"$guest_key_approval")" || fail 'invalid guest key approval mode'
guest_public_sha256="$(jq -r '.public_sha256 // empty' <<<"$guest_key_approval")"
key_setup_complete=false
setup_guest_public_sha256=''
# The approval binds every effective parameter; secrets and paths are only ever hashed.
context_sha256="$(timeout -k 2 15 oc config view --minify -o json 2>/dev/null | sha256sum | cut -d ' ' -f1)"
[[ -n "$context_sha256" ]] || fail 'could not fingerprint the current oc context'
host_sha256="$(hostname | sha256sum | cut -d ' ' -f1)"
params="$(jq -n --arg id "$CHAOS_RUN_ID" --arg life "$LIFECYCLE_ID" \
  --arg scenario "$SCENARIO_ID" \
  --arg restore "$RESTORE_HELPER_IMAGE" --arg host "$host_sha256" --arg context "$context_sha256" \
  --arg guest_mode "$guest_key_mode" --arg guest "$guest_public_sha256" \
  --arg control "$CONTROL_VM" --arg rec_backup "$RECOVERY_BACKUP_NAME" --arg rec_pvc "$RECOVERY_PVC_NAME" \
  --argjson dwell "$DWELL_SECONDS" --argjson condition_timeout "$CONDITION_TIMEOUT" \
  --argjson condition_poll "$CONDITION_POLL_SECONDS" --argjson revalidate "$REVALIDATE_TIMEOUT" \
  --argjson stuck "$STUCK_THRESHOLD_SECONDS" --argjson sample "$OBSERVATION_SAMPLE_SECONDS" \
  --argjson gone "$TRACKER_GONE_TIMEOUT" --argjson gone_poll "$TRACKER_GONE_POLL_SECONDS" \
  --argjson probe_offset "$PROBE_OFFSET_SECONDS" --argjson wedged "$WEDGED_DELETE_TIMEOUT" \
  --argjson recreate "$TRACKER_RECREATE_TIMEOUT" --argjson release "$WEDGED_RELEASE_AFTER_TRACKER_TIMEOUT" \
  --argjson rec_backup_bound "$RECOVERY_BACKUP_TIMEOUT" --argjson advance "$TRACKER_ADVANCE_TIMEOUT" \
  --argjson total "$TOTAL_TIMEOUT" --argjson setup "$SETUP_TIMEOUT" --argjson full "$FULL_TIMEOUT" \
  --argjson join_grace "$FULL_JOIN_GRACE" --argjson controller_pull "$CONTROLLER_PULL_TIMEOUT" \
  --argjson rec_ready "$RECOVERY_READY_TIMEOUT" --argjson rec_pvc_bound "$RECOVERY_PVC_TIMEOUT" \
  --argjson summary "$SUMMARY_TIMEOUT" --argjson watch_max "$WATCH_MAX_SECONDS" '
  {scenario:$scenario, chaos_run_id:$id, lifecycle_id:$life, namespace:"vm-cbt-demo", vm_os:"rhel9",
   manifest_variant:"large-odf", baseline_files:1000, incremental_files:1000, incremental_passes:1,
   file_size_min_mib:15, file_size_max_mib:20, incremental_pvc_size:"30Gi",
   guest_inventory_verify:"full", restore_image:$restore,
   host_sha256:$host, context_sha256:$context,
   guest_key:{mode:$guest_mode, public_sha256:(if $guest == "" then null else $guest end)},
   control_vm:$control,
   fault:{target_kind:"VirtualMachineBackupTracker", action:"delete",
     mechanism:"uid_preconditioned_DeleteOptions_via_owned_local_oc_proxy",
     action_file:"inject.sh",
     uses_krkn:false, grace_period_seconds:0, max_deletions:1,
     target:("this run own tracker vm-tracker-" + $life),
     fail_closed:"tracker GET must be HTTP 404 inside the bounded window after the DELETE"},
   window:{dwell_seconds:$dwell, condition_timeout_seconds:$condition_timeout,
     condition_poll_seconds:$condition_poll, revalidate_timeout_seconds:$revalidate},
   observation:{stuck_threshold_seconds:$stuck,
     sample_interval_seconds:$sample,
     tracker_gone_timeout_seconds:$gone,
     tracker_gone_poll_seconds:$gone_poll,
     post_fault_probe_offset_seconds:$probe_offset,
     controller_log_scope:"openshift-cnv pods labelled kubevirt.io=virt-controller (both replicas, all containers), three pinned pulls: end (since the delete-request instant), wedged (since the wedged-CR delete instant), recovery-done (since the recovery leg start)"},
   recovery:{attempt_id:"r001", pvc_name:$rec_pvc, backup_name:$rec_backup,
     force_full_backup:true,
     wedged_cr_delete:{uid_guarded:true, bounded_seconds:$wedged, forced:false},
     tracker_recreation:{when:"tracker absent", bounded_seconds:$recreate},
     wedged_release_after_tracker_seconds:$release,
     fresh_backup_bounded_seconds:$rec_backup_bound,
     tracker_advance_bounded_seconds:$advance,
     restore_test:"NOT_INCLUDED_BY_SPEC"},
   timeouts:{total:$total, setup:$setup, full_stage:$full,
     full_join_grace:$join_grace, controller_pull:$controller_pull,
     recovery_ready:$rec_ready, recovery_pvc_bound:$rec_pvc_bound,
     recovery_backup:$rec_backup_bound, wedged_delete:$wedged,
     wedged_release_after_tracker:$release,
     tracker_recreate:$recreate, run_summary:$summary},
   watch_max_seconds:$watch_max,
   blast_radius:{vms:1, trackers_deleted:1, backup_crs_deleted_max:1, destination_pvcs:1,
     trackers_reapplied_max:1, recovery_pvcs:1, recovery_backups:1, shared_resources:0},
   preserve_failed_resources:true}')" || fail 'could not build effective parameters'
assert_guest_key_state() {
  local current
  if [[ "$key_setup_complete" == true ]]; then
    current="$(guest_key_capture_after_setup "$GUEST_KEY")" || fail 'guest key pair unreadable after setup'
    [[ "$current" == "$setup_guest_public_sha256" ]] || fail 'guest public key changed after setup'
    if [[ "$guest_key_mode" == existing-pair ]]; then
      [[ "$current" == "$guest_public_sha256" ]] || fail 'setup changed the approved guest public key'
    fi
  else
    current="$(guest_key_approval_parameters "$GUEST_KEY")" || fail 'configured guest key is unreadable or not a regular file'
    [[ "$current" == "$guest_key_approval" ]] || fail 'guest key state changed after approved parameters were calculated'
  fi
}
check_approval() {
  local approval="$BUNDLE/approval.json" file digest expected
  assert_guest_key_state
  jq -e --argjson p "$params" '
      .scenario_id == "CBT-EXP-08V1" and .status == "APPROVED"
      and (.approved_by | type == "string" and length > 0)
      and (.approved_at | type == "string" and length > 0)
      and (.cluster_uid | type == "string" and length > 0)
      and .parameters == $p' "$approval" >/dev/null ||
    fail 'explicit approval (APPROVED + approved_by + approved_at + cluster_uid) or effective parameters mismatch'
  expected="$(jq -r '.files | keys[]' "$approval" | LC_ALL=C sort)"
  [[ "$expected" == "$(LC_ALL=C sort "$BUNDLE/bundle-files.txt")" ]] ||
    fail 'approval must hash exactly the declared manifest (no missing or extra file)'
  while IFS= read -r file; do
    [[ -f "$ROOT/$file" && ! -L "$ROOT/$file" ]] || fail "missing or symlinked dependency: $file"
    digest="$(sha256sum "$ROOT/$file" | cut -d ' ' -f1)"
    [[ "$digest" == "$(jq -er --arg f "$file" '.files[$f]' "$approval")" ]] || fail "changed dependency: $file"
  done < "$BUNDLE/bundle-files.txt"
}
# Non-mutating preflight needs no approval; execution does, before any output.
if [[ "$mode" == --execute ]]; then check_approval; fi
WORK="$EVIDENCE/preflight"
[[ "$mode" == --execute ]] && WORK="$EVIDENCE/execution"
mkdir "$WORK" 2>/dev/null || fail "evidence directory already exists: ${WORK#"$ROOT"/} (a fresh attempt needs a fresh pre-armed root)"
# Fingerprints are SHA-256 over the bundle's own files, and every projection is
# jq-1.6 syntax: refuse a non-canonical jq (e.g. a jaq shim) before anything is
# hashed or compared.
ccv2_assert_canonical_jq "$WORK"
printf '%s\n' "$params" > "$WORK/effective-parameters.json"
DEADLINE=$((SECONDS + TOTAL_TIMEOUT))
full_pid='' proxy_pid='' lock_owned=false
watch_pids=()
watch_names=()
# Machine observations assembled during execution; the Analyst verifies the raw
# artifacts behind each one. Defaults stay null so an early stop cannot look clean.
condition_recorded=false
active_copy_signal=false
active_job_observed=false
delete_requested=false
delete_transport_rc=''
delete_http_status=''
tracker_get_404=false
delete_accepted=false
effect_observed=false
stuck_at_threshold=null
terminal_observed=false
tracker_controller_recreated=false
wedged_cr_delete_requested=false
wedged_cr_release='unknown'
window_reason=''
tlog() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$EVIDENCE/trigger.log"
}
# Markers so an interrupted run still shows how far the sequence reached.
stage_mark() {
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/stage-$1.utc"
  tlog "stage $1"
}
stop_group() {
  # Bounded TERM-then-KILL of one process group started by this invocation; the
  # shared runtime records the joined status in <label>.rc under the work dir.
  ccv2_stop_group "$WORK" "$@"
}
cleanup() {
  local rc=$? pid watch_index watch_rc
  trap - EXIT INT TERM
  if [[ -n "$full_pid" ]]; then
    stop_group "$full_pid" "cleanup-full-join" || true
    full_pid=''
  fi
  if [[ -n "$proxy_pid" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
    kill -TERM "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi
  proxy_pid=''
  for ((watch_index=0; watch_index<${#watch_pids[@]}; watch_index++)); do
    pid="${watch_pids[$watch_index]}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
    if wait "$pid"; then watch_rc=0; else watch_rc=$?; fi
    printf '%s\n' "$watch_rc" > "$WORK/watch-${watch_names[$watch_index]}.status"
  done
  watch_pids=()
  watch_names=()
  if [[ "$lock_owned" == true ]]; then
    rm -f "$ROOT/state/e2e.lock/pid"
    rmdir "$ROOT/state/e2e.lock" 2>/dev/null || true
  fi
  printf '%s\n' "$rc" > "$WORK/entrypoint.status"
  terminal=FAILED
  case "$rc" in 0) terminal=COMPLETED;; 1) terminal=INCOMPLETE;; 2) terminal=BLOCKED;; 4) terminal=WINDOW_MISSED;; 124|137) terminal=TIMED_OUT;; esac
  jq -n --arg terminal "$terminal" --argjson rc "$rc" --arg reason "$window_reason" \
    '{orchestration_terminal:$terminal,child_rc:$rc,window_reason:(if $reason=="" then null else $reason end),product_verdict:null,analyst_required:true}' \
    > "$WORK/terminal.json" || true
  if [[ "$mode" == --execute && ! -e "$EVIDENCE/injection-confirmation.json" ]]; then
    jq -n --argjson condition "$condition_recorded" --argjson requested "$delete_requested" \
      --arg http "$delete_http_status" --argjson get404 "$tracker_get_404" \
      --argjson accepted "$delete_accepted" --argjson effect "$effect_observed" '
      {schema_version:1,scenario_id:"CBT-EXP-08V1",authored_machine_observations:true,
       author_grades_injection:false,independent_analyst_required:true,
       checks:{condition_recorded:$condition,delete_requested:$requested,
         delete_http_status:(if $http=="" then null else ($http|tonumber?) end),
         tracker_get_404:$get404,delete_accepted:$accepted,effect_observed:$effect},
       verdict:null,
       reason:"Entrypoint stopped before the complete machine checks; inspect the raw execution artifacts and per-child statuses",
       references:["execution/terminal.json","execution/"]}' > "$EVIDENCE/injection-confirmation.json" || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
budget() {
  # Shared bounded-budget primitive: exits 124 when the approved wall clock is
  # exhausted (never returns a negative remaining time).
  ccv2_budget_remaining "$DEADLINE"
}
api() {
  # Bounded read/write oc call through the shared runtime (15s cap, or less when
  # the attempt's wall clock is nearly spent).
  ccv2_oc "$DEADLINE" "$@"
}
record() {
  # record <name> <limit-seconds> <cmd...>: bounded child, combined log,
  # child_rc preserved in <name>.status.json.
  ccv2_record "$WORK" "$DEADLINE" "$@"
}
capture() {
  # capture <name> <limit-seconds> <dest-file> <cmd...>
  ccv2_capture "$WORK" "$DEADLINE" "$@"
}
require_uid() {
  # A value read from a bundle-authored artifact must never silently degrade to
  # the string "null": inside an --arg operand a failed extraction is otherwise
  # indistinguishable from a real value, and the comparison it feeds then just
  # never matches (iteration 3 of the reference scenario aborted a genuinely
  # confirmed copy window that way). ccv2_require_uid exits 2 (BLOCKED) and
  # names the operand.
  ccv2_require_uid "$@"
}
# ANSI escapes are stripped at the read boundary before any tool log is parsed:
# a colored INFO line can otherwise null a log-derived check or glue ESC[0m onto
# a parsed name and corrupt an identity comparison.
strip_ansi() {
  # strip_ansi <input-file> <output-file>
  LC_ALL=C sed -E $'s/\x1B\\[[0-9;?]*[A-Za-z]//g' "$1" > "$2"
}
# ---------- scenario-local helpers --------------------------------------------
# Defined above the preflight section on purpose: the UID-guarded delete
# mechanism rehearsal in --preflight calls api_proxy_start/proxy_stop, and
# bash resolves function names at call time, so every helper must be defined
# above its first call site.
start_watch() {
  local name="$1"
  shift
  WATCH_MAX_SECONDS="$WATCH_MAX_SECONDS" timeout -k 5 "$((WATCH_MAX_SECONDS + 15))" \
    bash "$ROOT/cbt-chaos/watch-resource.sh" "$@" "$WORK/watch-$name.jsonl" "$WORK/watch-$name.ready" \
    > "$WORK/watch-$name.log" 2>&1 &
  watch_pids+=("$!")
  watch_names+=("$name")
}
stop_watch() {
  local index="$1" pid="${watch_pids[$1]}" rc
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  if wait "$pid"; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" > "$WORK/watch-${watch_names[$index]}.status"
  watch_pids[$index]=''
}
resolve_launcher() {
  local outfile="$1"
  api get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json > "$outfile" || return 1
  launcher="$(jq -er -L "$BUNDLE" --arg vmi_uid "$vmi_uid" '
    include "checks";
    [.items[] | select(ready and owned_by("VirtualMachineInstance"; $vmi_uid))]
    | if length == 1 then .[0].metadata.name else error("ambiguous launcher") end' "$outfile")" || return 1
  launcher_uid="$(jq -er --arg n "$launcher" '.items[] | select(.metadata.name == $n) | .metadata.uid' "$outfile")" || return 1
}
qmp() {
  local launcher_pod="$1" request="$2" out="$3"
  api exec -n "$NAMESPACE" "$launcher_pod" -c compute -- \
    virsh qemu-monitor-command "${NAMESPACE}_${VM_NAME}" "$request" > "$out" 2> "$out.stderr"
}
api_proxy_start() {
  local port code deadline
  PROXY_PORT=''
  for _ in 1 2 3 4 5; do
    port=$(( (RANDOM % 20000) + 20000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then PROXY_PORT="$port"; break; fi
  done
  [[ -n "$PROXY_PORT" ]] || return 1
  timeout -k 5 120 oc proxy --address=127.0.0.1 --port="$PROXY_PORT" > "$WORK/proxy.log" 2>&1 &
  proxy_pid=$!
  deadline=$((SECONDS+30))
  while (( SECONDS < deadline )); do
    code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PROXY_PORT/version" 2>/dev/null || true)"
    if [[ "$code" == 200 ]]; then printf '%s\n' "$code" > "$WORK/proxy-ready.http"; return 0; fi
    kill -0 "$proxy_pid" 2>/dev/null || { proxy_pid=''; return 1; }
    sleep 0.5
  done
  return 1
}
proxy_stop() {
  local rc
  if [[ -n "$proxy_pid" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
    kill -TERM "$proxy_pid" 2>/dev/null || true
    if wait "$proxy_pid"; then rc=0; else rc=$?; fi
    printf '%s\n' "$rc" > "$WORK/proxy-stop.status"
  fi
  proxy_pid=''
}
inventory() {
  local label="$1" kind
  for kind in vmbackup vmbackuptracker vm vmi pvc; do
    if api get "$kind" -n "$NAMESPACE" -o json > "$WORK/inventory-$label-$kind.json" 2> "$WORK/inventory-$label-$kind.stderr"; then
      printf 'captured\n' > "$WORK/inventory-$label-$kind.state"
    else
      printf 'unavailable\n' > "$WORK/inventory-$label-$kind.state"
      rm -f "$WORK/inventory-$label-$kind.json"
    fi
  done
}
# Read-only view of the fault target and of every surface the abort/aftermath is
# reported on. API-level absence is not host-level release.
capture_post_fault() {
  local label="$1"
  local vmi_out="$WORK/vmi-after-$label.json"
  local vm_out="$WORK/vm-after-$label.json"
  local tracker_out="$WORK/tracker-after-$label.json"
  local backup_out="$WORK/backup-after-$label.json"
  local domblk="$WORK/domblklist-after-$label.log"
  api get vmi "$VM_NAME" -n "$NAMESPACE" -o json > "$vmi_out" 2> "$WORK/vmi-read-$label.stderr" || rm -f "$vmi_out"
  api get vm "$VM_NAME" -n "$NAMESPACE" -o json > "$vm_out" 2> "$WORK/vm-read-$label.stderr" || rm -f "$vm_out"
  if api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$tracker_out" 2> "$WORK/tracker-read.stderr"; then :; else
    if grep -q NotFound "$WORK/tracker-read.stderr" 2>/dev/null; then
      printf '{"absent":true}\n' > "$tracker_out"
    else
      printf '{"unreadable":true}\n' > "$tracker_out"
    fi
  fi
  if api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o json > "$backup_out" 2> "$WORK/backup-read.stderr"; then :; else
    if grep -q NotFound "$WORK/backup-read.stderr" 2>/dev/null; then
      printf '{"absent":true}\n' > "$backup_out"
    else
      printf '{"unreadable":true}\n' > "$backup_out"
    fi
  fi
  if [[ -s "$vmi_out" ]]; then
    # The destination volume's own attachment entry is the guest-effect surface
    # for the Jira criterion; an API-level absence is not host-level release.
    jq -L "$BUNDLE" --arg pvc "$FULL_BACKUP_PVC_NAME" '
      include "checks";
      {phase:(.status.phase // null), paused:paused_condition,
       volume_status:volume_status, hotplug:any_hotplug,
       destination_attachment:hotplug_attachment($pvc)}' "$vmi_out" > "$WORK/vmi-after-$label-summary.json" 2>> "$WORK/projection-errors.log" || true
  fi
  if [[ -s "$vm_out" ]]; then
    jq '{ready:([.status.conditions[]? | select(.type=="Ready") | .status] | last // null),
      cbt_state:(.status.changedBlockTracking.state // null),
      backup_status:(.status.changedBlockTracking.backupStatus // null)}' "$vm_out" > "$WORK/vm-after-$label-summary.json" 2>> "$WORK/projection-errors.log" || true
  fi
  if [[ -s "$tracker_out" ]]; then
    jq -L "$BUNDLE" --arg vm "$VM_NAME" 'include "checks";
      {present:((.absent // false) | not), unreadable:(.unreadable // false),
       uid:(.metadata.uid // null),
       deletion_timestamp:(.metadata.deletionTimestamp // null),
       finalizers:(.metadata.finalizers // []),
       source_vm_ok:tracker_source_vm($vm), checkpoint:tracker_checkpoint}' \
      "$tracker_out" > "$WORK/tracker-after-$label-summary.json" 2>> "$WORK/projection-errors.log" || true
  fi
  if [[ -s "$backup_out" ]]; then
    jq -L "$BUNDLE" 'include "checks";
      {present:((.absent // false) | not), unreadable:(.unreadable // false),
       uid:(.metadata.uid // null),
       deletion_timestamp:(.metadata.deletionTimestamp // null),
       finalizers:(.metadata.finalizers // []), done_status:done_status, done_reason:done_reason,
       terminal:terminal, progressing:progressing, initializing:initializing,
       type:(.status.type // null), checkpoint:(.status.checkpointName // null),
       included_volumes:(.status.includedVolumes // [])}' \
      "$backup_out" > "$WORK/backup-after-$label-summary.json" 2>> "$WORK/projection-errors.log" || true
  fi
  if resolve_launcher "$WORK/launchers-after-$label.json"; then
    capture "domblklist-$label" 30 "$domblk" oc --request-timeout=10s exec -n "$NAMESPACE" "$launcher" -c compute -- \
      virsh domblklist "${NAMESPACE}_${VM_NAME}" || true
    capture "guest-jobs-$label" 30 "$WORK/guest-jobs-after-$label.json" oc --request-timeout=10s exec -n "$NAMESPACE" "$launcher" -c compute -- \
      virsh qemu-monitor-command "${NAMESPACE}_${VM_NAME}" '{"execute":"query-block-jobs"}' || true
    capture "guest-nodes-$label" 30 "$WORK/guest-nodes-after-$label.json" oc --request-timeout=10s exec -n "$NAMESPACE" "$launcher" -c compute -- \
      virsh qemu-monitor-command "${NAMESPACE}_${VM_NAME}" '{"execute":"query-named-block-nodes"}' || true
    capture "guest-checkpoints-$label" 30 "$WORK/guest-checkpoints-after-$label.log" oc --request-timeout=10s exec -n "$NAMESPACE" \
      "$launcher" -c compute -- virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --name || true
  else
    printf 'launcher unavailable for guest probes at %s\n' "$label" > "$WORK/guest-probes-$label.unavailable"
  fi
}
# The backup after the fault: a wedged one stays Progressing/Initializing with
# no Done, so the sample must be a fail-closed projection of the raw object.
backup_sample() {
  local index="$1" prefix out raw
  prefix="$(printf '%03d' "$index")"
  out="$WORK/observation/backup/$prefix.json"
  raw="$WORK/observation/backup/$prefix.raw"
  mkdir -p "$WORK/observation/backup"
  if api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" --ignore-not-found -o json > "$raw" 2>/dev/null; then
    get_rc=0
  else
    get_rc=$?
  fi
  if (( get_rc == 0 )) && [[ -s "$raw" ]]; then
    jq -L "$BUNDLE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson index "$index" '
      include "checks";
      {index:$index, at:$at, present:true, unreadable:false, get_rc:0, uid:.metadata.uid,
       resource_version:.metadata.resourceVersion,
       deletion_timestamp:(.metadata.deletionTimestamp // null),
       finalizers:(.metadata.finalizers // []),
       done_status:done_status, done_reason:done_reason, terminal:terminal,
       progressing:progressing, initializing:initializing, deleting:deleting,
       progress_reason:progress_reason, initializing_reason:initializing_reason,
       type:(.status.type // null), checkpoint:(.status.checkpointName // null),
       included_volumes:(.status.includedVolumes // [])}' "$raw" > "$out"
    return 0
  fi
  rm -f "$raw"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson index "$index" --argjson rc "$get_rc" \
    '{index:$index, at:$at, present:false, unreadable:($rc != 0), get_rc:$rc}' > "$out"
  return 1
}
# The tracker after the fault: whether the product recreated it, and with which
# identity, is part of the scenario's own question.
tracker_sample() {
  local index="$1" prefix out raw
  prefix="$(printf '%03d' "$index")"
  out="$WORK/observation/tracker/$prefix.json"
  raw="$WORK/observation/tracker/$prefix.raw"
  mkdir -p "$WORK/observation/tracker"
  if api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" --ignore-not-found -o json > "$raw" 2>/dev/null; then
    get_rc=0
  else
    get_rc=$?
  fi
  if (( get_rc == 0 )) && [[ -s "$raw" ]]; then
    jq -L "$BUNDLE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson index "$index" --arg vm "$VM_NAME" '
      include "checks";
      {index:$index, at:$at, present:true, unreadable:false, get_rc:0, uid:.metadata.uid,
       resource_version:resource_version, deleting:deleting,
       deletion_timestamp:(.metadata.deletionTimestamp // null),
       finalizers:(.metadata.finalizers // []),
       source_vm_ok:tracker_source_vm($vm), checkpoint:tracker_checkpoint,
       checkpoint_age:(.status.latestCheckpoint.creationTimestamp // null)}' "$raw" > "$out"
    return 0
  fi
  rm -f "$raw"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson index "$index" --argjson rc "$get_rc" \
    '{index:$index, at:$at, present:false, unreadable:($rc != 0), get_rc:$rc}' > "$out"
  return 1
}
# The scenario's direct mechanism evidence: what the two virt-controller
# replicas logged around the fault. Three pulls are pinned (end, wedged,
# recovery-done) because a delete-instant window alone can legitimately contain
# zero run-scoped lines while the decisive lines appear when the wedged CR is
# released or the recovery backup starts. Every pull covers all pods matching
# the label at that moment, all containers, since that phase's pin instant.
collect_controller_window() {
  local phase="$1" since="$2" raw_dir="$WORK/controller-raw" name uid rc out pulls='[]'
  mkdir -p "$raw_dir"
  if ! api get pods -n openshift-cnv -l kubevirt.io=virt-controller -o json > "$WORK/controller-pods-$phase.json" 2>/dev/null; then
    printf '{"items":[]}\n' > "$WORK/controller-pods-$phase.json"
    jq -n --arg phase "$phase" --arg since "$since" \
      '{phase:$phase,since_time:$since,captured:false,reason:"pod list unavailable",pods:[],pulls:[]}' \
      > "$WORK/controller-pull-$phase.json"
    return 1
  fi
  jq -c '[.items[] | {name:.metadata.name, uid:.metadata.uid, node:(.spec.nodeName // null),
      phase:(.status.phase // null), restarts:([.status.containerStatuses[]?.restartCount] | add // 0)}]' \
    "$WORK/controller-pods-$phase.json" > "$WORK/controller-podlist-$phase.json"
  : > "$WORK/controller-pull-$phase.log"
  while IFS=$'\t' read -r name uid; do
    [[ -n "$name" ]] || continue
    out="$raw_dir/$phase-$name.log"
    if timeout -k 10 "$CONTROLLER_PULL_TIMEOUT" oc --request-timeout=20s logs -n openshift-cnv "$name" \
        --all-containers=true --timestamps=true --since-time="$since" --limit-bytes=8388608 \
        > "$out" 2> "$out.stderr"; then rc=0; else rc=$?; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$rc" "$out" >> "$WORK/controller-pull-$phase.log"
    pulls="$(jq -c --arg n "$name" --arg u "$uid" --argjson rc "$rc" --arg f "${out#"$WORK"/}" \
      '. + [{pod:$n, pod_uid:(if $u=="-" then null else $u end), pull_rc:$rc, raw:$f}]' <<<"$pulls")"
  done < <(jq -r '.[] | [.name, (.uid // "-")] | @tsv' "$WORK/controller-podlist-$phase.json")
  jq -n --arg phase "$phase" --arg since "$since" \
    --argjson pods "$(cat "$WORK/controller-podlist-$phase.json" 2>/dev/null || printf '[]')" \
    --argjson pulls "$pulls" '
    {phase:$phase, since_time:$since, captured:true, pods:$pods, pulls:$pulls,
     pods_pulled:($pulls|length), pulls_failed:([$pulls[]|select(.pull_rc != 0)]|length)}' \
    > "$WORK/controller-pull-$phase.json"
  return 0
}
build_controller_window_report() {
  # Rebuilt from every collected phase, ANSI-stripped at the read boundary: a
  # colored line must not hide a mechanism line or corrupt a grep count.
  local since_epoch="$1" raw_dir="$WORK/controller-raw" f base phase stripped
  local tracker_404 update_deleting total_lines per_phase='{}' phases_json
  local phase_absent phase_deleting phase_file
  : > "$EVIDENCE/controller-window.log"
  : > "$WORK/controller-phases.txt"
  {
    printf '# %s virt-controller log window\n' "$SCENARIO_ID"
    printf '# tracker: %s\n' "$TRACKER_NAME"
    printf '# source: oc logs -n openshift-cnv <pod> --all-containers=true --timestamps=true --since-time=<phase pin instant>\n'
    printf '# expected phases: end (delete instant), wedged (wedged-CR delete instant), recovery-done (recovery leg start)\n'
    printf '# ANSI escape sequences are stripped in this file; raw per-pod copies keep the original bytes\n'
    printf '# raw per-pod copies: execution/controller-raw/\n'
    printf '# pulled at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$EVIDENCE/controller-window.log"
  if [[ -d "$raw_dir" ]]; then
    for f in "$raw_dir"/*-*.log; do
      [[ -e "$f" ]] || continue
      case "$f" in *.stripped.log) continue;; esac
      base="$(basename "$f" .log)"
      phase="${base%%-*}"
      grep -qxF -- "$phase" "$WORK/controller-phases.txt" 2>/dev/null ||
        printf '%s\n' "$phase" >> "$WORK/controller-phases.txt"
      stripped="$raw_dir/$base.stripped.log"
      if ! strip_ansi "$f" "$stripped"; then
        # Never let an unreadable raw copy silently vanish from the window.
        printf '\n===== %s (strip failed; raw bytes not included) =====\n' "$base" >> "$EVIDENCE/controller-window.log"
        continue
      fi
      {
        printf '\n===== %s (pull phase %s) =====\n' "$base" "$phase"
        cat "$stripped"
        printf '\n===== end %s =====\n' "$base"
      } >> "$EVIDENCE/controller-window.log"
    done
  fi
  # Per-phase counts come from that phase's own stripped pulls, never from the
  # cumulative report.
  while IFS= read -r phase; do
    [[ -n "$phase" ]] || continue
    phase_absent=0
    phase_deleting=0
    for phase_file in "$raw_dir/$phase"-*.stripped.log; do
      [[ -e "$phase_file" ]] || continue
      phase_absent=$((phase_absent + $(grep -c -- "BackupTracker $TRACKER_NAME does not exist" "$phase_file" 2>/dev/null || true)))
      phase_deleting=$((phase_deleting + $(grep -c -- 'update backup is deleting' "$phase_file" 2>/dev/null || true)))
    done
    per_phase="$(jq -c --arg p "$phase" --argjson a "$phase_absent" --argjson d "$phase_deleting" \
      '. + {($p):{tracker_absent_line_count:$a, update_backup_is_deleting_line_count:$d}}' <<<"$per_phase")"
  done < "$WORK/controller-phases.txt"
  phases_json="$(jq -R . < "$WORK/controller-phases.txt" | jq -sc 'map(select(length>0))')"
  tracker_404="$(grep -c -- "BackupTracker $TRACKER_NAME does not exist" "$EVIDENCE/controller-window.log" 2>/dev/null || true)"
  update_deleting="$(grep -c -- 'update backup is deleting' "$EVIDENCE/controller-window.log" 2>/dev/null || true)"
  total_lines="$(wc -l < "$EVIDENCE/controller-window.log" | tr -d ' ')"
  jq -n --arg scenario "$SCENARIO_ID" --arg tracker "$TRACKER_NAME" --argjson since "${since_epoch:-0}" \
    --argjson lines "${total_lines:-0}" --argjson absent_lines "${tracker_404:-0}" \
    --argjson deleting_lines "${update_deleting:-0}" --argjson phases "$phases_json" \
    --argjson per_phase "$per_phase" \
    --argjson raw_files "$(find "$raw_dir" -name '*.log' ! -name '*.stripped.log' 2>/dev/null | wc -l | tr -d ' ')" '
    {artifact:"controller-window.log", scenario:$scenario, window_since_epoch:$since,
     total_lines:$lines, pulled_raw_files:$raw_files, phases:$phases,
     per_phase_line_counts:$per_phase,
     tracker_absent_line_count:$absent_lines,
     update_backup_is_deleting_line_count:$deleting_lines,
     tracker_absent_line_present:($absent_lines > 0),
     ansi_stripped_at_read_boundary:true,
     note:"line counts are a machine observation over the pulled window; the Analyst reads the raw lines and the per-pod copies under execution/controller-raw/. Absence of these two strings is not evidence of absence of a wedge: a provably silent wedge keeps resourceVersion frozen with no log line.",
     searched_strings:("BackupTracker " + $tracker + " does not exist", "update backup is deleting")}' \
    > "$EVIDENCE/controller-window.json"
  tlog "controller-window.log built: phases=$phases_json lines=$total_lines tracker_absent_lines=$tracker_404"
}
# --- independent rehearsal shape: platform preflight -------------------------
jq -n --arg namespace "$NAMESPACE" --arg vm "$VM_NAME" --arg backup "$FULL_BACKUP_NAME" \
  --arg pvc "$FULL_BACKUP_PVC_NAME" --arg tracker "$TRACKER_NAME" \
  --arg rec_backup "$RECOVERY_BACKUP_NAME" --arg rec_pvc "$RECOVERY_PVC_NAME" \
  --arg attempt "$RECOVERY_ATTEMPT_ID" --arg control "$CONTROL_VM" \
  '{namespace:$namespace, vm:$vm, backup:$backup, pvc:$pvc, tracker:$tracker,
    recovery_backup:$rec_backup, recovery_pvc:$rec_pvc, recovery_attempt:$attempt,
    control_vm:$control}' > "$WORK/input.json"
mkdir "$WORK/polls"
record make-preflight 180 "${make_cmd[@]}" preflight
record oc-version 15 oc version --client
record jq-version 15 jq --version
record make-version 15 make --version
record curl-version 15 curl --version
# krkn metadata is recorded to document WHY this bundle uses a documented
# oc/kubectl fault action (Pattern C). The fault action does not use krkn, so a
# missing krknctl cannot make the approved mechanism unusable; it is recorded.
if command -v krknctl >/dev/null 2>&1; then
  krkn_available=true
  # The installed binary has no `version` subcommand (verified on the execution
  # host: `krknctl version` errors). Record the binary identity and, when the go
  # toolchain is present, the module version from the binary's build metadata.
  record krkn-binary 30 sha256sum "$(command -v krknctl)" || true
  if command -v go >/dev/null 2>&1; then
    record krkn-module-version 30 go version -m "$(command -v krknctl)" || true
  else
    printf 'go toolchain unavailable: module version not read\n' > "$WORK/krkn-module-version.log"
  fi
  record krkn-list 60 krknctl list available || true
  record krkn-describe-pod-scenarios 60 krknctl describe pod-scenarios || true
  record krkn-describe-kubevirt-outage 60 krknctl describe kubevirt-outage || true
  record krkn-help-pod-scenarios 60 krknctl run pod-scenarios --help || true
  record krkn-help-kubevirt-outage 60 krknctl run kubevirt-outage --help || true
else
  krkn_available=false
  printf 'krknctl unavailable on this host\n' > "$WORK/krkn-unavailable.log"
fi
jq -n --argjson available "$krkn_available" '
  {krknctl_available:$available,
   fault_action_uses_krkn:false,
   pattern:"C (documented oc/kubectl fault action)",
   installed_version:"v0.14.2-beta+dirty (module version on the execution host; the binary exposes no `version` subcommand)",
   metadata_checked:["krknctl list available","krknctl describe pod-scenarios",
     "krknctl describe kubevirt-outage","krknctl run pod-scenarios --help",
     "krknctl run kubevirt-outage --help"],
   missing_capability:"no installed scenario deletes a named custom resource (VirtualMachineBackupTracker) on a condition; pod/container scenarios kill pods or containers and kubevirt-outage deletes a VMI",
   trigger_capability:"the installation does expose k8s/command triggers, but its --triggers-on-timeout default is skip, which would silently skip the fault on timeout; this bundle therefore acts itself with an explicit fail-closed window",
   note:"krkn metadata is recorded to document why Pattern C is used; the approved action does not use krkn, so an absent krknctl is non-fatal",
   raw:["krkn-binary.log","krkn-module-version.log","krkn-list.log",
     "krkn-describe-pod-scenarios.log","krkn-describe-kubevirt-outage.log",
     "krkn-help-pod-scenarios.log","krkn-help-kubevirt-outage.log","krkn-unavailable.log"]}' \
  > "$WORK/krkn-metadata.json"
# Required permissions for this scenario (reads, the one tracker delete, the one
# recovery-leg backup delete, the recovery leg, and read-only guest probes
# through the existing launcher). Authorization on cluster-scoped resources does
# not depend on the namespace argument.
namespace_permissions="$(ccv2_check_permissions "$NAMESPACE" "$DEADLINE" \
  "vmbackup get" "vmbackup list" "vmbackup watch" "vmbackup delete" \
  "vmbackuptracker get" "vmbackuptracker list" "vmbackuptracker watch" \
  "vmbackuptracker delete" "vmbackuptracker create" \
  "pvc get" "pvc list" "pvc watch" "pvc create" \
  "pod get" "pod list" "pod watch" "pods/exec create" "pods/log get" \
  "event get" "event list" "event watch" \
  "vm get" "vm list" "vm watch" "vmi get" "vmi list" "vmi watch")" ||
  fail 'permission probe failed to run'
cluster_permissions="$(ccv2_check_permissions "$NAMESPACE" "$DEADLINE" \
  "node get" "pv get" "volumeattachment get")" || fail 'cluster-scope permission probe failed to run'
cnv_permissions="$(ccv2_check_permissions openshift-cnv "$DEADLINE" \
  "deployment get" "lease get" "pod get" "pods/log get")" || fail 'openshift-cnv permission probe failed to run'
permission_failures="$(jq -cn --argjson a "$namespace_permissions" --argjson b "$cluster_permissions" \
  --argjson c "$cnv_permissions" '$a + $b + $c')" || fail 'could not merge permission results'
printf '%s\n' "$permission_failures" > "$WORK/permissions.json"
[[ "$permission_failures" == '[]' ]] || fail "missing required permissions: $permission_failures"
# Cluster identity, storage headroom, quotas, source image, node population.
api get namespace kube-system -o json | jq '{uid:.metadata.uid}' > "$WORK/cluster.json" || fail 'cannot read the cluster identity'
cluster_uid_value="$(jq -r '.uid // empty' "$WORK/cluster.json" 2>/dev/null || true)"
require_uid 'cluster identity uid' "$cluster_uid_value"
if [[ "$mode" == --execute ]]; then
  [[ "$(jq -er .cluster_uid "$BUNDLE/approval.json")" == "$(jq -er .uid "$WORK/cluster.json")" ]] || fail 'approved cluster identity mismatch'
fi
api get storageclass ocs-storagecluster-ceph-rbd -o json > "$WORK/storageclass.json" || fail 'cannot read the destination StorageClass'
jq -e '.provisioner == "openshift-storage.rbd.csi.ceph.com" and .parameters.clusterID == "openshift-storage" and .parameters.pool == "ocs-storagecluster-cephblockpool"' \
  "$WORK/storageclass.json" >/dev/null || fail 'destination StorageClass is not the approved ODF RBD profile'
record ceph-status 45 oc --request-timeout=10s exec -n openshift-storage deployment/rook-ceph-tools -- ceph status --format json
jq -e '.health.status == "HEALTH_OK"' "$WORK/ceph-status.log" >/dev/null || fail 'Ceph is not HEALTH_OK'
record ceph-df 45 oc --request-timeout=10s exec -n openshift-storage deployment/rook-ceph-tools -- ceph df --format json
# 500 GiB logical headroom covers the 80 Gi root clone, the 80 Gi destination,
# the 80 Gi recovery destination and a reserve. No capacity is reserved here.
jq -e -L "$BUNDLE" 'include "checks"; pool_headroom("ocs-storagecluster-cephblockpool"; 536870912000)' \
  "$WORK/ceph-df.log" >/dev/null || fail 'missing or insufficient trustworthy ODF logical headroom'
api get resourcequota -n "$NAMESPACE" -o json > "$WORK/quotas.json" || fail 'cannot read namespace quotas'
jq -e -L "$BUNDLE" 'include "checks"; no_storage_quota' "$WORK/quotas.json" >/dev/null ||
  fail 'storage/PVC quota present: capacity needs a separate approved calculation'
api get datasource rhel9 -n openshift-virtualization-os-images -o json > "$WORK/datasource.json" || fail 'cannot read the rhel9 DataSource'
source_pvc_name="$(jq -er '.spec.source.pvc.name' "$WORK/datasource.json")" || fail 'rhel9 DataSource has no source PVC'
source_pvc_ns="$(jq -er '.spec.source.pvc.namespace' "$WORK/datasource.json")" || fail 'rhel9 DataSource source PVC has no namespace'
api get pvc "$source_pvc_name" -n "$source_pvc_ns" -o json > "$WORK/source-pvc.json" || fail 'cannot read the source PVC'
jq -e '.status.phase == "Bound"' "$WORK/source-pvc.json" >/dev/null || fail 'source PVC is not Bound'
jq -n --arg ds rhel9 --arg ns "$source_pvc_ns" --arg pvc "$source_pvc_name" \
  --arg uid "$(jq -er .metadata.uid "$WORK/source-pvc.json")" \
  --arg class "$(jq -r '.spec.storageClassName // ""' "$WORK/source-pvc.json")" \
  '{datasource:"rhel9",pvc_name:$pvc,pvc_namespace:$ns,pvc_uid:$uid,storage_class:$class,phase:"Bound"}' \
  > "$WORK/source.json"
api get nodes -o json > "$WORK/nodes.json" || fail 'cannot read the node population'
ready_workers="$(jq '[.items[] | select(.status.conditions | any(.type=="Ready" and .status=="True")) | select(.metadata.labels["node-role.kubernetes.io/worker"] != null)] | length' "$WORK/nodes.json")"
((ready_workers >= 2)) || fail "fewer than two Ready workers ($ready_workers): the VM cannot be scheduled safely"
jq '[.items[] | select(.status.conditions | any(.type=="Ready" and .status=="True")) | {name:.metadata.name, uid:.metadata.uid}] | sort_by(.name)' \
  "$WORK/nodes.json" > "$WORK/ready-nodes.json"
# The fault target is a run-scoped tracker, so the observer needs the
# virt-controller replicas to exist and to be readable for the log window.
api get pods -n openshift-cnv -l kubevirt.io=virt-controller -o json > "$WORK/controller-pods-preflight.json" ||
  fail 'cannot read the virt-controller pods (required for the controller log window)'
controller_replicas="$(jq '[.items[] | select(.status.phase == "Running")] | length' "$WORK/controller-pods-preflight.json")"
((controller_replicas >= 1)) || fail 'no Running virt-controller replica: the controller log window cannot be captured'
api get deploy virt-controller -n openshift-cnv -o json > "$WORK/controller-deployment.json" || fail 'cannot read the virt-controller deployment'
jq -n --argjson running "$controller_replicas" \
  --argjson spec_replicas "$(jq '.spec.replicas // null' "$WORK/controller-deployment.json")" \
  --argjson ready "$(jq '.status.readyReplicas // null' "$WORK/controller-deployment.json")" '
  {running_virt_controller_pods:$running, deployment_spec_replicas:$spec_replicas,
   deployment_ready_replicas:$ready,
   log_scope:"namespace openshift-cnv, label kubevirt.io=virt-controller, every pod seen at each of the three pulls (end, wedged, recovery-done), --since-time = the pin instant of that phase",
   note:"both replicas are pulled so a replacement replica is captured too; a container restart inside one pod is not covered (restartCount was 0 at preparation)"}' \
  > "$WORK/controller-replicas.json"
# Name-collision absence for the fresh lifecycle, including the read-only
# delete-mechanism probe name (it must never exist).
collisions="$(ccv2_check_name_collisions "$NAMESPACE" "$DEADLINE" \
  "vmbackup:$FULL_BACKUP_NAME" "vmbackuptracker:$TRACKER_NAME" "pvc:$FULL_BACKUP_PVC_NAME" \
  "vmbackup:$RECOVERY_BACKUP_NAME" "pvc:$RECOVERY_PVC_NAME" \
  "vm:$VM_NAME" "datavolume:$DV_NAME" "service:$SSH_SERVICE" \
  "vmbackuptracker:vm-tracker-rehearsal-nonexistent-$LIFECYCLE_ID")" ||
  fail 'name-collision probe failed to run'
printf '%s\n' "$collisions" > "$WORK/name-collisions.json"
[[ "$collisions" == '[]' ]] || fail "fresh-lifecycle name collision/unknown state: $collisions"
# Delete-mechanism rehearsal: an owned local proxy must serve the API and the
# DeleteOptions precondition body must be parsed by the API server. The DELETE
# targets a tracker name that must never exist, so this probe cannot mutate.
proxy_probe_ok=false
if api_proxy_start; then
  probe_path="/apis/backup.kubevirt.io/v1alpha1/namespaces/$NAMESPACE/virtualmachinebackuptrackers/vm-tracker-rehearsal-nonexistent-$LIFECYCLE_ID"
  jq -n '{apiVersion:"v1",kind:"DeleteOptions",gracePeriodSeconds:0,preconditions:{uid:"00000000-0000-0000-0000-000000000000"}}' > "$WORK/proxy-probe-options.json"
  if probe_code="$(curl --noproxy '*' -sS --max-time 20 -X DELETE -H 'Content-Type: application/json' \
      --data-binary @"$WORK/proxy-probe-options.json" -o "$WORK/proxy-probe-response.json" \
      -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT$probe_path" 2> "$WORK/proxy-probe.stderr")"; then probe_rc=0; else probe_rc=$?; fi
  # A GET on the same row proves the read path used by the fail-closed check.
  probe_get_code="$(curl --noproxy '*' -sS --max-time 20 -o "$WORK/proxy-probe-get-response.json" \
    -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT$probe_path" 2>/dev/null || true)"
  printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":123}}' > "$WORK/proxy-probe-invalid.json"
  probe_invalid_code="$(curl --noproxy '*' -sS --max-time 20 -X DELETE -H 'Content-Type: application/json' \
    --data-binary @"$WORK/proxy-probe-invalid.json" -o "$WORK/proxy-probe-invalid-response.json" \
    -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT$probe_path" 2>/dev/null || true)"
  # The fault-action file itself is exercised once against a tracker name that
  # must never exist: it must accept the operands, render the preconditioned
  # body, send the one DELETE and report the API's 404 (its own exit 1 =
  # answered but not accepted). This is a rehearsal of the action file, not a
  # discovery step, and it cannot mutate an existing object.
  inject_smoke_dir="$WORK/inject-smoke"
  mkdir -p "$inject_smoke_dir"
  if inject_smoke_out="$(NAMESPACE="$NAMESPACE" \
        TRACKER_NAME="vm-tracker-rehearsal-nonexistent-$LIFECYCLE_ID" \
        TRACKER_UID="00000000-0000-0000-0000-000000000000" \
        API_BASE="http://127.0.0.1:$PROXY_PORT" API_GROUP='backup.kubevirt.io/v1alpha1' \
        BODY_FILE="$inject_smoke_dir/delete-options.json" \
        timeout -k 5 60 bash "$BUNDLE/inject.sh" < /dev/null 2> "$inject_smoke_dir/inject.stderr")"; then
    inject_smoke_rc=0
  else
    inject_smoke_rc=$?
  fi
  printf '%s\n' "$inject_smoke_out" > "$inject_smoke_dir/inject.stdout"
  inject_smoke_http="$(printf '%s\n' "$inject_smoke_out" | sed -n 's/^http_status=//p')"
  inject_body_ok=false
  if jq -e '.kind == "DeleteOptions" and .gracePeriodSeconds == 0
       and .preconditions.uid == "00000000-0000-0000-0000-000000000000"' \
       "$inject_smoke_dir/delete-options.json" >/dev/null 2>&1; then inject_body_ok=true; fi
  proxy_stop
  jq -n --arg code "$probe_code" --argjson rc "$probe_rc" --arg invalid "$probe_invalid_code" \
    --arg get_code "$probe_get_code" --argjson smoke_rc "$inject_smoke_rc" \
    --arg smoke_http "$inject_smoke_http" --argjson smoke_body "$inject_body_ok" '
    {probe_delete_http_status:($code|tonumber?),transport_rc:$rc,
     probe_get_http_status:($get_code|tonumber?),
     invalid_precondition_http_status:($invalid|tonumber?),
     body_parsed_by_api:($invalid=="400"),
     action_file_smoke:{path:"inject.sh", exit_status:$smoke_rc,
       http_status:($smoke_http|tonumber?), body_rendered:$smoke_body,
       expected:"exit 1 with http 404 on a nonexistent tracker name"},
     interpretation:"404 on a nonexistent tracker proves path+body routing for both the DELETE and the GET; 400 on a wrongly typed precondition uid proves the API server parses preconditions.uid; the action-file smoke proves inject.sh accepts its operands and reports the real status. No request can mutate an existing object.",
     raw:["proxy-probe-options.json","proxy-probe-response.json","proxy-probe-get-response.json","proxy-probe-invalid-response.json","inject-smoke/","proxy.log"]}' \
    > "$WORK/proxy-probe.json"
  if [[ "$probe_code" == 404 && "$probe_invalid_code" == 400 && "$probe_get_code" == 404 &&
        "$inject_smoke_rc" == 1 && "$inject_smoke_http" == 404 && "$inject_body_ok" == true ]]; then
    proxy_probe_ok=true
  fi
fi
rm -f "$WORK/proxy-probe-options.json" "$WORK/proxy-probe-invalid.json"
[[ "$proxy_probe_ok" == true ]] || fail 'UID-guarded delete mechanism (owned oc proxy + DeleteOptions preconditions + GET read + the inject.sh action contract) is not usable on this host'
# Guest key state and restore image are approval-visible metadata only.
guest_key_approval_parameters "$GUEST_KEY" > "$WORK/guest-key-preflight.json" || fail 'guest key unreadable'
jq -n --arg image "$RESTORE_HELPER_IMAGE" \
  '{restore_image:$image,digest_pinned:true,note:"RESTORE_HELPER_IMAGE must carry an @sha256 digest; a non-digest reference is refused before any output. The Lead pins the digest in .env before approval, and .env is part of the hashed manifest."}' \
  > "$WORK/restore-image.json"
printf '%s\n' "held=$( [[ -e "$ROOT/state/e2e.lock" ]] && printf true || printf false )" > "$WORK/e2e-lock-preflight.txt"
if [[ "$mode" == --preflight ]]; then
  assert_guest_key_state
  files='{}'
  while IFS= read -r file; do
    [[ -f "$ROOT/$file" && ! -L "$ROOT/$file" ]] || fail "manifest dependency missing: $file"
    digest="$(sha256sum "$ROOT/$file" | cut -d ' ' -f1)"
    files="$(jq -c --arg file "$file" --arg digest "$digest" '.+{($file):$digest}' <<<"$files")"
  done < "$BUNDLE/bundle-files.txt"
  jq -n --argjson parameters "$params" --argjson files "$files" \
    --arg cluster_uid "$(jq -er .uid "$WORK/cluster.json")" '
    {schema_version:1, scenario_id:"CBT-EXP-08V1", status:"NOT_APPROVED",
     approved_by:null, approved_at:null, cluster_uid:$cluster_uid,
     parameters:$parameters, files:$files}' > "$WORK/approval-candidate.json"
  jq -n --arg cluster_uid "$(jq -er .uid "$WORK/cluster.json")" \
    --argjson files "$(jq 'length' <<<"$files")" \
    --arg candidate "${WORK#"$ROOT"/}/approval-candidate.json" \
    '{scenario_id:"CBT-EXP-08V1",status:"NOT_APPROVED",cluster_uid:$cluster_uid,hashed_files:$files,
      approval_candidate:$candidate,
      next:"Lead records explicit approval into approval.json (status APPROVED, approved_by, approved_at, cluster_uid, parameters, files) after inspecting approval-candidate.json"}'
  exit 0
fi
# ---- execution ---------------------------------------------------------------
# The same directory/PID lock scripts/e2e-stage.sh uses. A flock file would be
# invisible to that owner and could be removed while this attempt runs.
mkdir -p "$ROOT/state"
mkdir "$ROOT/state/e2e.lock" || fail 'another lifecycle owns the checkout lock'
lock_owned=true
printf '%s\n' "$$" > "$ROOT/state/e2e.lock/pid"
check_approval
tlog "CBT-EXP-08V1 execute start (lifecycle=$LIFECYCLE_ID vm=$VM_NAME attempt=$CHAOS_RUN_ID)"
# ---------- 1. setup ---------------------------------------------------------
stage_mark setup-start
tlog "stage setup: make vm-setup RUN_ID=$LIFECYCLE_ID"
if record setup "$SETUP_TIMEOUT" "${make_cmd[@]}" vm-setup RUN_ID="$LIFECYCLE_ID"; then setup_rc=0; else setup_rc=$?; fi
if setup_guest_public_sha256="$(guest_key_capture_after_setup "$GUEST_KEY")"; then
  setup_key_rc=0
else
  setup_key_rc=$?
  setup_guest_public_sha256=''
fi
jq -n --arg mode "$guest_key_mode" --arg approved "$guest_public_sha256" --arg post "$setup_guest_public_sha256" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson setup_rc "$setup_rc" --argjson key_rc "$setup_key_rc" \
  '{schema_version:1,approval_mode:$mode,approved_public_sha256:(if $approved=="" then null else $approved end),
    public_sha256_after_setup:(if $post=="" then null else $post end),setup_stage_rc:$setup_rc,
    key_capture_rc:$key_rc,captured_at:$at}' > "$WORK/guest-key.json" || fail 'guest key evidence write failed'
if ((setup_rc != 0)); then tlog "setup stage failed rc=$setup_rc"; exit "$setup_rc"; fi
if ((setup_key_rc != 0)); then fail 'guest key pair unavailable after setup'; fi
if [[ "$guest_key_mode" == existing-pair && "$setup_guest_public_sha256" != "$guest_public_sha256" ]]; then
  fail 'setup changed the approved guest public key'
fi
key_setup_complete=true
assert_guest_key_state
stage_mark setup-done
# ---------- 2. baseline identities, watches, inventory ----------------------
api get vm "$VM_NAME" -n "$NAMESPACE" -o json > "$WORK/vm-setup.json" || fail 'VM missing after setup'
api get vmi "$VM_NAME" -n "$NAMESPACE" -o json > "$WORK/vmi-setup.json" || fail 'VMI missing after setup'
vm_uid="$(jq -er .metadata.uid "$WORK/vm-setup.json")" || fail 'VM UID unavailable'
vmi_uid="$(jq -er .metadata.uid "$WORK/vmi-setup.json")" || fail 'VMI UID unavailable'
node="$(jq -er .status.nodeName "$WORK/vmi-setup.json")" || fail 'VMI nodeName unavailable'
jq -e '.status.phase == "Running"' "$WORK/vmi-setup.json" >/dev/null || fail 'VMI is not Running after setup'
api get node "$node" -o json > "$WORK/node.json" || fail 'cannot read the VM node'
jq -e '.status.conditions | any(.type=="Ready" and .status=="True")' "$WORK/node.json" >/dev/null || fail 'VM node is not Ready'
node_uid="$(jq -er .metadata.uid "$WORK/node.json")" || fail 'node UID unavailable'
if ! resolve_launcher "$WORK/launchers-setup.json"; then fail 'ambiguous or missing setup launcher'; fi
setup_launcher="$launcher"
jq --arg life "$LIFECYCLE_ID" --arg vm "$vm_uid" --arg vmi "$vmi_uid" --arg node "$node" \
  --arg node_uid "$node_uid" --arg launcher "$launcher" --arg launcher_uid "$launcher_uid" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {lifecycle_id:$life, vm_uid:$vm, vmi_uid:$vmi, node:$node, node_uid:$node_uid,
        launcher:$launcher, launcher_uid:$launcher_uid}' "$WORK/input.json" > "$WORK/input.updated.json"
mv -f "$WORK/input.updated.json" "$WORK/input.json"
jq -n --arg life "$LIFECYCLE_ID" --arg vm "$vm_uid" --arg vmi "$vmi_uid" --arg node "$node" \
  --arg node_uid "$node_uid" --arg launcher "$launcher" --arg launcher_uid "$launcher_uid" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{lifecycle_id:$life, vm_uid:$vm, vmi_uid:$vmi, node:$node, node_uid:$node_uid,
    launcher:$launcher, launcher_uid:$launcher_uid, captured_at:$at}' \
  > "$WORK/identities-before.json"
capture vm-before 30 "$WORK/vm-before.json" oc --request-timeout=10s get vm "$CONTROL_VM" -n "$NAMESPACE" -o json || true
if [[ -s "$WORK/vm-before.json" ]]; then
  jq '{name:.metadata.name,uid:.metadata.uid}' "$WORK/vm-before.json" > "$WORK/control-vm-before.json"
else
  printf '{"available":false}\n' > "$WORK/control-vm-before.json"
fi
inventory before
# Pre-first-full invariant: this VM has no checkpoint yet (read-only guest probe)
capture checkpoint-baseline 30 "$WORK/checkpoint-baseline.log" oc --request-timeout=10s exec -n "$NAMESPACE" \
  "$setup_launcher" -c compute -- virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --name || true
if grep -q '[^[:space:]]' "$WORK/checkpoint-baseline.log" 2>/dev/null; then
  fail 'the fresh VM already has libvirt checkpoints; refusing to inject'
fi
capture qmp-capability 30 "$WORK/qmp-capability.json" oc --request-timeout=10s exec -n "$NAMESPACE" \
  "$setup_launcher" -c compute -- virsh qemu-monitor-command "${NAMESPACE}_${VM_NAME}" '{"execute":"query-block-jobs"}' || true
jq -e '.return | type == "array"' "$WORK/qmp-capability.json" >/dev/null || fail 'read-only active-copy QMP query is unavailable'
start_watch vm "$NAMESPACE" vm name "$VM_NAME"
start_watch vmi "$NAMESPACE" vmi name "$VM_NAME"
start_watch backup "$NAMESPACE" vmbackup name "$FULL_BACKUP_NAME"
start_watch vmbackups-all "$NAMESPACE" vmbackup field "metadata.namespace=$NAMESPACE"
start_watch tracker "$NAMESPACE" vmbackuptracker name "$TRACKER_NAME"
start_watch launchers "$NAMESPACE" pods label "vm.kubevirt.io/name=$VM_NAME"
start_watch events-vm "$NAMESPACE" events field "involvedObject.name=$VM_NAME"
start_watch events-backup "$NAMESPACE" events field "involvedObject.name=$FULL_BACKUP_NAME"
start_watch events-tracker "$NAMESPACE" events field "involvedObject.name=$TRACKER_NAME"
watch_deadline=$((SECONDS+120))
for name in "${watch_names[@]}"; do
  until [[ -s "$WORK/watch-$name.ready" ]]; do
    ((SECONDS<watch_deadline)) || fail "scoped watch readiness timeout: $name"
    sleep 1
  done
done
jq -n --argjson count "${#watch_names[@]}" --argjson names "$(printf '%s\n' "${watch_names[@]}" | jq -R . | jq -sc .)" \
  '{armed:$count,watchers:$names,note:"all read-only oc get --watch streams; each writes its own readiness marker and status"}' \
  > "$WORK/watches.json"
tlog "setup complete; watches armed (${#watch_names[@]}); vm=$VM_NAME node=$node"
stage_mark baseline-armed
# ---------- 3. start the full stage in the background -----------------------
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/full.started.utc"
full_started="$(cat "$WORK/full.started.utc")"
full_limit="$(budget)"; ((full_limit<=FULL_TIMEOUT)) || full_limit="$FULL_TIMEOUT"
tlog "stage full: make vm-backup RUN_ID=$LIFECYCLE_ID (background, bound ${full_limit}s)"
setsid timeout -k 10 "$full_limit" "${make_cmd[@]}" vm-backup RUN_ID="$LIFECYCLE_ID" > "$WORK/full.log" 2>&1 < /dev/null &
full_pid=$!
# ---------- 4. active-copy window (backup copy signal + the run tracker) ----
condition_poll() {
  local poll="$1"
  local backup_json="$poll/backup.json" tracker_json="$poll/tracker.json"
  poll_status=1
  poll_detail='backup-not-read'
  if ! api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o json > "$backup_json" 2> "$poll/backup.stderr"; then
    poll_status=3; poll_detail='backup-absent'; return 0
  fi
  if jq -e -L "$BUNDLE" 'include "checks"; terminal' "$backup_json" >/dev/null; then
    poll_status=2; poll_detail='terminal-done'; return 0
  fi
  if ! jq -e -L "$BUNDLE" --arg life "$LIFECYCLE_ID" --arg tracker "$TRACKER_NAME" \
        --arg pvc "$FULL_BACKUP_PVC_NAME" --arg since "$full_started" '
        include "checks";
        progressing and (deleting|not) and run_scoped($life; $tracker; $pvc)
        and .metadata.creationTimestamp >= $since' "$backup_json" >/dev/null; then
    poll_detail='not-progressing-or-not-run-scoped'; return 0
  fi
  api get vmi "$VM_NAME" -n "$NAMESPACE" -o json > "$poll/vmi.json" || { poll_detail='vmi-unreadable'; return 0; }
  jq -e --arg uid "$vmi_uid" '.metadata.uid == $uid and .status.phase == "Running"' "$poll/vmi.json" >/dev/null ||
    { poll_detail='vmi-not-running-or-uid-changed'; return 0; }
  api get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json > "$poll/launchers.json" || { poll_detail='launchers-unreadable'; return 0; }
  local poll_launcher
  poll_launcher="$(jq -er -L "$BUNDLE" --arg vmi_uid "$vmi_uid" '
    include "checks";
    [.items[] | select(ready and owned_by("VirtualMachineInstance"; $vmi_uid))]
    | if length == 1 then .[0].metadata.name else error("ambiguous launcher") end' "$poll/launchers.json")" ||
    { poll_detail='launcher-ambiguous'; return 0; }
  launcher="$poll_launcher"
  launcher_uid="$(jq -er --arg n "$poll_launcher" '.items[] | select(.metadata.name==$n) | .metadata.uid' "$poll/launchers.json")" || { poll_detail='launcher-uid'; return 0; }
  api logs -n "$NAMESPACE" "$launcher" -c compute --timestamps --since-time="$full_started" > "$poll/compute.log" || { poll_detail='log-unreadable'; return 0; }
  # Parse the ANSI-stripped copy of the launcher log: a colored line must not
  # hide the run-scoped copy signal.
  strip_ansi "$poll/compute.log" "$poll/compute.stripped.log" || { poll_detail='log-strip-failed'; return 0; }
  if ! jq -Rsc --arg b "$FULL_BACKUP_NAME" '
      split("\n") | map(select(contains("\"backupName\":\"" + $b + "\"") and contains("\"msg\":\"Backup started\"")))
      | if length > 0 then . else error("no run-scoped copy signal") end' "$poll/compute.stripped.log" > "$poll/copy-lines.json" 2>/dev/null; then
    poll_detail='no-backup-started-line'; return 0
  fi
  qmp "$launcher" '{"execute":"query-block-jobs"}' "$poll/jobs.json" || { poll_detail='qmp-unreadable'; return 0; }
  if ! jq -e -L "$BUNDLE" 'include "checks"; active_jobs' "$poll/jobs.json" >/dev/null; then
    poll_detail='no-active-backup-job'; return 0
  fi
  # The fault target itself: the run tracker must exist, be owned by this run
  # and still hold no checkpoint - the copy has not completed yet.
  if ! api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$tracker_json" 2> "$poll/tracker.stderr"; then
    printf '{"absent":true}\n' > "$tracker_json"
    poll_detail='tracker-absent'; return 0
  fi
  if ! jq -e -L "$BUNDLE" --arg vm "$VM_NAME" '
      include "checks";
      (deleting|not) and tracker_source_vm($vm) and tracker_unset' "$tracker_json" >/dev/null; then
    poll_detail='tracker-not-run-scoped-or-already-advanced'; return 0
  fi
  api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o json > "$poll/backup-recheck.json" || { poll_detail='backup-unreadable-recheck'; return 0; }
  jq -e -L "$BUNDLE" --arg uid "$(jq -er .metadata.uid "$backup_json")" --arg life "$LIFECYCLE_ID" \
      --arg tracker "$TRACKER_NAME" --arg pvc "$FULL_BACKUP_PVC_NAME" '
      include "checks";
      .metadata.uid == $uid and (terminal|not) and (deleting|not) and run_scoped($life; $tracker; $pvc)' \
      "$poll/backup-recheck.json" >/dev/null || { poll_detail='recheck-failed'; return 0; }
  poll_status=0
  poll_detail='active-copy'
  return 0
}
condition_deadline=$((SECONDS + CONDITION_TIMEOUT))
poll_index=0
condition=false
: > "$WORK/polls.log"
while (( SECONDS < condition_deadline )); do
  poll_index=$((poll_index+1))
  poll="$WORK/polls/$poll_index"
  mkdir "$poll"
  poll_status=1; poll_detail=''
  condition_poll "$poll"
  printf '%s poll=%s status=%s detail=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$poll_index" "$poll_status" "$poll_detail" >> "$WORK/polls.log"
  if (( poll_status == 0 )); then
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    backup_uid="$(jq -er .metadata.uid "$poll/backup-recheck.json")"
    tracker_uid="$(jq -er .metadata.uid "$poll/tracker.json")"
    jq -n --arg at "$at" --arg backup_uid "$backup_uid" \
      --arg tracker_uid "$tracker_uid" \
      --arg launcher "$launcher" --arg launcher_uid "$launcher_uid" --arg node "$node" \
      --arg vmi_uid "$vmi_uid" --arg raw "polls/$poll_index" \
      --slurpfile cp "$poll/copy-lines.json" --slurpfile jobs "$poll/jobs.json" \
      --slurpfile tracker "$poll/tracker.json" '
      {at:$at, backup_uid:$backup_uid, tracker_uid:$tracker_uid, launcher:$launcher,
       launcher_uid:$launcher_uid, node:$node, vmi_uid:$vmi_uid, active_copy:true,
       copy_signal_lines:$cp[0], backup_jobs:($jobs[0].return // []),
       tracker_checkpoint:($tracker[0].status.latestCheckpoint.name // ""),
       tracker_spec:($tracker[0].spec), raw:$raw}' > "$EVIDENCE/condition.json"
    condition=true; condition_recorded=true; active_copy_signal=true; active_job_observed=true
    tlog "active copy confirmed (poll $poll_index, backup uid $backup_uid, tracker uid $tracker_uid)"
    break
  fi
  if (( poll_status == 2 )); then
    window_reason='the backup reached Done=True before the active-copy condition was confirmed'
    break
  fi
  if (( poll_status == 3 )) && ! kill -0 "$full_pid" 2>/dev/null; then
    window_reason="the full stage exited before the backup object existed (see execution/full.log)"
    break
  fi
  sleep "$CONDITION_POLL_SECONDS"
done
if [[ "$condition" != true ]]; then
  [[ -n "$window_reason" ]] || window_reason='the active-copy condition could not be confirmed inside the 600s bound'
  jq -n --arg reason "$window_reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson polls "$poll_index" --argjson stage_alive "$(kill -0 "$full_pid" 2>/dev/null && printf true || printf false)" \
    '{reason:$reason,at:$at,polls:$polls,full_stage_alive:$stage_alive,evidence:"execution/polls/ and execution/polls.log"}' \
    > "$WORK/window-miss.json"
  tlog "WINDOW MISS: $window_reason"
  if kill -0 "$full_pid" 2>/dev/null; then
    if stop_group "$full_pid" "full-join"; then full_rc=0; else full_rc=$?; fi
    full_pid=''
    jq -n --argjson rc "$full_rc" '{child_rc:$rc,forced_termination:true,reason:"window miss"}' > "$WORK/full.status.json"
  fi
  jq -n --arg reason "$window_reason" '{schema_version:1,scenario_id:"CBT-EXP-08V1",
    authored_machine_observations:true,author_grades_injection:false,independent_analyst_required:true,
    checks:{condition_recorded:false,delete_requested:false,effect_observed:false},
    window_reason:$reason,verdict:null,
    references:["execution/window-miss.json","execution/polls.log","execution/full.log"]}' \
    > "$EVIDENCE/injection-confirmation.json"
  exit 4
fi
stage_mark condition-confirmed
# The operands the post-dwell re-validation compares against come from this
# bundle's own condition.json, which stores them as backup_uid / tracker_uid.
# Read and assert them once here, before the dwell, so a schema regression fails
# loudly instead of halting the window with a silent null comparison.
condition_backup_uid="$(jq -r '.backup_uid // empty' "$EVIDENCE/condition.json" 2>/dev/null || true)"
require_uid 'condition.json backup_uid' "$condition_backup_uid"
condition_tracker_uid="$(jq -r '.tracker_uid // empty' "$EVIDENCE/condition.json" 2>/dev/null || true)"
require_uid 'condition.json tracker_uid' "$condition_tracker_uid"
# ---------- 5. mid-copy dwell and same-instant re-validation ----------------
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/mid-copy-dwell.started.utc"
tlog "mid-copy dwell ${DWELL_SECONDS}s"
sleep "$DWELL_SECONDS"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/mid-copy-dwell.ended.utc"
revalidate_deadline=$((SECONDS + REVALIDATE_TIMEOUT))
revalidated=false
revalidate_reason=''
while (( SECONDS < revalidate_deadline )); do
  if ! api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o json > "$WORK/backup-immediately-before-delete.json" 2>/dev/null; then
    revalidate_reason='the backup object is gone before the action'; break
  fi
  if jq -e -L "$BUNDLE" 'include "checks"; terminal' "$WORK/backup-immediately-before-delete.json" >/dev/null; then
    revalidate_reason='the backup reached Done=True during the dwell (copy finished)'; break
  fi
  if ! jq -e -L "$BUNDLE" --arg uid "$condition_backup_uid" \
      --arg life "$LIFECYCLE_ID" --arg tracker "$TRACKER_NAME" --arg pvc "$FULL_BACKUP_PVC_NAME" '
      include "checks"; .metadata.uid == $uid and (deleting|not) and run_scoped($life; $tracker; $pvc)' \
      "$WORK/backup-immediately-before-delete.json" >/dev/null; then
    revalidate_reason='the backup UID or ownership changed during the dwell'; break
  fi
  if ! api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$WORK/tracker-immediately-before-delete.json" 2>/dev/null; then
    printf '{"absent":true}\n' > "$WORK/tracker-immediately-before-delete.json"
    revalidate_reason='the tracker is gone before the action'; break
  fi
  if ! jq -e -L "$BUNDLE" --arg uid "$condition_tracker_uid" \
      --arg vm "$VM_NAME" '
      include "checks";
      .metadata.uid == $uid and (deleting|not) and tracker_source_vm($vm) and tracker_unset' \
      "$WORK/tracker-immediately-before-delete.json" >/dev/null; then
    revalidate_reason='the tracker UID/ownership changed or its checkpoint advanced during the dwell'; break
  fi
  revalidated=true; break
done
if [[ "$revalidated" != true ]]; then
  [[ -n "$revalidate_reason" ]] || revalidate_reason='same-instant revalidation did not succeed inside the 15s bound'
  window_reason="$revalidate_reason"
  jq -n --arg r "$revalidate_reason" '{reason:$r,detail:"post-dwell revalidation",
    evidence:"execution/backup-immediately-before-delete.json, execution/tracker-immediately-before-delete.json"}' \
    > "$WORK/window-miss.json"
  tlog "WINDOW MISS (post-dwell): $revalidate_reason"
  if kill -0 "$full_pid" 2>/dev/null; then
    if stop_group "$full_pid" "full-join"; then full_rc=0; else full_rc=$?; fi
    full_pid=''
    jq -n --argjson rc "$full_rc" '{child_rc:$rc,forced_termination:true,reason:"post-dwell window miss"}' > "$WORK/full.status.json"
  fi
  jq -n --arg reason "$revalidate_reason" '{schema_version:1,scenario_id:"CBT-EXP-08V1",
    authored_machine_observations:true,author_grades_injection:false,independent_analyst_required:true,
    checks:{condition_recorded:true,delete_requested:false,effect_observed:false,revalidated:false},
    window_reason:$reason,verdict:null,
    references:["execution/window-miss.json","condition.json","execution/backup-immediately-before-delete.json","execution/tracker-immediately-before-delete.json"]}' \
    > "$EVIDENCE/injection-confirmation.json"
  exit 4
fi
target_uid="$(jq -er .metadata.uid "$WORK/tracker-immediately-before-delete.json")"
target_resource_version="$(jq -er .metadata.resourceVersion "$WORK/tracker-immediately-before-delete.json")"
target_checkpoint="$(jq -r -L "$BUNDLE" 'include "checks"; tracker_checkpoint' "$WORK/tracker-immediately-before-delete.json")"
backup_uid_before_delete="$(jq -er .metadata.uid "$WORK/backup-immediately-before-delete.json")"
jq -n --arg uid "$target_uid" --arg rv "$target_resource_version" --arg cp "$target_checkpoint" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {tracker_uid:$uid, tracker_resource_version:$rv,
   tracker_checkpoint:(if $cp=="" then null else $cp end), observed_at:$at,
   source:"execution/tracker-immediately-before-delete.json"}' > "$WORK/tracker-before-delete.json"
capture backup-pre-delete 30 "$EVIDENCE/backup-pre-delete.yaml" oc --request-timeout=10s get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml
capture tracker-pre-delete 30 "$EVIDENCE/tracker-pre-delete.yaml" oc --request-timeout=10s get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml
capture vmi-pre-delete 30 "$WORK/vmi-pre-delete.json" oc --request-timeout=10s get vmi "$VM_NAME" -n "$NAMESPACE" -o json
capture checkpoint-pre-delete 30 "$WORK/checkpoint-pre-delete.log" oc --request-timeout=10s exec -n "$NAMESPACE" \
  "${launcher:-$setup_launcher}" -c compute -- virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --name
# ---------- 6. the one approved UID-guarded DELETE, fail-closed GET ---------
stage_mark action-start
if ! api_proxy_start; then fail 'owned oc proxy did not become ready; no action was taken'; fi
api_group='backup.kubevirt.io/v1alpha1'
inject_dir="$WORK/inject"
mkdir -p "$inject_dir" || fail 'injection evidence directory write failed'
target_path="/apis/$api_group/namespaces/$NAMESPACE/virtualmachinebackuptrackers/$TRACKER_NAME"
delete_request_epoch="$(date -u +%s)"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/delete-request.utc"
jq -n --arg at "$(cat "$WORK/delete-request.utc")" --arg method DELETE --arg path "$target_path" \
  --arg name "$TRACKER_NAME" --arg uid "$target_uid" --arg rv "$target_resource_version" \
  --arg port "$PROXY_PORT" --arg action "$BUNDLE/inject.sh" --arg group "$api_group" \
  '{at:$at,method:$method,path:$path,target_kind:"VirtualMachineBackupTracker",
    target:{name:$name,uid:$uid,resourceVersion:$rv},
    action_file:$action, api_group:$group, proxy_port:$port,
    body_file:"execution/inject/delete-options.json",
    mechanism:"uid_preconditioned_DeleteOptions_via_owned_local_oc_proxy",
    note:"the request body and the response are written by inject.sh; this record is the run.sh-owned condition/operand snapshot"}' \
  > "$WORK/delete-request.json" || fail 'delete request record write failed'
tlog "action: invoking inject.sh for one UID-preconditioned DELETE of tracker $TRACKER_NAME uid=$target_uid via the owned oc proxy"
# The action file owns the one request; this entrypoint owns the operands, the
# proxy lifetime, the fail-closed postcondition and everything after it. Its
# stdout is the action's own status report, archived verbatim.
if inject_stdout="$(NAMESPACE="$NAMESPACE" TRACKER_NAME="$TRACKER_NAME" TRACKER_UID="$target_uid" \
      API_BASE="http://127.0.0.1:$PROXY_PORT" API_GROUP="$api_group" \
      BODY_FILE="$inject_dir/delete-options.json" \
      timeout -k 5 60 bash "$BUNDLE/inject.sh" < /dev/null 2> "$inject_dir/inject.stderr")"; then
  delete_rc=0
else
  delete_rc=$?
fi
printf '%s\n' "$inject_stdout" > "$inject_dir/inject.stdout"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/delete-response.utc"
delete_requested=true
delete_transport_rc="$(printf '%s\n' "$inject_stdout" | sed -n 's/^transport_rc=//p' | tail -1)"
delete_http_code="$(printf '%s\n' "$inject_stdout" | sed -n 's/^http_status=//p' | tail -1)"
[[ -n "$delete_http_code" ]] || delete_http_code='none'
# The canonical observation used by the finalizer and the summary keeps the raw
# API status, or empty when the action never produced one.
delete_http_status="$delete_http_code"
[[ "$delete_http_status" != 'none' ]] || delete_http_status=''
# Fail-closed postcondition: the tracker must be gone (HTTP 404), polled every
# second inside the bounded window. Every response code is recorded raw.
: > "$WORK/tracker-get-codes.log"
tracker_get_index=0
tracker_get_last=''
tracker_gone_deadline=$((SECONDS + TRACKER_GONE_TIMEOUT))
while :; do
  tracker_get_index=$((tracker_get_index+1))
  if tracker_get_code="$(curl --noproxy '*' -sS --max-time 10 -o "$WORK/tracker-get-response.json" \
      -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT$target_path" 2> "$WORK/tracker-get.stderr")"; then
    tracker_get_rc=0
  else
    tracker_get_rc=$?
  fi
  tracker_get_last="$tracker_get_code"
  printf '%s get=%s rc=%s at=%s\n' "$tracker_get_index" "$tracker_get_code" "$tracker_get_rc" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/tracker-get-codes.log"
  if [[ "$tracker_get_code" == 404 ]]; then tracker_get_404=true; break; fi
  (( SECONDS < tracker_gone_deadline )) || break
  sleep "$TRACKER_GONE_POLL_SECONDS"
done
if [[ "$tracker_get_404" == true ]]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/tracker-gone.utc"
fi
proxy_stop
jq -n --argjson rc "$delete_rc" --arg code "$delete_http_code" --argjson gets "$tracker_get_index" \
  --arg last "$tracker_get_last" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg path "$target_path" \
  --arg req_utc "$(cat "$WORK/delete-request.utc")" \
  --argjson get404 "$tracker_get_404" --argjson gone_timeout "$TRACKER_GONE_TIMEOUT" '
  {transport_rc:$rc,http_status:($code|tonumber?),request_path:$path,
   request_utc:$req_utc,ended_at:$at,get_attempts:$gets,last_get_http_status:($last|tonumber?),
   tracker_get_404:$get404,tracker_gone_bound_seconds:$gone_timeout,
   expected_delete_http_status:200,
   codes:{"409":"uid precondition failed: the object changed, no mutation applied",
     "404":"the tracker was already gone before the action","403":"not permitted"},
   raw:["tracker-get-codes.log","tracker-get-response.json","inject/delete-options.json","inject/delete-options.json.response","inject/inject.stdout","inject/inject.stderr"]}' \
  > "$WORK/delete-status.json"
tlog "action response: transport_rc=$delete_rc http=$delete_http_code tracker_get_404=$tracker_get_404 ($tracker_get_index GET attempts)"
case "$delete_http_code" in
  409)
    jq -n '{case:"uid-precondition-failed",note:"the approved tracker changed between the revalidation and the request; no mutation applied by the preconditioned DELETE"}' > "$WORK/action-outcome.json"
    printf 'tracker-delete-refused-uid-precondition-409\n' > "$EVIDENCE/inject-result.txt"
    tlog "ACTION REFUSED: uid precondition failed (409)"
    jq -n '{schema_version:1,scenario_id:"CBT-EXP-08V1",authored_machine_observations:true,
      author_grades_injection:false,independent_analyst_required:true,
      checks:{condition_recorded:true,delete_http_status:409,delete_accepted:false,effect_observed:false,
        tracker_get_404:false},
      verdict:null,references:["condition.json","execution/delete-request.json","execution/inject/delete-options.json.response"]}' \
      > "$EVIDENCE/injection-confirmation.json"
    exit 2;;
  403)
    jq -n '{case:"forbidden"}' > "$WORK/action-outcome.json"
    printf 'tracker-delete-refused-forbidden-403\n' > "$EVIDENCE/inject-result.txt"
    jq -n '{schema_version:1,scenario_id:"CBT-EXP-08V1",authored_machine_observations:true,
      author_grades_injection:false,independent_analyst_required:true,
      checks:{condition_recorded:true,delete_http_status:403,delete_accepted:false,effect_observed:false,
        tracker_get_404:false},
      verdict:null,references:["condition.json","execution/delete-status.json"]}' \
      > "$EVIDENCE/injection-confirmation.json"
    fail 'the DELETE was forbidden; no injection happened';;
  404)
    jq -n '{case:"already-absent"}' > "$WORK/action-outcome.json"
    window_reason='the tracker object was already absent when the DELETE was issued'
    printf 'tracker-already-absent-before-action\n' > "$EVIDENCE/inject-result.txt"
    jq -n '{schema_version:1,scenario_id:"CBT-EXP-08V1",authored_machine_observations:true,
      author_grades_injection:false,independent_analyst_required:true,
      checks:{condition_recorded:true,delete_http_status:404,delete_accepted:false,effect_observed:false,
        tracker_get_404:false},
      verdict:null,references:["condition.json","execution/delete-status.json"]}' \
      > "$EVIDENCE/injection-confirmation.json"
    exit 4;;
  *) :;;
esac
if (( delete_rc != 0 )) || [[ "$delete_http_code" != 200 && "$delete_http_code" != 202 ]]; then
  jq -n --argjson rc "$delete_rc" --arg code "$delete_http_code" \
    '{case:"delete-not-accepted",transport_rc:$rc,http_status:($code|tonumber?)}' > "$WORK/action-outcome.json"
  printf 'tracker-delete-not-accepted-transport_rc=%s-http=%s\n' "$delete_rc" "$delete_http_code" > "$EVIDENCE/inject-result.txt"
  jq -n --argjson rc "$delete_rc" --arg code "$delete_http_code" '
    {schema_version:1,scenario_id:"CBT-EXP-08V1",authored_machine_observations:true,
     author_grades_injection:false,independent_analyst_required:true,
     checks:{condition_recorded:true,delete_accepted:false,effect_observed:false,
       delete_transport_rc:$rc,delete_http_status:($code|tonumber?),tracker_get_404:false},
     verdict:null,references:["condition.json","execution/delete-status.json","execution/inject/inject.stderr"]}' \
    > "$EVIDENCE/injection-confirmation.json"
  fail "the tracker DELETE was not accepted (transport_rc=$delete_rc http=$delete_http_code); no injection is claimed"
fi
delete_accepted=true
effect_observed="$tracker_get_404"
jq -n --argjson accepted "$delete_accepted" --argjson effect "$effect_observed" \
  --argjson get404 "$tracker_get_404" '{case:"issued",accepted:$accepted,effect_observed:$effect,tracker_get_404:$get404}' \
  > "$WORK/action-outcome.json"
{
  printf 'tracker-delete-requested-http=%s-transport_rc=%s\n' "$delete_http_code" "$delete_rc"
  printf 'tracker-get-404-verified=%s-after=%s-get-attempts\n' "$tracker_get_404" "$tracker_get_index"
  printf 'delete_request_utc=%s\n' "$(cat "$WORK/delete-request.utc")"
  if [[ "$tracker_get_404" == true ]]; then printf 'tracker_gone_utc=%s\n' "$(cat "$WORK/tracker-gone.utc")"; fi
  printf 'tracker_uid=%s\n' "$target_uid"
  printf 'get_codes:\n'
  cat "$WORK/tracker-get-codes.log"
} > "$EVIDENCE/inject-result.txt"
jq -n --arg at "$(cat "$WORK/delete-request.utc")" --arg name "$TRACKER_NAME" --arg uid "$target_uid" \
  --arg code "$delete_http_code" --argjson rc "$delete_rc" --argjson get404 "$tracker_get_404" \
  --argjson gets "$tracker_get_index" --arg last "$tracker_get_last" \
  '{at:$at,target_kind:"VirtualMachineBackupTracker",target_name:$name,target_uid:$uid,
    delete_http_status:($code|tonumber?),delete_transport_rc:$rc,
    tracker_get_404:$get404,get_attempts:$gets,last_get_http_status:($last|tonumber?),
    raw:"execution/tracker-get-codes.log"}' > "$EVIDENCE/inject-result.json"
stage_mark action-issued
if [[ "$tracker_get_404" != true ]]; then
  window_reason="the fail-closed postcondition of the approved injection was not met: the tracker GET never returned HTTP 404 inside ${TRACKER_GONE_TIMEOUT}s after the DELETE (last status $tracker_get_last)"
  tlog "INJECTION POSTCONDITION UNCONFIRMED: $window_reason"
  jq -n --arg reason "$window_reason" --arg last "$tracker_get_last" --argjson gets "$tracker_get_index" \
    --argjson rc "$delete_rc" --arg code "$delete_http_code" \
    '{reason:$reason,last_get_http_status:($last|tonumber?),get_attempts:$gets,
      delete_transport_rc:$rc,delete_http_status:($code|tonumber?),
      evidence:"execution/tracker-get-codes.log, execution/tracker-get-response.json"}' > "$WORK/window-miss.json"
  if kill -0 "$full_pid" 2>/dev/null; then
    if stop_group "$full_pid" "full-join"; then full_rc=0; else full_rc=$?; fi
    full_pid=''
    jq -n --argjson rc "$full_rc" '{child_rc:$rc,forced_termination:true,reason:"injection postcondition unconfirmed"}' > "$WORK/full.status.json"
  fi
  jq -n --arg reason "$window_reason" --argjson gets "$tracker_get_index" --argjson get404 "$tracker_get_404" '
    {schema_version:1,scenario_id:"CBT-EXP-08V1",authored_machine_observations:true,
     author_grades_injection:false,independent_analyst_required:true,
     checks:{condition_recorded:true,delete_accepted:true,effect_observed:false,
       tracker_get_404:$get404,get_attempts:$gets},
     window_reason:$reason,verdict:null,
     note:"the DELETE was accepted but the approved fail-closed tracker-absence postcondition was not observed; no recovery leg was run and no injection is claimed",
     references:["execution/window-miss.json","execution/tracker-get-codes.log","inject-result.txt"]}' \
    > "$EVIDENCE/injection-confirmation.json"
  exit 4
fi
# ---------- 7. immediate aftermath probe at +5s -----------------------------
# This probe runs before the sampling window on purpose: the immediate state of
# the guest copy and of the destination attachment is the most perishable
# evidence in this experiment.
probe_at=$((delete_request_epoch + PROBE_OFFSET_SECONDS))
now_epoch="$(date -u +%s)"
if (( now_epoch < probe_at )); then sleep "$((probe_at - now_epoch))"; fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/post-fault-probe.utc"
if ! capture_post_fault fault; then printf 'fault probe returned nonzero\n' >> "$WORK/probe-failures.log"; fi
cp -f "$WORK/vmi-after-fault.json" "$EVIDENCE/vmi-after-fault.yaml" 2>/dev/null || true
capture vmi-after-fault-yaml 30 "$EVIDENCE/vmi-after-fault.yaml" oc --request-timeout=10s get vmi "$VM_NAME" -n "$NAMESPACE" -o yaml || true
tlog "post-fault probes captured (vmi phase=$(jq -r '.phase // "unknown"' "$WORK/vmi-after-fault-summary.json" 2>/dev/null), paused=$(jq -c '.paused // "none"' "$WORK/vmi-after-fault-summary.json" 2>/dev/null))"
# ---------- 8. sample the backup and the tracker to terminal or the bound ---
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/observation.started.utc"
observation_started_epoch="$(date -u +%s)"
observation_deadline_epoch=$((delete_request_epoch + STUCK_THRESHOLD_SECONDS))
sample_index=0
terminal_epoch=''
tracker_reappear_epoch=''
while :; do
  sample_index=$((sample_index+1))
  if backup_sample "$sample_index"; then :; else
    # an absent backup object is still a state (the wedged CR may vanish once the
    # tracker is recreated); it is recorded, not treated as an error here.
    :
  fi
  tracker_sample "$sample_index" || true
  if [[ -z "$terminal_epoch" ]] &&
     jq -e -L "$BUNDLE" 'include "checks"; terminal' "$WORK/observation/backup/$(printf '%03d' "$sample_index").json" >/dev/null 2>&1; then
    terminal_epoch="$(date -u +%s)"
    terminal_observed=true
    break
  fi
  if [[ -z "$tracker_reappear_epoch" ]] &&
     jq -e '.present == true' "$WORK/observation/tracker/$(printf '%03d' "$sample_index").json" >/dev/null 2>&1; then
    tracker_reappear_epoch="$(date -u +%s)"
    tracker_controller_recreated=true
  fi
  (( $(date -u +%s) < observation_deadline_epoch )) || break
  sleep "$OBSERVATION_SAMPLE_SECONDS"
done
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/observation.ended.utc"
observation_elapsed=$(( $(date -u +%s) - observation_started_epoch ))
stuck_at_threshold="$([[ "$terminal_observed" == true ]] && printf false || printf true)"
jq -s --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson threshold "$STUCK_THRESHOLD_SECONDS" --argjson interval "$OBSERVATION_SAMPLE_SECONDS" \
  --argjson elapsed "$observation_elapsed" --argjson samples "$sample_index" \
  --argjson terminal "$terminal_observed" --argjson stuck "$stuck_at_threshold" \
  --argjson recreated "$tracker_controller_recreated" '
  {schema_version:1, samples:$samples, sample_interval_seconds:$interval,
   stuck_threshold_seconds:$threshold, elapsed_seconds:$elapsed,
   terminal_observed:$terminal, stuck_at_threshold:$stuck,
   tracker_present_in_window:$recreated,
   completed_at:$at,
   first_terminal_sample:([.[] | select(.terminal == true) | .index] | first // null),
   unreadable_samples:([.[] | select(.unreadable == true) | .index]),
   unreadable_sample_count:([.[] | select(.unreadable == true)] | length),
   last_state:([.[] | {index, present, done_status, done_reason, progressing, initializing, progress_reason, deleting, deletion_timestamp, finalizers, resource_version}] | last),
   reason_transitions:([.[] | select(.present == true) | .progress_reason] | unique),
   resource_versions:[.[] | select(.present == true) | {index, resource_version}],
   distinct_resource_versions:([.[] | select(.present == true) | .resource_version] | unique | length),
   resource_version_frozen:(([.[] | select(.present == true) | .resource_version] | unique | length) == 1),
   note:"the bound is an approved observation window, not a documented product SLA; a non-terminal backup at the bound is preserved and never repaired here. resource_version_frozen with a non-terminal backup is the cheap silent-wedge signal: identity is unchanged between samples, so no reconcile write landed.",
   raw:"execution/observation/backup/"}' \
  "$WORK"/observation/backup/*.json > "$EVIDENCE/backup-samples.json"
jq -s --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg name "$TRACKER_NAME" --arg uid "$target_uid" \
  --argjson recreated "$tracker_controller_recreated" '
  {schema_version:1, tracker:$name, tracker_uid_before_delete:$uid,
   present_in_window:$recreated, completed_at:$at,
   first_present_sample:([.[] | select(.present == true) | .index] | first // null),
   unreadable_samples:([.[] | select(.unreadable == true) | .index]),
   unreadable_sample_count:([.[] | select(.unreadable == true)] | length),
   states:([.[] | {index, at, present, uid, resource_version, checkpoint, deleting, deletion_timestamp, finalizers, source_vm_ok}]),
   distinct_resource_versions:([.[] | select(.present == true) | .resource_version] | unique | length),
   note:"a tracker present again during the window was created by the product, not by this bundle (the bundle re-applies the manifest only in the recovery leg, and records that separately)",
   raw:"execution/observation/tracker/"}' \
  "$WORK"/observation/tracker/*.json > "$EVIDENCE/tracker-samples.json"
capture backup-final 30 "$EVIDENCE/backup-final.yaml" oc --request-timeout=10s get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml || true
if api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml > "$EVIDENCE/tracker-final.yaml.tmp" 2>/dev/null; then
  mv -f "$EVIDENCE/tracker-final.yaml.tmp" "$EVIDENCE/tracker-final.yaml"
else
  rm -f "$EVIDENCE/tracker-final.yaml.tmp"
  printf 'tracker absent\n' > "$EVIDENCE/tracker-final.yaml"
fi
unreadable_backup_samples="$(jq -r '.unreadable_sample_count // 0' "$EVIDENCE/backup-samples.json" 2>/dev/null || printf 0)"
jq -n --argjson terminal "$terminal_observed" --argjson stuck "$stuck_at_threshold" \
  --argjson elapsed "$observation_elapsed" --argjson threshold "$STUCK_THRESHOLD_SECONDS" \
  --argjson unreadable "${unreadable_backup_samples:-0}" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson backup_rv_frozen "$(jq -r '.resource_version_frozen // false' "$EVIDENCE/backup-samples.json" 2>/dev/null || printf false)" \
  --argjson backup_rv_count "$(jq -r '.distinct_resource_versions // 0' "$EVIDENCE/backup-samples.json" 2>/dev/null || printf 0)" \
  --arg last_backup_rv "$(jq -r '.last_state.resource_version // ""' "$EVIDENCE/backup-samples.json" 2>/dev/null || true)" \
  --argjson tracker_rv_count "$(jq -r '.distinct_resource_versions // 0' "$EVIDENCE/tracker-samples.json" 2>/dev/null || printf 0)" \
  '{terminal_observed:$terminal,stuck_at_threshold:$stuck,observed_seconds:$elapsed,
   threshold_seconds:$threshold,unreadable_backup_samples:$unreadable,
   observation_complete:($unreadable == 0),completed_at:$at,
   resource_version:{last_backup_resource_version:(if $last_backup_rv=="" then null else $last_backup_rv end),
     backup_distinct_across_samples:$backup_rv_count,
     backup_frozen_across_samples:$backup_rv_frozen,
     tracker_distinct_across_present_samples:$tracker_rv_count,
     interpretation:"a non-terminal backup whose resourceVersion is identical in every sample means no reconcile write landed during the window (a silent wedge); a changing resourceVersion means the controller kept writing, so the mechanism evidence must come from the log/condition surfaces instead"},
   note:"a non-terminal backup at the bound is a machine observation of no terminal state; when unreadable_backup_samples is non-zero the window itself is incomplete and the classification is UNKNOWN rather than STUCK",
   evidence:["backup-final.yaml","tracker-final.yaml","backup-samples.json","tracker-samples.json"]}' \
  > "$EVIDENCE/tracker-deletion.json"
tlog "observation window complete: terminal=$terminal_observed stuck_at_threshold=$stuck_at_threshold elapsed=${observation_elapsed}s samples=$sample_index"
stage_mark observation-done
# ---------- 9. virt-controller log window (both replicas) -------------------
collect_controller_window end "$(cat "$WORK/delete-request.utc")" || true
build_controller_window_report "$delete_request_epoch" || true
# ---------- 10. settled aftermath probes, then storage/exclusions -----------
if ! capture_post_fault settled; then printf 'settled probe returned nonzero\n' >> "$WORK/probe-failures.log"; fi
if ! capture_post_fault after-observation; then printf 'after-observation probe returned nonzero\n' >> "$WORK/probe-failures.log"; fi
# Storage-layer correlation for the destination volume (read-only, API-level).
api get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o json > "$WORK/pvc-destination.json" 2>/dev/null || rm -f "$WORK/pvc-destination.json"
if [[ -s "$WORK/pvc-destination.json" ]]; then
  pv_name="$(jq -r '.spec.volumeName // ""' "$WORK/pvc-destination.json")"
  if [[ -n "$pv_name" ]]; then
    api get pv "$pv_name" -o json > "$WORK/pv-destination.json" 2>/dev/null || rm -f "$WORK/pv-destination.json"
  fi
  api get volumeattachment -o json > "$WORK/volumeattachments.json" 2>/dev/null || rm -f "$WORK/volumeattachments.json"
  jq -n --slurpfile pvc "$WORK/pvc-destination.json" \
    --arg pv_name "$pv_name" \
    --argjson pv "$( [[ -s "$WORK/pv-destination.json" ]] && cat "$WORK/pv-destination.json" || printf 'null' )" \
    --argjson va "$( [[ -s "$WORK/volumeattachments.json" ]] && cat "$WORK/volumeattachments.json" || printf '{"items":[]}' )" '
    {pvc:{name:$pvc[0].metadata.name, uid:$pvc[0].metadata.uid, phase:($pvc[0].status.phase // null),
          pvc_resource_version:$pvc[0].metadata.resourceVersion,
          storage_class:($pvc[0].spec.storageClassName // null),
          requested_storage:($pvc[0].spec.resources.requests.storage // null)},
     pv:(if $pv == null then null else {name:$pv.metadata.name, uid:$pv.metadata.uid,
          csi_volume_handle:($pv.spec.csi.volumeHandle // null), reclaim_policy:$pv.spec.persistentVolumeReclaimPolicy,
          claim_uid:($pv.spec.claimRef.uid // null)} end),
     volume_attachments:[$va.items[]? | select((.spec.source.persistentVolumeName // "") == $pv_name)
       | {name:.metadata.name, node:(.spec.nodeName // null), attached:(.status.attached // null)}],
     host_layer:{status:"UNKNOWN",
       reason:"no host-level or node-local probe is authorized in this bundle read scope; absence of an API reference is not host release",
       authorized_alternative:"a Lead-approved read-only node-local mount/device correlation would be required"}}' \
    > "$WORK/storage-identity.json"
else
  jq -n '{pvc:null,host_layer:{status:"UNKNOWN",reason:"the destination PVC could not be read"}}' > "$WORK/storage-identity.json"
fi
# Exclusion / blast-radius comparison.
inventory after
excluded="$(printf '%s\n' "$VM_NAME" "$DV_NAME" "$SSH_SERVICE" "$TRACKER_NAME" "$FULL_BACKUP_NAME" \
  "$FULL_BACKUP_PVC_NAME" "$RECOVERY_BACKUP_NAME" "$RECOVERY_PVC_NAME" \
  | jq -R . | jq -sc .)"
inventory_complete=true
for kind in vmbackup vmbackuptracker vm vmi pvc; do
  [[ -s "$WORK/inventory-before-$kind.json" && -s "$WORK/inventory-after-$kind.json" ]] || inventory_complete=false
done
blast_radius_others_unchanged=''
if [[ "$inventory_complete" == true ]]; then
  for kind in vmbackup vmbackuptracker vm vmi pvc; do
    jq -n --slurpfile b "$WORK/inventory-before-$kind.json" --slurpfile a "$WORK/inventory-after-$kind.json" \
      --argjson excl "$excluded" -L "$BUNDLE" '
      include "checks";
      ($b[0] | others($excl)) as $before | ($a[0] | others($excl)) as $after
      | {unchanged:($before == $after), before:$before, after:$after}' > "$WORK/blast-$kind.json"
  done
  others_ok=true
  for kind in vmbackup vmbackuptracker vm vmi pvc; do
    jq -e '.unchanged == true' "$WORK/blast-$kind.json" >/dev/null || others_ok=false
  done
  blast_radius_others_unchanged="$others_ok"
  jq -n --argjson complete true --argjson others "$others_ok" --argjson excl "$excluded" \
    --slurpfile va "$WORK/blast-vmbackup.json" --slurpfile tr "$WORK/blast-vmbackuptracker.json" \
    --slurpfile vm "$WORK/blast-vm.json" --slurpfile vmi "$WORK/blast-vmi.json" --slurpfile pvc "$WORK/blast-pvc.json" '
    {complete:$complete, others_unchanged:$others, excluded_names:$excl,
     per_kind:{vmbackup:$va[0], vmbackuptracker:$tr[0], vm:$vm[0], vmi:$vmi[0], pvc:$pvc[0]}}' \
    > "$WORK/blast-radius.json"
else
  blast_radius_others_unchanged=null
  jq -n '{complete:false, others_unchanged:null, reason:"one or more namespace inventories could not be captured; UNKNOWN, never inferred clean"}' \
    > "$WORK/blast-radius.json"
fi
capture vm-after-settled 30 "$WORK/vm-settled.json" oc --request-timeout=10s get vm "$CONTROL_VM" -n "$NAMESPACE" -o json || true
control_vm_unchanged=null
if [[ -s "$WORK/vm-settled.json" && -s "$WORK/control-vm-before.json" ]]; then
  before_control_uid="$(jq -r '.uid // ""' "$WORK/control-vm-before.json")"
  after_control_uid="$(jq -r '.metadata.uid // ""' "$WORK/vm-settled.json")"
  if [[ -n "$before_control_uid" && "$before_control_uid" == "$after_control_uid" ]]; then control_vm_unchanged=true; else control_vm_unchanged=false; fi
fi
jq -n --argjson unchanged "${control_vm_unchanged:-null}" --arg control "$CONTROL_VM" \
  --arg before "$(jq -r '.uid // "unavailable"' "$WORK/control-vm-before.json")" \
  --arg after "$(jq -r '.metadata.uid // "unavailable"' "$WORK/vm-settled.json" 2>/dev/null)" '
  {control_vm:$control, before_uid:(if $before=="unavailable" then null else $before end),
   after_uid:(if $after=="unavailable" then null else $after end), unchanged:$unchanged}' > "$WORK/control-vm.json"
tlog "observation complete (terminal=$terminal_observed stuck=$stuck_at_threshold, others_unchanged=${blast_radius_others_unchanged:-unknown})"
stage_mark probes-done
# ---------- 11. join the full stage (its nonzero rc is expected evidence) ---
full_rc=''
if [[ -n "$full_pid" ]]; then
  waited=0
  while kill -0 "$full_pid" 2>/dev/null && (( waited < 3 )); do sleep 1; waited=$((waited+1)); done
  forced=false
  if kill -0 "$full_pid" 2>/dev/null; then forced=true; fi
  if stop_group "$full_pid" "full-join"; then full_rc=0; else full_rc=$?; fi
  full_pid=''
  jq -n --argjson rc "$full_rc" --argjson forced "$forced" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {child_rc:$rc,forced_termination:$forced,ended_at:$at,
     expected:"nonzero is expected when the backup wedged: the stage oc wait is still waiting for Done at the stuck threshold; this rc is preserved as evidence and is not a product verdict",
     note:"a transient descendant oc wait may outlive the killed make child; it performs no mutation and exits when the wedged CR is deleted"}' \
    > "$WORK/full.status.json"
else
  if [[ -s "$WORK/full.started.utc" ]]; then
    jq -n '{child_rc:null,note:"the full stage child had already exited and was joined earlier in this invocation; see execution/full.status.json if present"}' \
      > "$WORK/full.status.json"
  fi
fi
tlog "full stage child rc=${full_rc:-already-exited}"
# ---------- 12. recovery leg ------------------------------------------------
# (a) the wedged CR: at most one UID-guarded DELETE, bounded, never forced.
stage_mark recovery-start
wedged_delete_http=''
wedged_delete_rc=''
wedged_delete_velocity_ms=''
wedged_gone=false
wedged_release_epoch=''
recovery_ready=false
readiness_started="$(date -u +%s)"
readiness_deadline=$((SECONDS + RECOVERY_READY_TIMEOUT))
vm_ready_state='False'; vmi_phase='Unknown'; cbt_state='Unknown'
while :; do
  api get vm "$VM_NAME" -n "$NAMESPACE" -o json > "$WORK/recovery-vm.json" 2>/dev/null || printf '{}' > "$WORK/recovery-vm.json"
  api get vmi "$VM_NAME" -n "$NAMESPACE" -o json > "$WORK/recovery-vmi.json" 2>/dev/null || printf '{}' > "$WORK/recovery-vmi.json"
  vm_ready_state="$(jq -r '[.status.conditions[]? | select(.type=="Ready") | .status] | last // "False"' "$WORK/recovery-vm.json")"
  vmi_phase="$(jq -r '.status.phase // "Unknown"' "$WORK/recovery-vmi.json")"
  cbt_state="$(jq -r '.status.changedBlockTracking.state // "Unknown"' "$WORK/recovery-vm.json")"
  if [[ "$vm_ready_state" == True && "$vmi_phase" == Running && "$cbt_state" == Enabled ]]; then recovery_ready=true; break; fi
  (( SECONDS < readiness_deadline )) || break
  sleep 2
done
jq -n --argjson ready "$recovery_ready" --arg vm_ready "$vm_ready_state" --arg vmi "$vmi_phase" --arg cbt "$cbt_state" \
  --argjson elapsed "$(( $(date -u +%s) - readiness_started ))" --argjson bound "$RECOVERY_READY_TIMEOUT" '
  {ready:$ready, vm_ready:$vm_ready, vmi_phase:$vmi, cbt_state:$cbt, elapsed_seconds:$elapsed,
   bound_seconds:$bound,
   note:"readiness is recorded; a not-ready VM is a product observation of the fault aftermath, not a harness retry trigger"}' \
  > "$WORK/recovery-readiness.json"
tlog "recovery readiness: ready=$recovery_ready (vm_ready=$vm_ready_state vmi=$vmi_phase cbt=$cbt_state)"
attempt_id="$RECOVERY_ATTEMPT_ID"
attempt_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
attempt_status='blocked'
attempt_blocked_reason=''
attempt_resources_pvc=false
attempt_resources_backup=false
recovery_backup_valid=false
recovery_checkpoint=''; tracker_checkpoint_after=''
if [[ "$terminal_observed" != true ]]; then
  # The wedged CR holds the one-backup-per-source guard; the recovery leg needs
  # it to go, and the scenario's own question is whether it does.
  mkdir -p "$WORK/wedged"
  if ! api_proxy_start; then
    attempt_blocked_reason='the owned oc proxy did not become ready for the wedged-CR delete'
  else
    wedged_path="/apis/backup.kubevirt.io/v1alpha1/namespaces/$NAMESPACE/virtualmachinebackups/$FULL_BACKUP_NAME"
    jq -n --arg uid "$backup_uid_before_delete" \
      '{apiVersion:"v1",kind:"DeleteOptions",gracePeriodSeconds:0,preconditions:{uid:$uid}}' \
      > "$WORK/wedged/delete-options.json"
    tlog "recovery (a): DELETE wedged backup $FULL_BACKUP_NAME uid=$backup_uid_before_delete (precondition)"
    wedged_cr_delete_requested=true
    if wedged_delete_http="$(curl --noproxy '*' -sS --max-time 30 -X DELETE -H 'Content-Type: application/json' \
        --data-binary @"$WORK/wedged/delete-options.json" -o "$WORK/wedged/delete-response.json" -w '%{http_code}' \
        "http://127.0.0.1:$PROXY_PORT$wedged_path" 2> "$WORK/wedged/delete-curl.stderr")"; then
      wedged_delete_rc=0
    else
      wedged_delete_rc=$?
    fi
    wedged_delete_epoch="$(date -u +%s)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/wedged/delete-request.utc"
    wedged_index=0
    wedged_deadline_epoch=$((wedged_delete_epoch + WEDGED_DELETE_TIMEOUT))
    while :; do
      wedged_index=$((wedged_index+1))
      prefix="$(printf '%03d' "$wedged_index")"
      if api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" --ignore-not-found -o json > "$WORK/wedged/$prefix.raw" 2>/dev/null; then
        get_rc=0
      else
        get_rc=$?
      fi
      if (( get_rc == 0 )) && [[ -s "$WORK/wedged/$prefix.raw" ]]; then
        jq -L "$BUNDLE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
          include "checks";
          {at:$at, present:true, uid:.metadata.uid, resource_version:.metadata.resourceVersion,
           deletion_timestamp:(.metadata.deletionTimestamp // null),
           finalizers:(.metadata.finalizers // []), done_status:done_status, done_reason:done_reason,
           terminal:terminal, progress_reason:progress_reason, initializing_reason:initializing_reason}' \
          "$WORK/wedged/$prefix.raw" > "$WORK/wedged/$prefix.json"
      else
        rm -f "$WORK/wedged/$prefix.raw"
        jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson rc "$get_rc" \
          '{at:$at, present:false, unreadable:($rc != 0), get_rc:$rc}' > "$WORK/wedged/$prefix.json"
        (( get_rc == 0 )) || { printf 'wedged-CR read failed (rc=%s) at %s; not treated as released\n' "$get_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/wedged/read-errors.log"; (( $(date -u +%s) < wedged_deadline_epoch )) || break; sleep "$WEDGED_DELETE_POLL_SECONDS"; continue; }
        wedged_gone=true
        wedged_release_epoch="$(date -u +%s)"
        break
      fi
      (( $(date -u +%s) < wedged_deadline_epoch )) || break
      sleep "$WEDGED_DELETE_POLL_SECONDS"
    done
    proxy_stop
    if [[ "$wedged_gone" == true ]]; then
      wedged_delete_velocity_ms=$(( (wedged_release_epoch - wedged_delete_epoch) * 1000 ))
      wedged_cr_release="gone_before_tracker_recreation"
    else
      wedged_cr_release="stuck_at_bound_without_tracker"
    fi
    jq -n --arg code "$wedged_delete_http" --argjson rc "$wedged_delete_rc" \
      --argjson gone "$wedged_gone" --argjson velocity "${wedged_delete_velocity_ms:-null}" \
      --argjson bound "$WEDGED_DELETE_TIMEOUT" --argjson samples "${wedged_index:-0}" \
      --arg release "$wedged_cr_release" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {delete_http_status:($code|tonumber?),delete_transport_rc:$rc,object_gone:$gone,
       deletion_velocity_ms:$velocity,observation_bound_seconds:$bound,samples:$samples,
       release_outcome:$release,completed_at:$at,forced:false,
       note:"the bound is an approved observation window, not a documented product SLA; a finalizer or deletionTimestamp still present at the bound is recorded and never removed or bypassed",
       raw:"execution/wedged/"}' > "$EVIDENCE/wedged-deletion.json"
    tlog "recovery (a): wedged CR http=$wedged_delete_http gone=$wedged_gone outcome=$wedged_cr_release"
    # The decisive mechanism lines often post-date the delete instant (the
    # wedged-CR delete is the next reconcile trigger), so the log window is
    # pinned to this instant too.
    collect_controller_window wedged "$(cat "$WORK/wedged/delete-request.utc")" || true
  fi
else
  jq -n '{delete_requested:false,reason:"the backup reached Done=True inside the observation window; no wedged CR existed to delete"}' \
    > "$EVIDENCE/wedged-deletion.json"
fi
# (b) the tracker must exist for the fresh backup. The product may have
# recreated it (recorded in the samples); otherwise this bundle re-applies the
# tracker manifest shape once, exactly as the scenario prescribes.
tracker_reapply_performed=false
tracker_reapply_rc=''
tracker_after_recovery_present=false
tracker_after_recovery_uid=''
tracker_after_recovery_checkpoint=''
tracker_ready=false
if api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$WORK/tracker-before-reapply.json" 2>/dev/null; then
  tracker_after_recovery_present=true
  tracker_ready=true
  tlog "recovery (b): the tracker already exists (product recreated it); no re-apply performed"
else
  tracker_json="$(jq -n --arg name "$TRACKER_NAME" --arg ns "$NAMESPACE" --arg vm "$VM_NAME" \
    --arg run "$LIFECYCLE_ID" '
    {apiVersion:"backup.kubevirt.io/v1alpha1",kind:"VirtualMachineBackupTracker",
     metadata:{name:$name,namespace:$ns,
       labels:{"app.kubernetes.io/managed-by":"virt-cbt-lab","virt-cbt-lab/run-id":$run}},
     spec:{source:{apiGroup:"kubevirt.io",kind:"VirtualMachine",name:$vm}}}')"
  if api apply -f - <<<"$tracker_json" > "$WORK/tracker-reapply.log" 2>&1; then
    tracker_reapply_rc=0
    tracker_reapply_performed=true
    tlog "recovery (b): tracker re-applied (spec.source = this run VM)"
  else
    tracker_reapply_rc=$?
  fi
  recreate_deadline=$((SECONDS + TRACKER_RECREATE_TIMEOUT))
  while (( SECONDS < recreate_deadline )); do
    if api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$WORK/tracker-after-reapply.json" 2>/dev/null &&
       jq -e -L "$BUNDLE" --arg vm "$VM_NAME" 'include "checks";
         (deleting|not) and tracker_source_vm($vm)' "$WORK/tracker-after-reapply.json" >/dev/null; then
      tracker_after_recovery_present=true; tracker_ready=true; break
    fi
    sleep 2
  done
fi
if [[ "$tracker_after_recovery_present" == true ]]; then
  api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$WORK/tracker-after-recovery.json" 2>/dev/null ||
    printf '{"absent":true}\n' > "$WORK/tracker-after-recovery.json"
  tracker_after_recovery_uid="$(jq -r '.metadata.uid // ""' "$WORK/tracker-after-recovery.json")"
  tracker_after_recovery_checkpoint="$(jq -r -L "$BUNDLE" 'include "checks"; tracker_checkpoint' "$WORK/tracker-after-recovery.json")"
fi
jq -n --argjson recreated "$tracker_controller_recreated" --argjson reapplied "$tracker_reapply_performed" \
  --argjson ready "$tracker_ready" --argjson rc "${tracker_reapply_rc:-null}" \
  --arg uid_before "$target_uid" --arg uid_after "$tracker_after_recovery_uid" \
  --arg cp_after "$tracker_after_recovery_checkpoint" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson bound "$TRACKER_RECREATE_TIMEOUT" '
  {product_recreated_during_window:$recreated, reapply_performed:$reapplied,
   reapply_transport_rc:$rc, tracker_ready_for_recovery:$ready,
   tracker_uid_before_delete:$uid_before, tracker_uid_after_recovery:(if $uid_after=="" then null else $uid_after end),
   tracker_uid_changed:(($uid_after != "") and ($uid_after != $uid_before)),
   tracker_checkpoint_after_recovery:(if $cp_after=="" then null else $cp_after end),
   recreation_bound_seconds:$bound, completed_at:$at,
   note:"the re-apply uses the tracker manifest shape of manifests/full-backup-large-odf.yaml (spec.source = the run VM) and is recorded separately from a product-created tracker",
   raw:["execution/tracker-reapply.log","execution/tracker-before-reapply.json","execution/tracker-after-recovery.json"]}' \
  > "$EVIDENCE/tracker-recreation.json"
tlog "recovery (b): tracker ready=$tracker_ready reapplied=$tracker_reapply_performed product_recreated=$tracker_controller_recreated"
# After the tracker exists again the wedged CR may be released; observed bounded.
if [[ "$wedged_cr_delete_requested" == true && "$wedged_gone" != true ]]; then
  wedged_release_deadline=$((SECONDS + WEDGED_RELEASE_AFTER_TRACKER_TIMEOUT))
  wedged_release_index=0
  while (( SECONDS < wedged_release_deadline )); do
    wedged_release_index=$((wedged_release_index+1))
    if api get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" --ignore-not-found -o json > "$WORK/wedged/release-$wedged_release_index.raw" 2>/dev/null; then
      get_rc=0
    else
      get_rc=$?
    fi
    if (( get_rc == 0 )) && [[ -s "$WORK/wedged/release-$wedged_release_index.raw" ]]; then
      jq -L "$BUNDLE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        include "checks";
        {at:$at, present:true, uid:.metadata.uid, deletion_timestamp:(.metadata.deletionTimestamp // null),
         finalizers:(.metadata.finalizers // []), done_status:done_status, done_reason:done_reason,
         terminal:terminal}' "$WORK/wedged/release-$wedged_release_index.raw" \
        > "$WORK/wedged/release-$wedged_release_index.json"
    else
      rm -f "$WORK/wedged/release-$wedged_release_index.raw"
      jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson rc "$get_rc" \
        '{at:$at, present:false, unreadable:($rc != 0), get_rc:$rc}' > "$WORK/wedged/release-$wedged_release_index.json"
      (( get_rc == 0 )) || { printf 'wedged-CR read failed (rc=%s) at %s; not treated as released\n' "$get_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/wedged/read-errors.log"; sleep "$WEDGED_DELETE_POLL_SECONDS"; continue; }
      wedged_gone=true
      wedged_cr_release="gone_after_tracker_recreation"
      break
    fi
    sleep "$WEDGED_DELETE_POLL_SECONDS"
  done
  jq --arg release "$wedged_cr_release" --argjson gone "$wedged_gone" \
    --argjson samples "$wedged_release_index" --argjson bound "$WEDGED_RELEASE_AFTER_TRACKER_TIMEOUT" \
    '. + {release_outcome_after_tracker:$release, object_gone_after_tracker:$gone,
          post_tracker_samples:$samples, post_tracker_bound_seconds:$bound}' \
    "$EVIDENCE/wedged-deletion.json" > "$WORK/wedged-deletion.updated.json"
  mv -f "$WORK/wedged-deletion.updated.json" "$EVIDENCE/wedged-deletion.json"
  tlog "recovery: wedged CR gone after tracker recreation=$wedged_gone ($wedged_cr_release)"
fi
# (c) the fresh-named backup through the tracker, with operand checks.
if [[ -z "$attempt_blocked_reason" && "$recovery_ready" != true ]]; then
  attempt_blocked_reason="the VM is not Ready/Running/CBT-Enabled after the fault (ready=$vm_ready_state vmi=$vmi_phase cbt=$cbt_state); no guessed state"
fi
if [[ -z "$attempt_blocked_reason" && "$tracker_ready" != true ]]; then
  attempt_blocked_reason='the tracker could not be made present for the recovery backup (neither the product recreated it nor the re-applied manifest became usable)'
fi
rec_storage_class=''; rec_storage_request=''; rec_access_modes='[]'; rec_volume_mode=''
if [[ -z "$attempt_blocked_reason" ]]; then
  if api get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o json > "$WORK/recovery-source-pvc.json" 2>/dev/null &&
     [[ -s "$WORK/recovery-source-pvc.json" ]]; then
    rec_storage_class="$(jq -r '.spec.storageClassName // ""' "$WORK/recovery-source-pvc.json")"
    rec_storage_request="$(jq -r '.spec.resources.requests.storage // ""' "$WORK/recovery-source-pvc.json")"
    rec_access_modes="$(jq -c '.spec.accessModes // []' "$WORK/recovery-source-pvc.json")"
    rec_volume_mode="$(jq -r '.spec.volumeMode // ""' "$WORK/recovery-source-pvc.json")"
  fi
  [[ -n "$rec_storage_class" && -n "$rec_storage_request" && "$rec_access_modes" == '["ReadWriteOnce"]' ]] ||
    attempt_blocked_reason='the destination PVC storage profile could not be resolved; refusing to guess a recovery profile'
fi
if [[ -z "$attempt_blocked_reason" ]]; then
  pvc_json="$(jq -n --arg name "$RECOVERY_PVC_NAME" --arg ns "$NAMESPACE" \
    --arg class "$rec_storage_class" --arg storage "$rec_storage_request" \
    --argjson modes "$rec_access_modes" --arg vmode "$rec_volume_mode" \
    --arg run "$LIFECYCLE_ID" '
    {apiVersion:"v1",kind:"PersistentVolumeClaim",
     metadata:{name:$name,namespace:$ns,
       labels:{"app.kubernetes.io/managed-by":"virt-cbt-lab","virt-cbt-lab/run-id":$run}},
     spec:({storageClassName:$class,accessModes:$modes,
       resources:{requests:{storage:$storage}}}
       + (if $vmode == "" then {} else {volumeMode:$vmode} end))}')"
  if api create -f - <<<"$pvc_json" > "$WORK/recovery-pvc-create.log" 2>&1; then
    attempt_resources_pvc=true
    pvc_bound=false
    pvc_deadline=$((SECONDS + RECOVERY_PVC_TIMEOUT))
    while (( SECONDS < pvc_deadline )); do
      if api get pvc "$RECOVERY_PVC_NAME" -n "$NAMESPACE" -o json > "$WORK/recovery-pvc.json" 2>/dev/null &&
         jq -e '.status.phase == "Bound"' "$WORK/recovery-pvc.json" >/dev/null 2>&1; then pvc_bound=true; break; fi
      sleep 2
    done
    if [[ "$pvc_bound" != true ]]; then
      attempt_blocked_reason="the recovery PVC did not become Bound inside ${RECOVERY_PVC_TIMEOUT}s; it is preserved for diagnosis"
    fi
  else
    attempt_blocked_reason="the recovery PVC could not be created; see execution/recovery-pvc-create.log"
  fi
fi
if [[ -z "$attempt_blocked_reason" ]]; then
  backup_json="$(jq -n --arg name "$RECOVERY_BACKUP_NAME" --arg ns "$NAMESPACE" \
    --arg tracker "$TRACKER_NAME" --arg pvc "$RECOVERY_PVC_NAME" --arg run "$LIFECYCLE_ID" '
    {apiVersion:"backup.kubevirt.io/v1alpha1",kind:"VirtualMachineBackup",
     metadata:{name:$name,namespace:$ns,
       labels:{"app.kubernetes.io/managed-by":"virt-cbt-lab","virt-cbt-lab/run-id":$run}},
     spec:{source:{apiGroup:"backup.kubevirt.io",kind:"VirtualMachineBackupTracker",name:$tracker},
       pvcName:$pvc,forceFullBackup:true}}')"
  if api create -f - <<<"$backup_json" > "$WORK/recovery-backup-create.log" 2>&1; then
    attempt_resources_backup=true
    tlog "recovery (c): backup $RECOVERY_BACKUP_NAME created (forceFullBackup) through $TRACKER_NAME"
    recovery_done=false
    states=0; last_sig=''
    backup_deadline=$((SECONDS + RECOVERY_BACKUP_TIMEOUT))
    while (( SECONDS < backup_deadline )); do
      if api get vmbackup "$RECOVERY_BACKUP_NAME" -n "$NAMESPACE" -o json > "$WORK/recovery-backup.json" 2>/dev/null; then
        sig="$(jq -r '[( [.status.conditions[]? | select(.type=="Done") | (.status + ":" + (.reason // ""))] | last // "pending"), (.status.type // ""), (.status.checkpointName // "")] | join("|")' "$WORK/recovery-backup.json")"
        if [[ "$sig" != "$last_sig" ]]; then
          states=$((states+1))
          cp -f "$WORK/recovery-backup.json" "$WORK/recovery-state-$states.json" 2>/dev/null || true
          last_sig="$sig"
        fi
        if jq -e -L "$BUNDLE" 'include "checks"; terminal' "$WORK/recovery-backup.json" >/dev/null 2>&1; then recovery_done=true; break; fi
      fi
      sleep 2
    done
    if [[ "$recovery_done" != true ]]; then
      attempt_blocked_reason="the recovery backup did not reach Done inside ${RECOVERY_BACKUP_TIMEOUT}s; it is preserved and not retried"
    fi
  else
    attempt_blocked_reason="the recovery backup could not be created (a rejection such as spec.source: in progress for source is itself the product observation); see execution/recovery-backup-create.log"
  fi
fi
if [[ -z "$attempt_blocked_reason" ]]; then
  recovery_type="$(jq -r '.status.type // "Unknown"' "$WORK/recovery-backup.json")"
  recovery_done_status="$(jq -r -L "$BUNDLE" 'include "checks"; done_status' "$WORK/recovery-backup.json")"
  recovery_reason="$(jq -r -L "$BUNDLE" 'include "checks"; done_reason' "$WORK/recovery-backup.json")"
  recovery_checkpoint="$(jq -r '.status.checkpointName // ""' "$WORK/recovery-backup.json")"
  recovery_pvc_name="$(jq -r '.spec.pvcName // ""' "$WORK/recovery-backup.json")"
  force_full="$(jq -r '.spec.forceFullBackup // false' "$WORK/recovery-backup.json")"
  actual_volumes="$(jq -c '[.status.includedVolumes[]? | {diskTarget, volumeName}] | sort_by(.diskTarget, .volumeName)' "$WORK/recovery-backup.json")"
  expected_disks="$(api get vm "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -c '[.spec.template.spec.domain.devices.disks[]?.name] | sort')"
  printf '%s\n' "$expected_disks" > "$WORK/recovery-expected-disks.json"
  volumes_known=true
  for vm_disk in $(jq -r '.[].volumeName' <<<"$actual_volumes"); do
    jq -e --arg d "$vm_disk" 'index($d) != null' <<<"$expected_disks" >/dev/null || volumes_known=false
  done
  api get pvc "$RECOVERY_PVC_NAME" -n "$NAMESPACE" -o json > "$WORK/recovery-pvc-final.json" 2>/dev/null || printf '{}' > "$WORK/recovery-pvc-final.json"
  recovery_pvc_phase="$(jq -r '.status.phase // "Unknown"' "$WORK/recovery-pvc-final.json")"
  tracker_deadline=$((SECONDS + TRACKER_ADVANCE_TIMEOUT))
  while (( SECONDS < tracker_deadline )); do
    if api get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json > "$WORK/tracker-after-recovery.json" 2>/dev/null; then
      tracker_checkpoint_after="$(jq -r -L "$BUNDLE" 'include "checks"; tracker_checkpoint' "$WORK/tracker-after-recovery.json")"
      [[ -n "$recovery_checkpoint" && "$tracker_checkpoint_after" == "$recovery_checkpoint" ]] && break
    fi
    sleep 2
  done
  checks='[]'
  add_check() { checks="$(jq -c --arg n "$1" --argjson p "$2" --arg a "$3" '. + [{name:$n,passed:$p,actual:$a}]' <<<"$checks")"; }
  [[ "$recovery_type" == Full ]] && v=true || v=false; add_check "recovery_backup_is_full" "$v" "$recovery_type"
  { [[ "$recovery_done_status" == True ]] && ! backup_done_reason_is_failure "$recovery_reason"; } && v=true || v=false
  add_check "recovery_backup_succeeded" "$v" "${recovery_done_status}:${recovery_reason:-missing}"
  [[ -n "$recovery_reason" ]] && v=true || v=false; add_check "recovery_reason_nonempty" "$v" "${recovery_reason:-missing}"
  [[ "$force_full" == true ]] && v=true || v=false; add_check "recovery_force_full_backup" "$v" "$force_full"
  [[ "$recovery_pvc_name" == "$RECOVERY_PVC_NAME" ]] && v=true || v=false; add_check "recovery_backup_uses_new_pvc" "$v" "$recovery_pvc_name"
  [[ "$recovery_pvc_phase" == Bound ]] && v=true || v=false; add_check "recovery_pvc_bound" "$v" "$recovery_pvc_phase"
  [[ -n "$recovery_checkpoint" ]] && v=true || v=false; add_check "recovery_checkpoint_present" "$v" "${recovery_checkpoint:-missing}"
  [[ "$(jq 'length' <<<"$actual_volumes")" -gt 0 ]] && v=true || v=false; add_check "included_volumes_nonempty" "$v" "$actual_volumes"
  add_check "included_volumes_known_disks" "$volumes_known" "disks=$expected_disks volumes=$actual_volumes"
  { [[ "$tracker_after_recovery_present" == true ]] && [[ -z "$tracker_after_recovery_uid" || "$tracker_after_recovery_uid" != "$target_uid" ]] && v=true || v=false; }
  add_check "tracker_recreated_with_new_identity" "$v" "before=$target_uid after=${tracker_after_recovery_uid:-missing}"
  [[ -n "$recovery_checkpoint" && "$tracker_checkpoint_after" == "$recovery_checkpoint" ]] && v=true || v=false
  add_check "tracker_advanced_to_recovery_checkpoint" "$v" "${tracker_checkpoint_after:-empty}"
  printf '%s\n' "$checks" > "$WORK/recovery-operand-checks.json"
  if jq -e 'all(.[]; .passed == true) and length > 0' <<<"$checks" >/dev/null; then
    recovery_backup_valid=true
    attempt_status='backup_verified'
  else
    attempt_status='failed'
  fi
else
  printf '[]\n' > "$WORK/recovery-operand-checks.json"
fi
cp -f "$WORK/recovery-operand-checks.json" "$EVIDENCE/recovery-operand-checks.json" 2>/dev/null || true
if [[ -s "$WORK/recovery-backup.json" ]]; then
  cp -f "$WORK/recovery-backup.json" "$EVIDENCE/recovery-backup.yaml" 2>/dev/null || true
fi
# The attempt record is a superset of the fields write-run-summary.sh reads; it
# is written atomically through vm_info_update.
recovery_full_json='null'
if [[ -s "$WORK/recovery-backup.json" ]]; then
  recovery_full_json="$(jq -c --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson passed "$recovery_backup_valid" \
    --arg tracker "$tracker_checkpoint_after" '
    {name:.metadata.name, type:(.status.type // null), done_status:([.status.conditions[]? | select(.type=="Done") | .status] | last // null),
     done_reason:([.status.conditions[]? | select(.type=="Done") | .reason] | last // null),
     checkpoint_name:(.status.checkpointName // null), pvc_name:(.spec.pvcName // null),
     pvc_phase:(.status.phase // null), included_volumes:(.status.includedVolumes // []),
     force_full_backup:(.spec.forceFullBackup // null), tracker_checkpoint_after:$tracker,
     verification_passed:$passed, completed_at:$completed}' "$WORK/recovery-backup.json")"
fi
attempt_json="$(jq -n --arg id "$attempt_id" --arg status "$attempt_status" \
  --arg started "$attempt_started" --arg blocked "$attempt_blocked_reason" \
  --argjson resources_pvc "$attempt_resources_pvc" --argjson resources_backup "$attempt_resources_backup" \
  --argjson preconditions "$( [[ -s "$WORK/recovery-operand-checks.json" ]] && cat "$WORK/recovery-operand-checks.json" || printf '[]' )" \
  --arg vm "$VM_NAME" --arg vm_uid "$vm_uid" --arg saved "$vm_uid" \
  --arg vm_ready "$vm_ready_state" --arg vmi_phase "$vmi_phase" --arg cbt "$cbt_state" \
  --arg deleted_name "$FULL_BACKUP_NAME" --arg deleted_uid "$backup_uid_before_delete" \
  --arg tracker_uid_before "$target_uid" \
  --arg pvc_name "$FULL_BACKUP_PVC_NAME" \
  --arg pvc_phase_original "$(jq -r '.status.phase // "Unknown"' "$WORK/pvc-destination.json" 2>/dev/null || printf 'Unknown')" \
  --arg tracker "$TRACKER_NAME" --arg tracker_after "$tracker_checkpoint_after" \
  --arg tracker_uid_after "$tracker_after_recovery_uid" \
  --arg rec_backup "$RECOVERY_BACKUP_NAME" --arg rec_pvc "$RECOVERY_PVC_NAME" \
  --arg class "$rec_storage_class" --arg storage "$rec_storage_request" --argjson modes "$rec_access_modes" \
  --arg vmode "$rec_volume_mode" \
  --arg del_req "$(cat "$WORK/delete-request.utc" 2>/dev/null || printf '')" \
  --argjson stuck "$stuck_at_threshold" --argjson terminal "$terminal_observed" \
  --arg wedged_http "$wedged_delete_http" --argjson wedged_gone "$wedged_gone" \
  --arg wedged_release "$wedged_cr_release" \
  --argjson recovery_full "$recovery_full_json" '
  {id:$id, status:$status, started_at:$started,
   resources_applied:{pvc:$resources_pvc, backup:$resources_backup},
   blocked_reasons:(if $blocked == "" then [] else [$blocked] end),
   preconditions:$preconditions,
   vm:{name:$vm, uid:$vm_uid, saved_uid:$saved, ready:$vm_ready, vmi_phase:$vmi_phase, cbt_state:$cbt},
   fault:{target_kind:"VirtualMachineBackupTracker", tracker_name:$tracker,
     tracker_uid_before_delete:$tracker_uid_before,
     tracker_uid_after_recovery:(if $tracker_uid_after=="" then null else $tracker_uid_after end),
     backup_terminal_inside_window:$terminal, backup_stuck_at_threshold:$stuck},
   failed_full:{name:$deleted_name, uid:$deleted_uid, state:(if $terminal then "terminal_in_window" else "wedged_no_terminal_state" end),
     done_status:null, done_reason:null, checkpoint_name:null,
     pvc_name:$pvc_name, pvc_phase:$pvc_phase_original,
     deletion_request_utc:(if $del_req=="" then null else $del_req end),
     wedged_delete_http_status:(if $wedged_http=="" then null else ($wedged_http|tonumber?) end),
     wedged_object_gone:$wedged_gone, release_outcome:$wedged_release},
   tracker:{name:$tracker, checkpoint_before:null, checkpoint_after:$tracker_after},
   proposed_resources:{backup_name:$rec_backup, pvc_name:$rec_pvc, storage_class:$class,
     storage_request:$storage, access_modes:$modes, volume_mode:$vmode},
   recovery_full:$recovery_full,
   api_contract:{api_version:"backup.kubevirt.io/v1alpha1", source_kind:"VirtualMachineBackupTracker",
     source_name:$tracker, force_full_backup:true}}')" || fail 'could not build the recovery attempt record'
if [[ -r "$VM_INFO_PATH" ]]; then
  vm_info_update '(.recovery.attempts // []) as $items |
    .recovery.attempts = (if any($items[]?; .id == $attempt.id)
      then [$items[] | if .id == $attempt.id then $attempt else . end]
      else $items + [$attempt] end) |
    .recovery.status = $attempt.status' --argjson attempt "$attempt_json" ||
    fail 'could not record the recovery attempt in run.json'
else
  fail "lifecycle run metadata is missing: ${VM_INFO_PATH#"$ROOT"/}"
fi
printf '%s\n' "$attempt_json" > "$WORK/attempt-record.json"
jq -n --arg status "$attempt_status" --arg blocked "$attempt_blocked_reason" \
  '{recorded_status:$status, blocked_reason:(if $blocked=="" then null else $blocked end),
    run_json:"runs/<lifecycle>/run.json .recovery.attempts[] id r001",
    operator_note:"if a fresh backup was rejected with spec.source: in progress for source, that is a product observation: the wedged CR still held the one-backup-per-source guard",
    raw:(["execution/recovery-operand-checks.json","execution/recovery-backup.json","execution/recovery-readiness.json",
      "execution/wedged-deletion.json","execution/tracker-recreation.json"]
      + (if $blocked=="" then [] else ["execution/recovery-pvc-create.log","execution/recovery-backup-create.log"] end))}' \
  > "$WORK/recovery-summary.json"
tlog "recovery attempt r001 status=$attempt_status"
capture_post_fault recovery
stage_mark recovery-done
# Third pinned controller pull: the recovery window (from the recovery leg start,
# which is never later than the wedged-CR delete) also covers the lines the
# controller writes when the wedge releases. The report is rebuilt so it carries
# every phase collected so far.
recovery_window_since="$(cat "$WORK/stage-recovery-start.utc" 2>/dev/null || cat "$WORK/delete-request.utc")"
collect_controller_window recovery-done "$recovery_window_since" || true
build_controller_window_report "$delete_request_epoch" || true
# ---------- 13. run summary (read-only) -------------------------------------
if record run-summary "$SUMMARY_TIMEOUT" "${make_cmd[@]}" run-summary RUN_ID="$LIFECYCLE_ID"; then
  summary_rc=0
else
  summary_rc=$?
fi
tlog "run-summary rc=$summary_rc"
# ---------- 14. close watchers, then publish machine observations -----------
for ((watch_index=0; watch_index<${#watch_pids[@]}; watch_index++)); do
  stop_watch "$watch_index"
done
tracker_deleted_event=false
if jq -se --arg uid "$target_uid" 'any(.[]; .type == "DELETED" and .object.metadata.uid == $uid)' \
    "$WORK/watch-tracker.jsonl" >/dev/null 2>&1; then tracker_deleted_event=true; fi
excluded_deletions='[]'
if [[ -s "$WORK/watch-vmbackups-all.jsonl" ]]; then
  excluded_deletions="$(jq -sc --arg uid "$backup_uid_before_delete" --argjson excl "$excluded" '
    [.[] | select(.type == "DELETED") | select(.object.metadata.uid != $uid)
     | select((.object.metadata.name as $n | $excl | index($n)) == null)
     | {name:.object.metadata.name, uid:.object.metadata.uid,
        run:(.object.metadata.labels["virt-cbt-lab/run-id"] // null)}]' "$WORK/watch-vmbackups-all.jsonl" 2>/dev/null || printf '[]')"
fi
jq --argjson deleted "$tracker_deleted_event" --argjson excluded_deletions "$excluded_deletions" \
  '. + {watch_deleted_event_for_tracker_uid:$deleted, excluded_vmbackup_deletions:$excluded_deletions}' \
  "$WORK/blast-radius.json" > "$WORK/blast-radius.updated.json"
mv -f "$WORK/blast-radius.updated.json" "$WORK/blast-radius.json"
recovery_attempt_status="$(jq -r --arg id "$RECOVERY_ATTEMPT_ID" \
  '[.recovery.attempts[]? | select(.id == $id) | .status] | last // empty' "$VM_INFO_PATH" 2>/dev/null || true)"
[[ -n "$recovery_attempt_status" ]] || recovery_attempt_status="$attempt_status"
injection_proven=false
if [[ "$condition_recorded" == true && "$delete_accepted" == true && "$tracker_get_404" == true ]]; then injection_proven=true; fi
recovery_terminal=false
[[ "$recovery_attempt_status" == backup_verified ]] && recovery_terminal=true
jq -n --argjson condition "$condition_recorded" --argjson copy_signal "$active_copy_signal" \
  --argjson active_job "$active_job_observed" --argjson requested "$delete_requested" \
  --argjson accepted "$delete_accepted" --argjson get404 "$tracker_get_404" \
  --argjson effect "$effect_observed" --argjson uid_guard true --arg uid "$target_uid" \
  --arg transport "$delete_transport_rc" --arg http "$delete_http_status" \
  --argjson terminal "$terminal_observed" --argjson stuck "$stuck_at_threshold" \
  --argjson recreated "$tracker_controller_recreated" --argjson watch_deleted "$tracker_deleted_event" \
  --argjson wedged_requested "$wedged_cr_delete_requested" --argjson wedged_gone "$wedged_gone" \
  --arg wedged_release "$wedged_cr_release" \
  --argjson others "${blast_radius_others_unchanged:-null}" --argjson control "${control_vm_unchanged:-null}" \
  --arg recovery_status "$recovery_attempt_status" \
  --argjson proven "$injection_proven" --argjson recovery_terminal "$recovery_terminal" '
  {schema_version:1, scenario_id:"CBT-EXP-08V1",
   authored_machine_observations:true, author_grades_injection:false, independent_analyst_required:true,
   fault_action:{mechanism:"uid_preconditioned_DeleteOptions_via_owned_local_oc_proxy",
     action_file:"inject.sh",
     target_kind:"VirtualMachineBackupTracker", target_name:("<lifecycle tracker>"), target_uid:$uid,
     uses_krkn:false, native_trigger_used:false,
     krkn_metadata:"execution/krkn-metadata.json"},
   checks:{condition_recorded:$condition, copy_signal_line_saved:$copy_signal,
     active_copy_job_observed:$active_job, delete_requested:$requested,
     uid_precondition_used:$uid_guard, delete_http_status:($http|tonumber?),
     delete_transport_rc:(if $transport=="" then null else ($transport|tonumber?) end),
     delete_accepted:$accepted, tracker_get_404:$get404, effect_observed:$effect,
     backup_terminal_inside_window:$terminal, backup_stuck_at_threshold:$stuck,
     tracker_recreated_by_product_in_window:$recreated,
     tracker_deletion_watch_event_for_target_uid:$watch_deleted,
     wedged_cr_delete_requested:$wedged_requested, wedged_cr_gone:$wedged_gone,
     wedged_cr_release_outcome:$wedged_release,
     blast_radius_others_unchanged:$others, control_vm_unchanged:$control,
     recovery_attempt_status:$recovery_status,
     controller_window:"controller-window.json",
     controller_window_pins:"controller-window.json .phases (end, wedged, recovery-done)"},
   orchestration:{injection_proven:$proven, recovery_leg_terminal:$recovery_terminal,
     note:"injection_proven and recovery_leg_terminal are orchestration facts about this attempt; they are never a product verdict, and STUCK/COMPLETED is the independent Analyst call"},
   artifact_references:["trigger.log","condition.json","inject-result.txt","inject-result.json",
     "execution/inject/delete-options.json","execution/inject/delete-options.json.response",
     "execution/inject/inject.stdout","execution/inject/inject.stderr",
     "backup-pre-delete.yaml","tracker-pre-delete.yaml","backup-samples.json","tracker-samples.json",
     "tracker-deletion.json","backup-final.yaml","tracker-final.yaml","controller-window.log",
     "controller-window.json","wedged-deletion.json","tracker-recreation.json"],
   analyst_inputs:["runs/<lifecycle>/run.json .recovery.attempts[] (r001)",
     "execution/observation/backup/","execution/observation/tracker/","execution/wedged/",
     "execution/controller-raw/","execution/controller-pull-<phase>.json","execution/watch-*.jsonl",
     "execution/blast-radius.json","execution/storage-identity.json",
     "execution/recovery-operand-checks.json","execution/proxy-probe.json"],
   verdict:null}' > "$EVIDENCE/injection-confirmation.json"
jq -n --argjson proven "$injection_proven" --argjson recovery_terminal "$recovery_terminal" \
  --arg recovery_status "$recovery_attempt_status" --argjson terminal "$terminal_observed" \
  --argjson stuck "$stuck_at_threshold" --arg evidence "${EVIDENCE#"$ROOT"/}" '
  {scenario_id:"CBT-EXP-08V1", injection_proven:$proven, recovery_leg_terminal:$recovery_terminal,
   recovery_attempt_status:$recovery_status, backup_terminal_inside_window:$terminal,
   backup_stuck_at_threshold:$stuck, evidence_root:$evidence, product_verdict:null}' > "$WORK/execution-summary.json"
tlog "execute end: injection_proven=$injection_proven recovery_terminal=$recovery_terminal status=$recovery_attempt_status"
sleep 0.2
# Orchestration exit status only; the Analyst owns every product verdict.
if [[ "$injection_proven" == true && "$recovery_terminal" == true ]]; then exit 0; fi
exit 1
