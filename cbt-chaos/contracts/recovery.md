# Task Contract: Recovery Worker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-recovery-worker`. One job: run the lead-authorized
post-chaos same-VM recovery backup and restore checks, preserving evidence.
Every mutating action below is pre-authorized by this contract; anything else
requires a new Lead authorization.

## Run identity
- Scenario: CBT-F-04; RUN_ID: `__RUN_ID__`; VM `vm-__RUN_ID__`
- Full backup: `vm-backup-__RUN_ID__`; tracker `vm-tracker-__RUN_ID__`
- Namespace: `vm-cbt-demo`; Host: `__HOST__`; checkout `__REMOTE_DIR__`
- Prerequisite: `observer/PRESERVED` exists (Lead has accepted it) before you start.

## Paths you may read
- This contract.
- The scenario spec `__SCENARIO_DIR__/scenario-spec.md` and jira issue.
- The run's `observer/` payload files (ARMED, PRESERVED, FINAL markers + JSON).
- The run's `trigger/` outputs (logs, exit statuses).
- Read-only cluster state via the host-local kubeconfig from `__REMOTE_DIR__/.env`.

## Files you own (sole writer)
Everything under the run root's `recovery/` directory.

## Authorized actions (exhaustive)
None beyond running the supported workflow stages below. In this scenario the
same-VM recovery is performed by the trigger script itself:
`make e2e TYPE=incremental VM=vm-__RUN_ID__` runs after the full
stage inside the trigger. Your job is to VERIFY and EVIDENCE recovery, and to
run the follow-up stage only if the trigger already terminated before running it
(i.e., the trigger exited non-zero after the full stage but the full backup
succeeded and PRESERVED evidence exists).

1. Verify VM/VMI Running, launcher Ready, `.status.changedBlockTracking.state=Enabled`.
2. Verify tracker `latestCheckpoint.name` equals the full backup's checkpoint
   (exactly one advancement); record tracker YAML before the incremental stage.
3. If (and only if) the trigger did not run it: from `__REMOTE_DIR__` run
   `make e2e TYPE=incremental VM=vm-__RUN_ID__` with the host-local
   kubeconfig env; tee the log to `recovery/incremental-followup.log`; preserve
   its exit status.
4. Verify the incremental backup: new distinct backup object name, `Done=True`
   with non-failure reason, `status.type=Incremental`, distinct child checkpoint,
   tracker advanced exactly once more, destination PVC Bound.
5. Verify restore/data correctness per the workflow's own verification output
   (restore + hash/marker checks in the stage log and `runs/<NAME>/report.json`
   for the run's lifecycle NAME `__RUN_ID__`): baseline file count,
   payload bytes, canonical manifest hash match.
6. Snapshot into `recovery/`: post-recovery tracker YAML, incremental backup
   YAML, `virsh checkpoint-list --tree` via the recovered launcher compute
   container (if accessible), and a JSON copy of `runs/__RUN_ID__/summary.json`.
7. Emit `recovery/done.json`: `{"utc": "...", "vm_ready": bool, "cbt_enabled":
   bool, "incremental_run_by": "trigger"|"recovery-worker", "incremental_ok":
   bool|null, "restore_ok": bool|null, "exit_statuses": {...}, "evidence": [paths]}`.

## Never
- Delete or mutate the original failed/preserved backup objects, PVCs, tracker,
  or any run-scoped resource.
- Create a fresh VM as a substitute for the same-VM check.
- Retry a failed backup by reusing its object/PVC name.
- Read other runs' artifacts or the learnings file; edit state/ledger/contracts.
