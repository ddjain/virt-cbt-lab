# Task Contract: Trigger Worker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-trigger-worker`. One job: execute the verified trigger
on __HOST__ and preserve exact exit statuses. You do not decide, grade, or edit.

## Run identity
- Scenario: CBT-F-04; RUN_ID: `__RUN_ID__` (lifecycle NAME identical)
- Host: `__HOST__`; remote checkout `__REMOTE_DIR__` (git 9adb186)
- Trigger (validated, sha256 recorded in preflight): `__SCENARIO_DIR__/chaos-trigger.sh`
- Workflow: `make e2e TYPE=full NAME=__RUN_ID__` with the trigger's
  documented env, then (script-internal) same-VM `TYPE=incremental` follow-up.

## Paths you may read
- This contract.
- The trigger script `__SCENARIO_DIR__/chaos-trigger.sh` (read-only).
- Your own outputs under the run root's `trigger/` directory.

## Files you own (sole writer)
Under `__REMOTE_DIR__/__SCENARIO_DIR__/runs/__RUN_ID__/trigger/`:
`command.txt`, `trigger.log`, `action-request.json`, `exit-statuses.json`.

## Execution
1. Before starting, verify the Lead's ARMED acceptance: `observer/ARMED` exists
   in the run root and the watch PIDs in `observer/watches/pids.json` are alive
   (`kill -0`). If ARMED is absent or watches are dead, DO NOT start; report back.
2. Run exactly (from `__REMOTE_DIR__`, via `ssh __HOST__`):
   CRITICAL (clean-environment launch, per spec S1 and skill rule 4a): set
   ONLY `RUN_ID` and `KUBECONFIG_PATH` in the trigger's environment. Do NOT
   source `__REMOTE_DIR__/.env` wholesale — extract the kubeconfig path
   by parsing (`KUBECONFIG_PATH="$(grep -E '^KUBECONFIG_PATH=' __REMOTE_DIR__/.env | cut -d= -f2-)"`)
   and assert no `GUEST_*` variable is set before launching. The hardened
   trigger aborts with exit 3 before any mutation if the environment leaks
   workload values; if that happens, report it as `harness-trigger` — do not
   strip variables and relaunch without the Lead.
   `cd __REMOTE_DIR__ && RUN_ID=__RUN_ID__ KUBECONFIG_PATH=<host-local kubeconfig from .env> bash __SCENARIO_DIR__/chaos-trigger.sh 2>&1 | tee __SCENARIO_DIR__/runs/__RUN_ID__/trigger/trigger.log`
   Record the exact command line in `command.txt` (with the kubeconfig path
   REDACTED to `<kubeconfig>`).
3. The trigger itself gates the Krkn deletion on the launcher `Backup started`
   signal and Lease-holder verification. Capture the moment the script prints
   its action lines (`Active-copy signal:`, `Deleting current controller leader
   through Krkn: <leader>`) into `action-request.json`:
   `{"utc_action_request": "...", "leader": "...", "backup": "vm-backup-__RUN_ID__", "vm": "vm-__RUN_ID__", "signal_line": "..."}`.
   Derive the UTC time from the log's own timestamps where present.
4. Handshake with the observer before any destructive step. Publish the resolved
   target to `trigger/surgery-target.json` (`{utc, checkpoint, disk, qemu_node}`)
   the moment it is resolved and before the mutation, then block (bounded, then
   abort) until `observer/effect/PRE-READY` exists and the artifact it names
   contains the target value; reject a witness older than 60 s and fail closed
   (exit 7) otherwise. A run whose pre-state only the injector saw is a REJECT
   for the injection checker (runs 20261016-exp06-r02), so aborting is cheaper
   than grading it.
5. Preserve exit statuses separately: workflow exit (make e2e full), observer
   exit, follow-up incremental exit, and overall trigger exit in
   `exit-statuses.json`. Do not flatten them into one status.
6. Do not leave background processes running after the script exits.

## Never
- Edit the trigger, spec, Makefile, or any state/contract file.
- Inject chaos manually or re-run Krkn yourself.
- Read observer watches' contents beyond PID liveness, other runs' artifacts,
  or the learnings file.
- Run `make clean-all` or any cleanup.
