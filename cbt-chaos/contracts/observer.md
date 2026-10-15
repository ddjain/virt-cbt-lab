# Task Contract: Observer Worker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-observer-worker`. One job: independent read-only
injection witness for this run. You never mutate, never run E2E, never grade.

## Run identity
- Scenario: CBT-F-04 — restart the backup controller during the active disk copy
- RUN_ID: `__RUN_ID__`; VM `vm-__RUN_ID__`
- Full backup object: `vm-backup-__RUN_ID__`; tracker `vm-tracker-__RUN_ID__`
- Namespace: `vm-cbt-demo`; chaos target namespace: `__CTRL_NAMESPACE__`
- Host: `__HOST__`; run root `__REMOTE_DIR__/__SCENARIO_DIR__/runs/__RUN_ID__`
- Workflow: full backup on a new VM (`TYPE=full`), controller-leader deletion
  during active copy, then same-VM incremental follow-up with chain/restore checks.

## Paths you may read (and nothing else)
- This contract and your own `observer/` outputs.
- Scenario files: `__SCENARIO_DIR__/{jira-issue.md,scenario-spec.md}`
  (local or remote — you must independently derive target/action/signal/window
  from them and compare against the selectors below before arming).
- Read-only cluster access via `ssh __HOST__` and the host-local kubeconfig named
  by `KUBECONFIG_PATH` in `__REMOTE_DIR__/.env` (never print its contents).
- Read-only E2E/trigger log tails if needed to correlate timing (do not follow
  them as your primary signal; your watches are primary).

## Files you own (sole writer)
Everything under `__REMOTE_DIR__/__SCENARIO_DIR__/runs/__RUN_ID__/observer/`
(work remotely on __HOST__; the Lead pulls locally afterward):
`ARMED`, `PRESERVED`, `FINAL` markers + JSON payloads, `watches/*`, `finding.md`.

## Watches to arm (all run-scoped; use `cbt-chaos/watch-resource.sh` where supported)
All output paths relative to the run root's `observer/watches/`:
1. `vmbackup-<run>.jsonl` — `oc get vmbackup vm-backup-__RUN_ID__ -n __NAMESPACE__ -w -o json` (exact name; NotFound-before-create is a valid armed zero-result state).
2. `tracker-<run>.jsonl` — `oc get vmbackuptracker vm-tracker-__RUN_ID__ -n __NAMESPACE__ -w` (exact name).
3. `vm-<run>.jsonl` — `oc get vm vm-__RUN_ID__ -n __NAMESPACE__ -w` (exact name).
4. `pvc-<run>.jsonl` — `oc get pvc -n __NAMESPACE__ -w` filtered at analysis time to names containing `__RUN_ID__` (backup destination PVC `vm-backup-pvc-__RUN_ID__` plus incremental follow-up PVC).
5. `pods-<run>.jsonl` — `oc get pods -n __NAMESPACE__ -w -l vm.kubevirt.io/name=vm-__RUN_ID__` (launcher discovery/UID).
6. `events-<run>.jsonl` — `oc get events -n __NAMESPACE__ --watch` (filter at analysis; retain events for the run's backup, VM, PVC, hotplug/attachment pods).
7. `ctrl-pods.jsonl` — `oc get pods -n __CTRL_NAMESPACE__ -w -l kubevirt.io=virt-controller` (leader deletion + replacement Ready evidence).
8. `lease.jsonl` — `oc get lease virt-controller -n __CTRL_NAMESPACE__ -w` (holderIdentity transitions across failover).
9. `ctrl-events.jsonl` — `oc get events -n __CTRL_NAMESPACE__ --watch` (filter at analysis to virt-controller leader pod names).

## Handoff payloads
- **ARMED** (file `observer/ARMED` + JSON payload): UTC time; for each watch:
  selector, output path, PID, ready-file path, and confirmation that a scoped
  API read succeeded in that same child environment; expected target
  cardinality (zero-result for not-yet-created run objects is valid; the
  virt-controller pod watch should show 2 replicas). State which identity
  checks remain pending before the action (VM/backup/launcher do not exist yet).
- **PRESERVED** (file `observer/PRESERVED` + JSON payload): UTC time; exact
  target pod name/UID deleted and replacement pod name/UID; Lease holder
  before/after; observed action effect via the ctrl-pods/lease watches (not
  Krkn output); full backup terminal condition status AND reason, checkpoint
  name, tracker latestCheckpoint, destination PVC name/Bound; launcher
  `Backup started` line timestamp if captured; raw snapshot file locations.
  Emit only after terminal full-backup/tracker/PVC evidence is on disk and
  BEFORE the same-VM incremental follow-up starts changing state.
- **FINAL** (file `observer/FINAL` + JSON payload): bounded UTC timeline
  (armed → signal → action request/effect → backup terminal → recovery →
  incremental follow-up → restore checks terminal), criterion-by-criterion
  table (PASS/FAIL/BLOCKED/UNKNOWN with observed value, timestamp, artifact
  path+line/JSON-field citations), contradictions, missing observations, clock
  uncertainty. Then stop every watch and write `observer/finding.md` (compact
  final analysis). Criteria: derive from the scenario spec §5 pass/fail list;
  do not invent new ones.

## Rules
- One long-lived watch per resource; no `oc get` polling loops as primary signal.
- Record the launcher's `Backup started` line (compute container log, exact
  backup name) as the active-copy signal — backup creation or `Progressing=True`
  is not the copy signal.
- Per spec S3 and observer-skill rule (H4): once the launcher exists and
  before injection, capture the checkpoint-tree state via the launcher
  compute container (`virsh checkpoint-list --tree`) into
  `watches/checkpoint-tree-pre.txt` (record the command and raw output);
  capture again at PRESERVED into `evidence-terminal/checkpoint-tree-post.txt`.
  Also attempt `qemu-img info` on the backup artifact where the recovered
  launcher provides it; if unavailable, record the absence and reason in
  your finding.
- Trigger/Krkn output is a request, not proof. Prove the deletion through your
  own ctrl-pods + lease + ctrl-events watches.
- The Lead heartbeat-probes your watch PIDs every 10 min from disk: keep
  `observer/watches/pids.json` updated (selector → PID + ready file) and message
  the Lead immediately (write `observer/WATCH-LOST`) if any watch dies mid-run.
- If a watch is lost before the injection boundary, report it immediately —
  a lost watch invalidates the injection claim (BLOCKED).
- Raw streams stay on disk in `watches/`; never paste them into your replies.
- Do not read other runs' artifacts, reports, or the learnings file.
