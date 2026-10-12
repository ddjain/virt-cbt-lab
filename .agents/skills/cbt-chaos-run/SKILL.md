---
name: cbt-chaos-run
description: >
  Run a KubeVirt CBT chaos scenario with product-focused full/incremental backup,
  checkpoint/tracker, CBT recovery, and restore verification. Validate scenario
  execution separately from the product result and report harness findings
  outside the standalone result/report. Supports v1 and CBT v2 scenarios; use
  when a user requests a scenario run or report.
user_invocable: true
arguments:
  - name: request
    description: >
      Scenario ID or directory and desired target/workflow, e.g. "run CBT-F-01
      on the configured chaos host" or "execute scenario 01 against the full
      backup". Include the existing VM for incremental tests when known.
    required: true
---

# CBT Chaos Scenario Runner

Run one CBT chaos scenario end-to-end: resolve → inspect → validate → execute → observe → verify → report. User requests to run a scenario authorize the scenario-specific E2E and chaos injection on the configured dedicated demo cluster. Ask a follow-up at the start if scenario, target, workflow, or expected behavior is not at least 95% clear after reading the issue/spec and available repository state.

## Generic execution gates

Apply the same gates to every v1/v2 scenario; obtain the values from **that scenario's** Jira/spec, active trigger, and live resources. Never substitute a generic signal, object selector, chaos command, backup type, or pass criterion for the scenario contract.

1. **Resolve:** choose one new chaos artifact `RUN_ID`. For a new full lifecycle, resolve its `NAME` separately; for incremental, select and validate the existing managed `VM` rather than creating a new VM. Check the exact local scenario path, remote path, and run-scoped cluster names together once immediately before reserving the artifact directory. The trigger's own fail-closed collision guard remains in place. Do not inspect existing artifacts.
2. **Validate:** reconcile issue/spec, script, local and remote workflow support, target, signal, action, safety, recovery method, and criterion-by-criterion evidence oracle. A missing or contradictory contract blocks mutation.
3. **Arm:** one read-only monitoring agent proves child-process API access and starts exact resource and signal watches; a running PID or marker alone is not proof. It sends `ARMED` with the authenticated selector/watch evidence. Before a newly created target can be disrupted, revalidate its exact UID, owner/run association, and selector cardinality; zero targets before setup is normal, but ambiguity at injection is not.
4. **Execute:** the trigger is gated on continued watch health and the scenario's actual signal, records a UTC action-request time with exact resource name/UID, and preserves separate workflow/action exit statuses. A lost watch before the boundary blocks or aborts the action; never infer a valid injection from a later event.
5. **Preserve → recover → assess:** the agent sends `PRESERVED` only after terminal backup/tracker/checkpoint/PVC evidence is captured before recovery can change it. Run the API-supported same-VM check, then any separate supplemental lifecycle. After all checks terminate, it sends one `FINAL` UTC timeline and criterion table; the parent reconciles against the run-scoped API and lifecycle records before reports.

Keep the observer's three handoffs compact (`ARMED`, `PRESERVED`, `FINAL`); put raw streams on disk. Do not poll for narrative progress or spawn a second observer merely because a handle/acknowledgment is delayed. Investigate the original handle and stop the run if no verified `ARMED` response arrives.

## Run isolation

Treat every invocation as an independent test. For scenario intent and acceptance criteria, use only the selected scenario's `jira-issue.md` and `scenario-spec.md` (for legacy scenarios without a Jira file, use that scenario's spec). Do not inspect historical `runs/` contents, prior reports, old logs/snapshots, previous trigger output, run history, or past timing measurements. Do not use prior-run information to choose the workflow/action/trigger, interpret current evidence, set the verdict, or write the current report. If the selected spec contains historical execution notes, treat them as history—not as current-run evidence or acceptance criteria.

Use the current run's live cluster state and newly collected observer, event, trigger, E2E, lifecycle, and restore evidence to validate this run. A collision check may inspect whether a `RUN_ID` path/resource name already exists, but must not open its old artifacts. For an incremental workflow, inspect only the current managed VM/lifecycle state required as a runtime precondition; do not consult another scenario run's results.

Read the root `AGENTS.md` instructions first if they are not already in context. The live cluster may contain unrelated VM/backups; always scope every action and watch to the selected scenario/run.
## Product scope and finding separation

The primary question is whether CBT full/incremental backup behavior meets the scenario criteria: backup type and terminal reason, checkpoint/tracker correctness, VM CBT recovery, and data/restore correctness. The E2E workflow, trigger, observer, and report generator are test machinery. Validate them as needed to establish trustworthy evidence, but do not mistake a harness failure for a CBT product failure.

Keep `test-run-result.md` and `test-run-report.md` focused on CBT behavior and recovery. If the E2E workflow, trigger, observer, report writer, or artifact transfer has a defect or improvement, explain it separately in the final chat under **Harness findings (not a CBT product finding)**. Do not put harness findings, framework exit codes, or implementation defects in either Markdown report.


## Safety rules

- Never run `make clean-all`. It deletes managed resources for all runs in the namespace.
- Run the selected scenario's supported backup workflow, the exact targeted chaos action, and the post-chaos full/incremental recovery checks required below. Do not delete unrelated resources or clean the namespace afterward.
- Use the configured SSH host and remote checkout (`REMOTE_HOST`/`REMOTE_DIR` from `.env` or explicit user input). Use the cluster kubeconfig on that host in place. Never read, print, transfer, or commit kubeconfig contents, `.env`, private keys, or credential values.
- Do not hardcode private hostnames or absolute host paths into committed files. Derive the remote trigger path from `REMOTE_DIR` and the scenario's actual repository-relative folder.
- Before every remote scenario run, execute `make resync` from the local checkout after validating the local trigger and before starting observers/E2E. First confirm `REMOTE_HOST`/`REMOTE_DIR` and inspect target files for remote edits; stop and ask if resync would overwrite unexpected changes. Verify the remote trigger matches the validated local file. Never run `make resync` after this run begins or completes; use `make pull-reports` after E2E.
- If the target path, VM/run, or framework behavior is ambiguous or the remote checkout has conflicting edits, stop and ask before a live mutation. No separate confirmation is needed for the exact planned run once the user request and target are clear.

## Phase 0 — Resolve the scenario and run IDs

1. Resolve the scenario from the exact user input and local tree. Supported locations:
   - Legacy: `cbt-chaos/scenarios/<scenario-name>/`
   - CBT v2: `cbt-chaos/scenarios_v2/<scenario-id>/`
2. For v2, read `jira-issue.md` as well as the spec; use its test ID/title and every expected criterion in the final report. Do not guess an ID or use a different test folder.
3. Read `REMOTE_HOST` and `REMOTE_DIR` without exposing `.env` values. Confirm SSH access and locate the remote checkout. The execution script must be run from the configured remote checkout, not from an assumed local path. If the user supplied a remote path, verify it exists and corresponds to the resolved local scenario directory.
4. Choose a unique chaos `RUN_ID`; just before creating its artifact directory, check the exact local and remote scenario paths and run-scoped cluster names together for collisions, without opening old artifacts. Do not repeatedly query the same unchanged collision state; retain the trigger's fail-closed guard. Resolve E2E `NAME`/`VM` separately from the chaos execution ID. For `TYPE=incremental`, inspect only the selected managed VM's current lifecycle metadata and remaining pass count as runtime preconditions. Ask early if there are multiple plausible VMs.
5. Create the per-execution artifact directory under the scenario, `runs/<RUN_ID>/`, on the remote checkout. Keep chaos logs, snapshots, JSON copies, and reports there. After the run, pull this directory into the matching local scenario path. Do not overwrite an existing run directory.

## Phase 1 — Read and reconcile the spec and trigger

Read `scenario-spec.md` and every active trigger version in the scenario directory (`chaos-trigger.sh`, `chaos-trigger-v2.sh`, or another explicitly named active script). For v2 also read `jira-issue.md`. Extract:

- Hypothesis, workflow/backup target, target component/resource, action, duration, and exact injection signal/window.
- Pass/fail criteria, recovery expectations, verification commands, blast radius, and known timing/cluster constraints.
- Script inputs, exact `make` command, exact Krkn/`oc` action, event query, target selector, exit-status handling, and output paths.
- Resolve which identifiers are stable before VM creation, which appear later, and how the observer will acquire the exact UID and owner before the action. Include the API-supported same-VM recovery method separately from any supplemental new-VM lifecycle.

The spec and script must agree. The script is the executable source of truth for the command; the spec is the contract for intended timing and outcome. If either is missing or inconsistent, update the local spec/script before syncing and running. Preserve prior validated script versions when introducing a materially different mechanism; keep the active script name explicit in the spec.

## Phase 2 — Validate the real workflow, cluster target, and chaos command

### Workflow and target

- Inspect the active local and remote `Makefile`, `make help`, `scripts/e2e-stage.sh` when present, run-ID/resource naming code, and relevant backup scripts. Never assume local and remote checkouts are the same revision.
- Select the `make e2e` mode that matches the issue. In the current framework, `make e2e TYPE=full` creates a new lifecycle and takes the full backup; `make e2e TYPE=incremental VM=vm-<run-id>` uses an existing managed lifecycle and adds its next planned pass. Default `make e2e`/`TYPE=all` runs the complete fresh lifecycle. These modes are valid only when the active checkout implements them; an older Makefile may ignore `TYPE` and run the full demo. Never run the wrong mode merely because Make accepts the variable.
- Inspect live resources using the configured host-local kubeconfig: namespace, exact VM/VMI, backup/tracker/PVC names, relevant pods and labels, node placement, events, and current state. Derive selectors from live objects and this run's ID. Do not use broad pod selectors in the shared demo namespace.
- Do not read scenario run history, previous results/reports, or old logs. They must not influence this run's plan, evidence interpretation, verdict, or report.

### Krkn validation

Invoke/read the `krkn-scenario` skill for the exact action. On the host that runs the trigger, verify `krknctl`, run `krknctl list available`, `krknctl describe <tag>`, and `krknctl run <tag> --help`. Validate every flag and target from live metadata; then run `krknctl run <tag> --dry-run ...` with the exact arguments. Do not substitute guessed flags or stale commands.
Batch those required metadata commands on the host and project only the relevant scenario tag, target flags, native-trigger flags, and dry-run result into model context; retain raw output in this run's artifact bundle if needed. Do not consume the full registry listing or unrelated global help as analysis evidence.

Prefer Krkn's documented event-driven trigger arguments (`--trigger-command`, `--trigger-k8s-*`, or the exact supported equivalent) tied to the issue's observed condition. Whenever `krknctl` performs the disruption, the disruption MUST be gated by that native Krkn trigger and Krkn MUST be started early enough to absorb its own startup time. A custom host-side Bash observer that detects the condition and only then launches `krknctl` is not reliable for short CBT windows; Krkn startup can consume the entire window. A custom event observer followed by a direct, narrowly scoped `oc`/`kubectl` mutation is acceptable when Krkn cannot preserve the exact action/target/timing, with the reason documented. Determine the exact Kubernetes object and event/state transition to query. Backup CR creation is not proof that QEMU copy has started. Do not use arbitrary sleeps to represent an event.

Validate the trigger before execution:

- Run `bash -n` on the active script. `bash -n` only checks syntax; it does not catch an edit that silently deletes a load-bearing variable assignment (a real prior incident let an E2E run proceed with zero chaos injected because an edited comment block consumed the line defining the trigger command, and the script only failed at runtime under `set -u` after the backup had already started). If the trigger was just edited, additionally grep for the definition of every variable the script's chaos-action command references (for example its `TRIGGER_CMD`/equivalent assignment) and confirm each still exists at its expected scope, or run the script in a mode that only resolves variables without executing the action.
- Confirm it invokes exactly one E2E workflow and one intended chaos action, passes only supported `make`/Krkn arguments, arms the trigger early enough, waits for both operations, preserves each exit code, and does not leave background processes running.
- Confirm script/spec paths and runtime variables match the remote checkout. Confirm the test `RUN_ID` cannot collide with existing local or remote run data.
- Require an explicit UTC action-request record with run/backup identity, target kind/name/UID, and observed signal; a tool exit code or second-resolution `Killing` event cannot establish subsecond order. If the active trigger cannot gate its action on authenticated observer health and a unique live target at the injection boundary, make that safety change locally before synchronization; do not start a live run with an unguarded trigger.
- If the script needs changes, edit it locally and rerun syntax/Krkn dry-run checks. Inspect remote divergence, then run `make resync` before execution; do not use a broad sync after run artifacts exist.

### Pre-run test oracle

Before arming the observers, build a compact evidence oracle from the selected issue/spec and the relevant injection-boundary and source-grounded failure-matrix entries in `docs/cbt/10-chaos-test-design.md`. Read only the relevant design sections; do not import unrelated scenarios or historical run results into this run.

For every stated acceptance criterion, record in the monitoring task contract:

- The product invariant or expected state transition.
- The primary evidence source and, where available, an independent corroborating source; if no independent source exists, name the authoritative source and limitation.
- The exact run-scoped object/field, log signal, or restore result that proves it.
- A plausible false-positive or alternative explanation that would invalidate a pass.

Capture the relevant baseline before injection, including identities and states needed to interpret later deltas. Keep this oracle aligned with the issue/spec: do not silently add acceptance criteria. New behavior outside the stated criteria is an unexpected observation or follow-up hypothesis, not a retroactive pass/fail rule. No separate planning artifact is required unless the scenario needs one for reproducibility.


## Phase 3 — Start live resource observers and run remotely

Run the exact remote scenario script from the configured remote checkout, using the repository-relative v1/v2 folder resolved above. Do not start a second `make e2e` if `chaos-trigger.sh` already orchestrates it. If it only performs chaos, start the matching supported `make e2e` invocation as a separate process.

Invoke it through `ssh "$REMOTE_HOST"` from the configured host, `cd` to `REMOTE_DIR`, and run `bash` on the verified repository-relative trigger path. Quote the remote command/arguments and propagate the SSH/script exit status; do not try to execute a remote script as a local file.
Pass the newly chosen chaos `RUN_ID` and the separately resolved lifecycle `NAME`/`VM` explicitly through the active trigger's documented interface. Do not rely on a hardcoded example/default ID. If the trigger lacks a safe override, update it before synchronization.

From the local checkout, run `make resync` before starting the monitor or trigger. Confirm the resolved remote trigger exists and matches the validated local script; if it does not, do not start the run until synchronization succeeds.

Before the trigger starts, spawn one dedicated read-only monitoring subagent with the task tool. Give it the scenario ID, exact objective and injection window from the issue/spec, RUN_ID, namespace, resolved target object/selector, expected target component, observed condition/query, and the trigger/E2E log locations. Give it access only through the configured remote host and host-local kubeconfig; never pass kubeconfig contents. Its job is to continuously watch the target resource and relevant Kubernetes events with `oc`/`kubectl`, plus the actual trigger/Krkn output when available, and independently confirm whether the expected condition and disruption occurred on the correct component. It must not inject chaos, modify resources, run E2E, edit the trigger, or write the final report.
Require it to independently read the resolved `scenario-spec.md` and, for v2, `jira-issue.md`; it must derive the expected target component, action, injection signal, and time window from those files and compare them with the parent's proposed selector before arming. Do not let it assume the target supplied by the parent is correct without this comparison.

Require the subagent to start its watches and return `ARMED` **only after** an approved host-local kubeconfig has been exported into every child, a scoped `oc` API read succeeds in that same child environment, and each watch stays alive without an immediate API/configuration error. Validate the marker plus child health and stderr; markers, child-ready files written before an `oc` call, and `kill -0` alone do not establish API access. Before a new target exists, an authenticated zero-result watch can be armed, but the subagent must later verify one exact UID/owner/label before disruption. If no authenticated watch is confirmed, do not launch. The subagent continues through recovery and writes raw output only under `runs/<RUN_ID>/observer/`, not the final reports.
The parent must not accept an `ARMED` claim on narrative alone: independently confirm each required `watch-resource.sh` ready-file still exists and its recorded `watch_pid` is live (`kill -0`) immediately before starting the trigger, and again immediately before the action fires. A ready file that is absent, stale, or whose PID is dead means the watch is not armed regardless of what the subagent's message says; stop or hold the action and classify it BLOCKED.
Use the read-only `cbt-chaos/watch-resource.sh <namespace|-> <resource> <name|label|field> <selector> <output.jsonl> <ready-file>` helper for run-scoped Kubernetes resource watches where supported. It saves a scoped baseline, exports the host-local kubeconfig to its `oc` child, creates readiness only after a successful API preflight and healthy watch startup, and removes readiness on exit. Run it under the monitoring agent's supervision; keep its process alive and its output/stderr on disk. A ready file is **not** proof of a later injection signal or target UID. For launcher logs, metrics, or other non-resource signals, use the scenario's exact validated read-only source and the same authenticated/healthy-child gate. The trigger/orchestrator must verify required watches are still live immediately before the action; if they are lost before injection, abort/hold the action and classify it BLOCKED. After injection, preserve the evidence gap and do not infer PASS from post-hoc records.
The helper also verifies `watch` authorization in that child environment. Its readiness is revoked when the watch exits, but does not by itself guarantee a future signal will be observed; retain supervision and an action-boundary health check. Never claim a generic Kubernetes resource watch is equivalent to the scenario's copy/log/metric signal.

The monitoring subagent must run the scoped, read-only watches concurrently with the trigger/E2E and record output in `runs/<RUN_ID>/observer/`, for example:

- `oc get vmbackup ... -w -o json` for the exact run's backup CR transitions.
- `oc get events ... --watch` filtered/retained for the target backup, VM, and affected pod.
- `oc get pod`, `oc get vm`, `oc get vmbackuptracker`, and `oc get pvc` snapshots before, during, and after the disruption.

Use a single long-lived watch where possible, not a tight loop of sequential API requests. For targets that are not `VirtualMachineBackup` objects, watch the actual object identified by the issue (controller/handler/CSI pod, VMI, node, or PVC). Do not leave observers running after the test is terminal.

### Independent injection proof

The monitoring subagent is the read-only injection witness. If the target does not yet exist, first establish an authenticated exact run-scoped watch with zero candidates. Once it appears, independently resolve and check its namespace, kind, name, UID, owner/labels, run association, and selector cardinality **before the action**. Require exactly the intended target; if identity or uniqueness is ambiguous, do not launch the disruption. Recheck this dynamic identity at the injection boundary; the once-per-run collision check is not a substitute.

Record distinct UTC times for the observer becoming armed, the exact scenario signal, the trigger's action request, the independently observed target effect, and relevant backup/recovery transitions. The signal must identify the intended backup/run and represent the specified phase; object creation time or `Progressing=True` alone is not a precise live-copy signal when the spec requires active copying.

Treat trigger/Krkn output as evidence of the requested action, not independent proof that it happened. Confirm the effect through a separate read-only observation suited to the action (for example, the exact target's Kubernetes UID/state transition and relevant API event, or target-specific telemetry when no API event represents the effect; use audit evidence only if already available and authorized). Corroborating records must not merely repeat the same source data. Compare the event order and timestamp resolution/clock uncertainty; do not claim precision the clocks or API timestamps cannot support.

Injection is valid only when the exact target/action is independently confirmed and the scenario-specific ordering among its signal, action, and relevant backup/recovery transitions satisfies the issue/spec. If the watch was not armed in time, the observed UID differs, the action cannot be distinguished from a request, the event is outside the specified window, or timing cannot be established, mark injection validity BLOCKED/UNKNOWN and do not report the scenario as PASS.


Wait until the E2E pipeline and chaos command have each reached completion and their exit statuses are captured. A trigger-script success message or `krknctl` exit code alone does not prove injection. If either process fails or times out, preserve its logs and classify the test as blocked/failed according to evidence; do not report a successful run.

After every E2E/chaos run terminates, regardless of its exit status, run `make pull-reports` from the local checkout. This pulls the remote root `runs/` tree. Then use a targeted, quoted `rsync` to pull the scenario-specific remote `runs/<RUN_ID>/` folder into its matching local scenario folder; `make pull-reports` does not copy `cbt-chaos/.../runs/`. Open and validate only the current run's JSON and observer files; do not inspect other run directories or historical artifacts.
The monitor may already have created the matching **current** local scenario run directory; do not repeat the pre-run absence assertion when pulling its own new artifacts. The collision check belongs before the run, not before each transfer.

### Bounded evidence analysis by the monitoring subagent

Use the monitoring subagent for both independent live observation and a bounded post-run evidence analysis; do not routinely launch a second analyst agent. It should observe during the run, then analyze only after the trigger, E2E workflow, required same-VM recovery, and restore checks are terminal. Keep raw watch output in `runs/<RUN_ID>/observer/`; do not stream full logs or entire JSON files into the agent's reasoning context.

Give the subagent a compact evidence contract before it starts:
- `ARMED`: UTC time, successful scoped API preflight, each required watch selector and live child health, expected zero/one target count, and any pending identity check before the target appears. Parent verifies this before starting the trigger.
- `PRESERVED`: UTC time, exact target UID and action effect where independently observed, terminal backup reason, tracker/checkpoint and failed PVC snapshot locations; parent waits for this before same-VM recovery.
- `FINAL`: bounded UTC timeline, criterion statuses and exact evidence fields, missing observations and clock uncertainty after same-VM and any supplemental verification. Stop every child watch when terminal.

- Correlation keys: scenario ID, `RUN_ID`, namespace, VM name, backup name/UID, tracker name, PVC name, target pod name/UID, and chaos action.
- UTC milestones: baseline; E2E stage/backup creation; signal observed; disruption requested and confirmed; backup terminal transition; tracker/checkpoint snapshot; VM/CBT recovery; same-VM recovery backup; restore result.
- Acceptance criteria from the issue/spec, with the exact fields or observations that prove each one.

After the run, analyze the current run's artifacts only. Start with `summary.json` when present, then use narrow `jq` projections from `run.json`, `report.json`, and the exact object snapshots needed to verify unresolved criteria. The repo-root `runs/` tree (`summary.json`, `run.json`, `report.json`) is addressed by the lifecycle `NAME`, not the chaos `RUN_ID`; for a scenario that keeps these IDs distinct (recommended for v2), resolve `NAME` first and query `runs/$NAME/summary.json`. Scenario-level chaos artifacts (observer output, trigger/Krkn logs, action-request records) live separately under `cbt-chaos/scenarios_v2/<scenario-id>/runs/<RUN_ID>/`. Do not assume `RUN_ID == NAME`; confirm which applies from this run's own resolved IDs before querying either path. For example:

```sh
jq '{run_id, verdict, vm, lifecycle, cbt, backups, restore_hashes, recovery_attempts}' \
  "runs/$NAME/summary.json"
jq -r '.status.conditions[]? | select(.type == "Done") |
  [.status, .reason, .message, .lastTransitionTime] | @tsv' backup.json
```

For plain-text logs, filter to the run's exact backup/pod identifiers and the relevant signal or error terms; bound collection to the run's time window and retain line numbers for citations. For example, use `grep -nF` for an exact resource name or `grep -nE` for a small set of known signal/error patterns. Prefer `jq` for structured JSON logs and object snapshots; do not use text matching as a substitute for checking fields. Never dump all namespace objects, all controller logs, the full `report.json`, or large workload manifests into the prompt. Keep the raw evidence on disk and widen the query only to resolve a specific gap or contradiction.

The subagent's finding must be concise and include:

1. A UTC timeline linking E2E stage → observed signal → requested/confirmed injection → affected object identity → terminal backup state → tracker/checkpoint state → recovery → restore/data result.
2. A criterion-by-criterion `PASS`/`FAIL`/`BLOCKED`/`UNKNOWN` table with the observed value, timestamp, and exact artifact/object source (file plus line or JSON field).
3. Contradictions, missing evidence, and confidence limits. Distinguish CBT product behavior from harness/observer issues; do not infer success from `Done=True`, a checkpoint-name field alone, warning-event presence, or a successful Krkn/E2E exit code.

The monitoring subagent supplies an independent evidence assessment, not the final verdict. The parent must reconcile its assessment against the current run's lifecycle records and primary observer/API evidence before reporting. If the evidence pack is incomplete, request only the missing run-scoped object, log interval, or metric; do not reread unrelated artifacts or historical runs.

### AI and tool-call efficiency

Keep model context focused on decisions and evidence, not repeated raw output:

- Use exactly one monitoring subagent for both live observation and post-run analysis. Keep its returned handle and use the three handoffs above; if an agent tool appears to return a completed/unresolvable handle, investigate that result rather than launching duplicate watches or analysts. Escalate only a specific failed slice.
- Give the subagent a short, run-specific task contract. It must independently verify the target, action, signal, and window from the relevant issue/spec sections, but should not reread entire unrelated workflow docs or load the full skill into its task context.
- Redirect continuous watch output and raw logs to run artifact files. Do not stream every watch frame, poll result, or log line into model context; inspect a compact filtered result only when needed.
- Start with the existing summary and observer finding. Reuse collected snapshots and logs; do not issue duplicate `oc` queries or reread unchanged artifacts. Batch independent reads/queries where practical, and project only the fields needed for the criteria.
- Before each additional tool call, identify the unanswered acceptance criterion or contradiction it will resolve. Query only that run-scoped object, timestamp range, log pattern, or metric; stop when the required evidence is established.
- Keep the subagent response to the required compact timeline, criterion table, material contradictions, and evidence gaps. Cite source paths plus line numbers or JSON fields; never paste raw logs or full JSON into its response.
- The parent must independently reconcile the verdict-critical evidence, not repeat the subagent's entire investigation. Escalate to another agent only if the monitoring agent fails or a specific unresolved issue requires separate expertise.



## Phase 4 — Validate injection, workflow JSON, and recovery

1. Reconstruct a UTC timeline using the monitor subagent's observer output, Kubernetes events, backup condition transitions, trigger log, and E2E log. Verify the exact condition, intended injection window, expected component/object from Jira/spec, and observed resource affected.
   - Before assigning any verdict, receive the monitor subagent's final timestamped report and reconcile it against independent API events/logs. Require explicit confirmation of both (a) injection within the specified window and (b) the action affecting the exact component/resource specified by Jira/spec. If either is missing, contradictory, or inconclusive, the run cannot PASS.
2. Locate the active lifecycle record from the executed run's observed ID, not timestamps. Validate emitted `run.json`, `report.json`, and `summary.json` as JSON and compare IDs, VM/namespace, backup details, and underlying checks. Confirm the scenario workflow process is terminal. A managed lifecycle may remain incomplete when an expected backup failure stops it; do not turn that status into a CBT product verdict.
3. Compare framework records with live `oc` results and observer evidence. Require the backup types/reasons, checkpoints, tracker, CBT state, and restore/data checks from the scenario criteria. If a framework file or field is missing, record it only as a separate harness finding; if product evidence itself is unavailable or contradictory, classify the scenario BLOCKED rather than infer a pass.
4. Check recovery and data correctness from the spec. Inspect terminal `VirtualMachineBackup` `Done` condition status **and reason**; `Done=True` alone is not success. Check the VM/launcher returns ready, tracker/checkpoint state matches expectations, and restore/hash/marker verification succeeded where required.

### Adversarial completeness review

Before accepting any tentative PASS, perform a skeptical pass over the run-scoped evidence:

- Could a transient or stale status, event, checkpoint-name field, or later retry make the result look healthier than the primary attempt? Confirm terminal conditions and capture tracker/checkpoint state before recovery can change it.
- Are control-plane and data-plane claims both covered where the scenario requires them? Check backup type and terminal reason, tracker/checkpoint invariants, VM/VMI/CBT recovery, and the required restore/data verification as separate claims.
- If the scenario claims actual incremental/delta representation or chain correctness, inspect the relevant qcow2 backing relationship and allocation metadata (`qemu-img info`/`qemu-img map`) when available. Restore success, an `Incremental` label, or file size alone does not prove the physical delta/chain claim. If artifact inspection is unavailable, state that limitation rather than claiming it was verified.
- Does every acceptance criterion have evidence from the correct run, object UID, and time interval? Did any watcher gap, selector ambiguity, clock uncertainty, conflicting API/log state, or unobserved transition weaken the claim?
- What evidence would falsify each PASS? Search only the relevant run-scoped events, object transitions, and component logs for that counter-evidence; do not expand into unrelated namespace/controller dumps.

Use the scenario-relevant failure hypotheses in the design doc to interpret unexpected transitions, not to presume a defect. Report material anomalies separately as product findings or harness findings with the observed evidence and confidence. Keep suspected causes and new tests explicitly labeled as hypotheses/follow-ups; do not broaden or rewrite the current acceptance criteria after observing the outcome. For a novel, high-impact, or contradictory result, a focused skeptical reviewer may independently assess the criteria and evidence without being told the parent’s preferred verdict; otherwise, use the existing monitoring subagent and parent reconciliation.


### Required post-chaos same-VM backup validation

After the intended disruption, first preserve the failed backup CR, tracker state, checkpoint evidence, and destination PVC. Do not delete, overwrite, or accept a failed/partial artifact.

The primary post-chaos backup check is against the **same original VM**, after its VMI/launcher is Ready and CBT is Enabled:

1. If the targeted full backup failed or no successful full exists, attempt a new full backup on that recovered VM using a unique backup-object name and destination PVC. Use only a live-schema/API-supported full-backup method; do not reapply the failed object's name, reuse its PVC, or guess spec fields.
2. If the targeted incremental failed and a prior successful full/checkpoint still exists, attempt a new incremental on the same VM from the last known-good checkpoint with new backup/PVC names. Never reuse the failed pass name or use its checkpoint as a base.
3. If the same-VM full succeeds and the scenario's planned chain includes an incremental, continue on that same VM with the next supported incremental and verify tracker/checkpoint and restored data. If the same-VM backup itself fails with a CBT backup error after VM/CBT recovery, classify it as a product recovery failure and retain the new CR/PVC evidence.
4. Before attempting a new same-VM backup, confirm the API and active workflow support a distinct backup object/PVC while preserving failed artifacts, and extend the read-only observer with exact watches for those names. If no safe supported same-VM attempt exists, do not improvise or substitute a fresh VM as proof; mark the same-VM check BLOCKED and ask for an approved path.
5. A separate fresh full-plus-incremental lifecycle may be run afterward as supplemental cluster/data recovery evidence, with its own run ID. It does **not** replace the same-VM recovery check. Keep both results distinct and sequential; stop observers after all verification is terminal.

### Internal evidence handling

Preserve sanitized lifecycle JSON and relevant logs in the scenario's separate evidence bundle for internal validation. These files support evidence review but are not named or linked in the engineer-facing reports.

## Product verdict

A non-zero workflow result may be consistent with the expected safe failure of an interrupted backup. Base the CBT verdict on backup conditions/reasons, checkpoint/tracker state, CBT recovery, and restored data—not on workflow or chaos-tool exit status:

- **PASS** — the monitor confirms the correct target was disrupted inside the intended window, and all CBT product criteria were met.
- **PASS WITH FINDINGS** — CBT product criteria were met but a non-blocking product/evidence issue remains.
- **FAIL** — observed CBT backup/checkpoint/data/recovery behavior violated a required product criterion.
- **BLOCKED** — target/timing or required product evidence could not be established.

## Phase 5 — Write the run reports from templates

Use both repository templates, filling every field supported by the evidence:

- `cbt-chaos/template/test-run-result-template.md` → local `runs/<RUN_ID>/test-run-result.md` (short Jira/dashboard summary).
- `cbt-chaos/template/test-run-report-template.md` → local `runs/<RUN_ID>/test-run-report.md` (detailed evidence).

After both reports are written locally, use a targeted `rsync` of the scenario run folder back to the matching remote `runs/<RUN_ID>/` directory so the validated reports and evidence exist on both hosts. Do not use `make resync` for this post-run copy.

Both files must be standalone for an engineer who does not have this repository. Include all source test-plan fields (ID/title, workflow in product terms, objective, target, action, injection window/signal/duration, expected behavior, recovery, verification, expected outcome, priority, technical scenario, phase), product outcome, backup/checkpoint/tracker/CBT/data evidence, post-chaos recovery result, and UTC timeline.

Each report must contain a **How we ran the scenario** section describing the actual high-level sequence in plain language (baseline/setup, backup stage, observed injection signal, targeted disruption, recovery checks, and post-chaos backup/restore verification when run). Do not refer to `chaos-trigger.sh`, `make e2e`, any repository script/target, local/remote artifact paths, or framework JSON filenames. Describe the workflow and injection as actions and product resources, not as steps that require this repository.

Use concise, human-readable evidence descriptions (resource names, condition/reason, timestamps, observed state) in the reports. Preserve raw logs and API snapshots in the separate run-artifact bundle, but do not make report comprehension depend on repository-relative paths or attachments. Link the result summary to the detailed report. Never run `make clean-all`.

### Report truthfulness and standalone evidence

Write for PMs and engineers who may not have this repository or its test framework. Use direct, simple language; define specialized terms briefly on first use. Explain what was expected, what was observed, and what conclusion follows. Never turn an expectation, inference, or missing observation into a fact. Distinguish observed results from hypotheses and recommendations. If evidence is unavailable or inconclusive, say so explicitly and use the appropriate BLOCKED/UNKNOWN result; do not fill gaps with plausible values.

Make evidence understandable in the report itself:

- Identify relevant resources by kind/name and namespace; include UID, owner/run association, container, or other identity detail when it establishes the exact target.
- Give UTC timestamps, observed condition/status and reason, tracker/checkpoint values, and concise restore/data results. State timing precision or uncertainty when material.
- For a log reference, name the component/resource and container, give its UTC time, and quote only the short relevant line or message. Do not cite an internal artifact path as a substitute for the evidence.
- Keep the short result report readable; put any detailed evidence or command snippet in the detailed report. Do not make either report depend on an attachment, repository file, or internal log bundle.

The detailed report MAY include the actual, sanitized `oc`/`kubectl` command used to inspect a resource or the actual `krknctl`/narrow `oc`/`kubectl` command used to inject the disruption, when it materially helps an independent reader understand or reproduce the action. Place it under **How we ran the scenario** or **Target and disruption**; label it as live or dry-run and identify the actual target and namespace. Include only commands confirmed from this run—never reconstruct or invent one after the fact. Do not include credentials, tokens, private hostnames, environment-specific paths, broad selectors, or unsafe invocations; describe the observed action and evidence instead. These external cluster commands do not require access to the repository.


Verdict rationale must be based on the scenario's pass/fail criteria, not solely on `make e2e` exit status, `krknctl` exit status, or `Done=True`. Do not commit or push unless asked.

## Required report content and verdict

The detailed report must explicitly include:

- Every source test-plan field and the standalone **How we ran the scenario** steps.
- Expected-versus-observed target identity, observed condition, injection timing, disruption, terminal backup state, recovery, and independent monitor conclusion.
- For every backup relevant to the criteria: type, `Done` status and reason, checkpoint name, tracker checkpoint, included volumes where available, PVC disposition, CBT state, and restore/data-check result.
- Same-VM post-chaos backup outcome for the affected full/incremental stage. If a separate clean lifecycle is also run, label it supplemental; it never substitutes for the same-VM result.
- Criterion-by-criterion PASS/FAIL/BLOCKED results and CBT-product findings. When evidence warrants recommendations, distinguish engineering action from customer guidance.

Never put repository/framework commands or implementation references in either Markdown report: this includes `make e2e`, `chaos-trigger.sh`, other repository scripts/targets, framework exit statuses, internal artifact paths/filenames, or report-writer/observer details. This does not prohibit the actual sanitized `oc`/`kubectl` or `krknctl` commands described above when they explain the live inspection or injection. If a harness defect or improvement is material, report it separately in the final chat as **Harness findings (not a CBT product finding)**. Keep the scenario verdict based on the CBT acceptance criteria, not orchestration or tool exit status.

For a CBT product finding, include an evidence-backed **Engineering recommendation** when a product change, API-contract clarification, or investigation is warranted. Distinguish a confirmed contract defect from an unresolved question; do not present a suspected cause or speculative fix as established. Include a separate, concrete **Customer recommendation** only when the run supports customer action or mitigation; otherwise state that no specific customer action was identified. Put applicable recommendations in the reports' CBT-product findings/next-action content and summarize them in the final chat. Keep harness recommendations under **Harness findings (not a CBT product finding)** in the final chat only; never put harness findings or recommendations in either report.

### Bug-ticket drafts for product findings

When a CBT product finding warrants an engineering ticket, draft it from `cbt-chaos/template/engineering-jira-issue-template.md`. Store the draft at the **scenario level**, `cbt-chaos/scenarios_v2/<scenario-id>/bugs/<bug-file>.md` (create the `bugs/` directory if absent) — not inside a single run directory — because a finding may be corroborated by multiple runs. The ticket's `Related scenario / execution` field and evidence section MUST name every run label from which the finding was reproduced (e.g. both the RHEL 9 and Windows run IDs), with per-run timestamps/UIDs; a single-run observation stays in that run's report until a second reproduction or a stronger contract basis exists. Keep harness defects in a separate ticket from product bugs. Push the updated scenario `bugs/` directory to the remote checkout with a targeted rsync after writing, the same as run reports; never use `make resync` post-run.

## Lessons this skill encodes

- Krkn startup and trigger-evaluation latency can exceed short CBT copy windows. Start Krkn early with its native event trigger so its startup is absorbed before the condition.
- Sequential `oc get` polling adds API round-trip delays. Prefer one long-lived watch or Krkn's supported native trigger; use `oc`/`kubectl` as an observer or narrowly scoped fallback when needed.
- `Done=True` is not success by itself. Check `.status.conditions[?(@.type=="Done")].reason`, backup type, checkpoint, tracker, and restore/data verification.
- Use the framework's lifecycle files and observer bundle internally to validate product claims. Keep repository-specific filenames and paths out of engineer-facing reports.

## Run learnings

Do not read the canonical run-learning file during planning, execution, evidence interpretation, or report writing; prior-run lessons must not influence the current test or report. After the current report is finalized, follow the `Learning closeout` process below. Do not create another learning file.
## Learning closeout

Before closing a run, the assistant MUST assess whether the **current run's** evidence establishes a generic, actionable workflow/process lesson worth recording. The monitoring subagent MAY suggest a candidate lesson from current observations, but the assistant owns the decision and the update to the canonical learning file. Do not ask the user the routine yes/no lesson question.

- Only after the current reports are finalized, review the canonical run-learning file for duplicates. Append one concise, dated, evidence-backed entry only when the lesson is generic, actionable, reusable, and not already recorded. Do not record a scenario-only outcome or let the existing file influence the completed run/report.
- If there is no substantial reusable lesson, make no entry.
- Use the existing learning file only. Do not create another `.md` file; ask before creating one if no suitable file exists.
- If the lesson warrants a main skill change, propose the exact additions/updates/removals and wait for explicit user confirmation before editing a `SKILL.md`.
