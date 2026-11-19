---
name: cbt-chaos-simple
description: >
  Execute one CBT chaos scenario simply and directly on the fixed execution host
  `ssh cloud05` (checkout /root/v2/virt-cbt-lab, kubeconfig /root/mno/kubeconfig —
  all make/oc/krknctl commands run there). Takes a scenario ID
  (e.g. CBT-F-08), reads its definition under cbt-chaos/scenarios_v2/<ID>/,
  plans the run, uses the krkn-scenario skill to derive and validate the
  krknctl command (or drafts an oc/kubectl fallback for faults krknctl cannot
  express), discusses the injection approach with the user, prechecks it, runs
  the make pipeline stage with the injector armed, validates the outcome
  through the pipeline's own backup validation, and writes the run report from
  the template. Use when the user wants a scenario planned and/or executed
  without the full v2 lead/analyst machinery. Never execute the injection
  before the user approves the exact command.
user_invocable: true
arguments:
  - name: scenario
    description: >
      Scenario ID and desired target/workflow, e.g. "CBT-F-08" or "plan
      CBT-F-09 on windows/ODF full backup". Include the stage (full or
      incremental), OS, and backend when known; otherwise they are derived
      from the scenario definition.
    required: true
---

# cbt-chaos-simple — simple scenario executor

Drive one CBT chaos scenario end to end: **read → plan → discuss → test → run → verify → report**.
The make pipeline is the backup validator — never re-implement backup validation; interpret the
pipeline's verdict against the scenario's expected failure signature.

## Inputs

- **scenario** (required): e.g. `CBT-F-08`. Resolve to `cbt-chaos/scenarios_v2/<ID>/`.
- Optional (derive from the scenario when omitted): run ID, VM_OS, backend (ODF default, HPP when
  the use case needs it), stage (`full` | `incremental`), expected verdict.

## Execution environment (fixed)

- **All execution happens on `ssh cloud05`** — every make/oc/krknctl/scp command runs there,
  never on the local workstation. Local work is limited to reading the skill, drafting scripts
  (write locally, `scp` to cloud05, run via `bash -n` first), and editing this checkout's files.
- cloud05 checkout: `/root/v2/virt-cbt-lab` (verify `git log --oneline -1` and that the needed
  `make` targets exist via `make help` / `make stage-list` before relying on them).
- Kubeconfig: `/root/mno/kubeconfig` (`export KUBECONFIG=/root/mno/kubeconfig` for oc;
  `--kubeconfig /root/mno/kubeconfig` for krknctl; `KUBECONFIG_PATH` is preset in the
  checkout's `.env`).
- Required on cloud05: `krknctl`, `oc`, `jq`, `make` (verify with one ssh command before
  planning; also confirm the plugin exists in `krknctl list available` — digests move,
  recheck every run).

## Hard safety rules (non-negotiable)

1. **User gate**: never arm or execute a chaos injection before the user approves the exact
   command, trigger, sizing, and blast radius. Discussion is a step, not a courtesy.
2. **Mechanism preference**: native `krknctl` plugin first — derive and validate the exact
   command with the `krkn-scenario` skill during planning. Use `oc`/`kubectl` only for faults
   krknctl cannot express (e.g. a pool free-space-floor filler on shared HPP), and only with
   explicit user consent. State which case applies and why.
3. Never run `make clean-all`; never delete failed-backup PVCs/artifacts — they are evidence.
4. One mutating stage at a time (`state/e2e.lock` refuses concurrency — wait, never force).
5. HPP destinations are **shared node pools**: krkn fill percentages are computed against the
   whole pool (df), not the PVC request. 95% on a 1.5T pool leaves ~75GiB and a 40–60GiB backup
   SUCCEEDS (invalid run). Use 99% and remove the leftover `kraken.tmp` after terminal state.
6. Never claim success or failure from exit codes alone — check `runs/<run-id>/run.json`,
   `summary.json`, and the vmbackup Done reason.
7. Recovery runs only when the user asks for it.
8. **What needs re-approval**: re-ask the user only when the injection point, target, fault,
   or blast radius changes. Fixes that restore the approved behavior (a broken trigger parse,
   a mis-targeted pod, a guard bug) proceed — but state each fix in the next message.
9. **Process hygiene on cloud05**: never `pgrep -f`/`pkill -f` a pattern from inside an ssh
   command or wait loop (it matches its own command line — hung loops, killed shells). Capture
   the PID (`$!`) and use `kill -0 <pid>` / `kill <pid>`. After stopping an injector, confirm
   no `krknctl run` process and no `krknctl-*` podman container remains.

## Step 1 — Read the scenario

Read, in order:
- `cbt-chaos/scenarios_v2/<ID>/jira-issue.md` — the defect/failure mode, acceptance criteria.
- `cbt-chaos/scenarios_v2/<ID>/scenario-spec.md` (if present) — workflow legs (control/surgery),
  injection target/action/window, measurements, classification (RESILIENT/DEFECT), blast radius.
- `cbt-chaos/scenarios_v2/<ID>/runs/` — prior attempts and their learnings; do not re-fail a
  known-bad approach.

Extract into a plan: what breaks, which stage it lands in (full/incremental), the target
component, the expected failure signature string, and how the scenario classifies results.
If the spec is missing or thin, draft the plan from the Jira issue and confirm it with the user
before proceeding.

## Step 2 — Plan the run

Resolve and confirm with the user:
- RUN_ID (suggest `<date>-<scenario-lowercase>-rNN`), VM_OS, backend, stage.
- Resource names (derivation): backup `vm-backup-<RUN_ID>` / dest `vm-backup-pvc-<RUN_ID>` /
  tracker `vm-tracker-<RUN_ID>`; incremental pass NN: `vm-incremental-<RUN_ID>-pNN` /
  `vm-incremental-pvc-<RUN_ID>-pNN`; launcher pod via label `vm.kubevirt.io/name=vm-<RUN_ID>`.
- **Fresh control run** (always): same profile, no chaos, must PASS. It is also the
  trigger-validation reference and the timing baseline. Extract: dest capacity (df inside the
  mount, not the request — HPP differs), artifact size, copy duration, setup duration.
- Sizing: the injector must leave less free than the artifact needs (`floor < artifact`, with
  margin for concurrent writes). For krkn pvc fill: `floor = capacity × (1 − pct/100)`.
- Timing budgets: `--triggers-timeout` must exceed setup (Linux ~1800s; Windows OOBE ~20–25 min
  → 3600s). Fill itself is fast (~1.3s for ~57GiB on RBD); `--duration 120` is plenty.
- **Sub-second windows** (a phase shorter than the 1 s trigger poll + `oc` call latency, e.g.
  copy-complete → Done): do NOT gate on the window itself (CBT-F-13 r01: the compound
  condition never fired). Measure the control's phase timestamps first
  (`scripts/backup-state-watch.sh <run-id>` with no checkpoint; launcher log lines; Done
  `lastTransitionTime`), then choose: (a) an offset trigger from a launcher log timestamp, or
  (b) the fast `oc` watcher fallback (needs explicit user consent, rule 2).
- **Offset sizing:** `offset = control_copy_s − (krkn_selection_lag + target_margin_s)`.
  Measured: krkn `pod-scenarios` fires ~7 s after the trigger (selection latency); virt-controller
  Lease failover ~15–17 s. Record the control's copy duration and phase timestamps, not only
  totals. Copy time varies ±5 s run to run — state the expected landing band to the user.

## Step 3 — Decide the mechanism and discuss it (user gate)

1. If the fault is krkn-expressible, **load the `krkn-scenario` skill** and use it to derive and
   validate the exact krknctl command: plugin, flags, sizing, trigger wiring. Cross-check its
   output against this skill's measured constants (appendix) and the scenario's contract.
2. If krknctl cannot express the fault, draft the `oc`/`kubectl` fallback and state precisely
   why krknctl cannot express it (e.g. percentage fills on a shared pool cannot target a
   free-space floor).
3. Propose, and get explicit approval for:
   - the **exact command** (krknctl or fallback),
   - the trigger that gates it. Do NOT invent a condition from scratch — pick
     from `templates/trigger-library.md` (one tested condition per checkpoint,
     all live-validated 2026-11-11), substituting RUN/BACKUP/PVC/POD/TRACKER/VM:
     - **Backup-copy window**: PVC Bound + launcher exists + vmbackup Done≠True +
       the exact backup's `Backup started` line in the launcher compute logs
       (compound condition in the library; see also `templates/precheck.sh.tpl`).
     - **BACKUP_INITIALIZING window** (pre-copy): vmbackup exists AND
       `Initializing=True` AND Done≠True AND launcher scheduled (`&&`-chained
       compound in the library; the r02 existence and r03 node-assignment traps
       are built in).
     - Other checkpoints: PVC_BOUND, VOLUME_ATTACHING, COPY_IN_PROGRESS,
       BACKUP_COMPLETED/FAILED, CHECKPOINT_RECORDED, DETACHING, log-based
       (BACKUP_REQUESTED / GUEST_FROZEN / COPY_STARTED / COPY_FINISHED_LOCAL),
       TRACKER_ADVANCED, event-based (hotplug pod / volume mount/unmount).
   - Trigger-command mechanics (verified live in krkn image `7b2b29ed1be6`):
     multi-line commands are supported (YAML `inline: |-` → `shell=True`), the
     container ships oc/kubectl/jq/bash with KUBECONFIG preset, and each poll
     has a **30 s hard timeout** — keep conditions ~1-2 s.
   - **Trigger text rules** (each one cost a run in CBT-F-13): (1) **no backslashes** — krkn
     collapses `\\`→`\`, so a jq/grep escape becomes a compile error that is invisible in the
     log (use `.timestamp[0:19] + "Z" | fromdateiso8601`, not `sub("\\.…")`); (2) one trigger
     poll must stay ~1–2 s; (3) the trigger is evaluated by `subprocess.run(shell=True)`, so
     test it with the same quoting, not just `bash -c` locally.
   - **Pod targeting with `pod-scenarios`:** krkn's pod-disruption plugin gives `--pod-label`
     precedence and ignores `--name-pattern` when both are set (r04 killed the standby instead
     of the leader). To hit one named pod use `--namespace <ns>` + `--name-pattern '^<pod>$'`
     and NO `--pod-label`. Resolve names from live state (Lease holder, `oc get pod`) at arm time.
   - parameters (fill %, duration, timeouts), expected failure signature, blast radius, and the
     cleanup obligation if any (HPP `kraken.tmp`),
   - what the make pipeline will report in both cases (fail-expected vs survive-expected).

Do not proceed to Step 4 without approval.

## Step 4 — Test the injection (precheck)

Instantiate `templates/precheck.sh.tpl` and run it (read-only):
- collision guard for the new RUN_ID (cluster objects + local run dirs + evidence dir),
- trigger-command parse validation against live objects (both negative cases: terminal-state
  backup and missing backup must each yield rc≠0; only the live in-window state yields 0) —
  a parse error is indistinguishable from "not satisfied" in krknctl logs (the r02/r05
  learning; this check is mandatory),
- sizing echo (floor vs artifact).
- **post-arm round-trip** (in the injector script, not the precheck): after `krknctl` starts,
  read the `[0] command trigger:` line from its log, strip the leading `[0] command trigger: '`
  and everything from `' (expected rc=` on (the line ends with an ANSI reset — a plain `$`
  anchor fails, r03), and diff against the intended text. Abort the injector on mismatch.
  `templates/precheck.sh.tpl` has a no-backslash assert; `templates/inject-roundtrip.sh.tpl`
  has the guard.
- **trigger liveness**: note the expected window (control timestamps). If the trigger has not
  fired by window end + 30 s, stop and report — never wait out the 1800 s budget (r01/r02
  silently burned full setup + backup cycles).

Run a bounded live probe (e.g. scratch-PVC fill) **only** when the backend or mechanism is
unproven — both ODF and HPP pvc-fill mechanics are already measured (see appendix). Never probe
on a shared HPP pool without accounting for the temporary usage.

## Step 5 — Execute

Two execution shapes; pick the one the scenario needs:

**A. Staged (preferred, and required whenever the injector needs facts that only
exist after setup — launcher pod name, node, labels, pre-chaos uid):** run
`make vm-setup NAME=<RUN_ID>` first, then resolve the facts the krknctl command
needs — launcher pod name (`oc get pod -n <ns> -l vm.kubevirt.io/name=vm-<RUN_ID>`),
its node (`spec.nodeName`), labels, and capture the pre-chaos `.metadata.uid`
(the restart detector). Target krknctl by `--pod-name <launcher>` instead of a
label selector. Then arm, then run only the needed stage (`make vm-backup
RUN_ID=<RUN_ID>`, `make vm-cbt-backup RUN_ID=<RUN_ID>`, `make vm-cbt-verify …`) —
never a full `make e2e` when one stage is the target.

**B. Single-shot (only when the trigger fully gates timing and the injector needs
no setup-time facts):** arm the injector, then `make e2e TYPE=<stage>
NAME=<RUN_ID>` runs setup + stage in one invocation; the trigger absorbs setup
time.

Session layout (staged runs) — keep commands in independent sessions for
simplicity, not because of any lock:

- **Session 1 — pipeline:** all `make` commands (`vm-setup`, then later
  `vm-backup`/`vm-cbt-backup`/`vm-cbt-verify`), sequentially in one terminal.
- **Session 2 — injector:** the krknctl command with its `--trigger-command`,
armed (started) before session 1 runs the mutating stage, run in the FOREGROUND
so trigger polling and fault application are watched live (`tee` to the evidence
log). The trigger absorbs setup/image-pull latency, so arming right after
`vm-setup` completes is fine — it just polls until the backup stage creates the
target window.
- Optional session 3 — read-only watch: `scripts/monitor.sh <vm-name>` or
  `scripts/backup-state-watch.sh <run-id> <CHECKPOINT>`.

Only session 1 takes the checkout lock (`state/e2e.lock`); the injector session
takes no lock and must never drive a mutating stage. The single-session
alternative (one script, `nohup` injector + make + bounded join:
`templates/run.sh.tpl`) remains the default for scripted/agent runs.

Then, either layout:
1. Arm the injector **before** the mutating `make` stage — the trigger absorbs
   setup/image-pull latency (krknctl pull+init measured ~13s) and fires only inside the
   target window.
2. Run the stage (Windows: add `GUEST_EXEC_POLL_ATTEMPTS=450`; use the profile's proven
   GUEST_* values).
3. Bounded join of the injector; record both exit codes.
4. Injector exit-code interpretation: krknctl rc=1 after a confirmed fill is **expected** when
   the target pod is gone at cleanup time (r06 learning) — it is not a chaos failure.
   Second rc=1 case: the killed pod's ReplicaSet replacement has a *different name* and krkn
   reports `Pods Unrecovered: 1` / "timeout while waiting for pods to come up" although the
   replacement is Ready (CBT-F-13 r05: Ready in 22 s). Check the replacement's Ready condition
   yourself; this is a krkn tracking artifact, not a product failure.
5. A fired trigger is not proof of the target: confirm from the krknctl log which object was
   deleted/filtered (`Force deleting pod <name>`) and compare with the pre-chaos leader/target.
   If it is the wrong object, the run is invalid for the scenario (record it, do not grade it).

**Injection-phase signals are observable object fields, not guesses** (learning: a
spec-guessed window can turn out empty or shorter than injector latency). Proven mappings on
the vmbackup object:
- backup startup / pre-copy = condition `Initializing=True` (reason "backup target PVC … is
  being attached to VMI"); window ~11s on rhel9/large-odf — poll interval 1s catches it.
- copy in progress = `Progressing=True, Done≠True`.
- terminal = `Done=True` (reason carries success/failure).
Use the scenario's named phase; if the spec's phase has no such field, measure the window with
`scripts/backup-state-watch.sh <run-id>` (or monitor.sh) on a control run before committing to
a trigger. `backup-state-watch.sh <run-id> <CHECKPOINT>` exits 0 the moment a checkpoint fires
and is the tool for confirming a phase is reachable at all.

**Lifecycle-shape trap (generic):** `vm-cbt-restore-test`/`vm-cbt-verify` refuse to
validate a full-only restore while the run *plans* incremental passes (manifest validator
requires `incrementals.length == incremental_passes_total` outside recovery mode). If the
scenario needs a full-only restore verdict, either set `GUEST_INCREMENTAL_PASSES` to the
minimum the spec needs before `make vm-setup`, or complete the planned passes **without
chaos** after the chaos window is terminal (lifecycle completion, not part of the chaos
verdict — say so in the report).

**Verify removal, not just application:** an "applied" claim needs a counterpart probe after
the duration — e.g. `curl` from inside the launcher for network filters, df for fills. krknctl
rc=0 alone is not removal evidence.

## Step 6 — Verify (use the pipeline's own validation)

The make stages already wait for Done, parse the reason, refuse the checkpoint on a
failure-reason, and write honest state. Interpret:

| expected outcome | pipeline evidence | verdict |
|---|---|---|
| fail-expected | e2e exit 2 · stage line `reached Done=True but the backup actually failed: <signature>` · `run.json` status `<stage>_failed` · checkpoint NOT recorded | chaos worked iff the reason contains the scenario's signature |
| survive-expected | e2e PASS · Done=True success reason · checkpoint recorded | resilient iff data checks also pass |

Add the scenario's own spot checks (from its spec's measurements section). Common ones:
tracker `latestCheckpoint` null after a failed full; no usable partial image on the destination
(only `kraken.tmp`); VM still Running / CBT Enabled / agent connected. Capture injector evidence
(krknctl.log fill lines: requested/actual/utilization, trigger timing) and timing vs the control.
Classify per the spec (RESILIENT / DEFECT) — never from exit codes alone.

Recovery (`make e2e TYPE=recover` for `full_failed`; reconcile→retry for `incremental_failed`)
only when the user asks.

## Step 7 — Report

Write `cbt-chaos/scenarios_v2/<ID>/runs/<RUN_ID>/run-report.md` from
`templates/run-report.md.tpl`, filling: injection timeline (from injector log + launcher logs),
product checks vs the scenario's criteria, findings, preserved state, evidence file list.
Keep evidence in that directory (repo convention for v2 outputs); never archive/move it.
After execution, `rsync` the run's evidence back from cloud05
(`rsync -a cloud05:/root/v2/virt-cbt-lab/cbt-chaos/scenarios_v2/<ID>/runs/ <local>/runs/`) so
the local checkout holds the report and evidence together.
When earlier attempts were invalid, include an **Attempt history** table (run → outcome →
cause) at the top of the report, and a **scope caveat** in Classification stating which
interleavings the run did NOT exercise (e.g. kill landed before the copy finished).

## Appendix — measured constants & learnings (live-proven 2026-11-10/11)

| item | value |
|---|---|
| krkn pvc fill semantics | `file size = capacity×pct/100 − used` (df-based, self-adjusting); pct must exceed current utilization; range 1–99 |
| Fill rate RBD | ~44–50GiB/s (57.2GiB in 1.3s; 85GiB in 1.7s) — no timing risk after trigger |
| Trigger→fill lag | ~0.75–1.5s; utilization overshoots target by the backup's concurrent writes |
| ODF sizing | dedicated dest (70–90Gi): pct 95 → floor ~3.5–4.5GiB vs ~60–78GiB artifact |
| HPP sizing | shared pool (df = node disk): pct 99 → floor ~15GiB; 95 is INVALID (backup succeeds) |
| Timeout budgets | Linux 1800s; Windows 3600s (OOBE ~20 min) |
| Windows knobs | `GUEST_EXEC_POLL_ATTEMPTS=450`; 1000 files/pass on 60Gi ODF root, 200/pass on 40Gi HPP root |
| r02/r05 | trigger parse errors are invisible in krknctl logs → precheck parse validation mandatory |
| r06 | krknctl rc=1 on post-duration cleanup when the attachment pod is gone — expected |
| WFFC trap | a pod pinned with `spec.nodeName` never triggers WaitForFirstConsumer binding — use `nodeSelector` (scheduler must run) |
| Windows guest-exec | inline `-Command` > 32,767 chars fails at spawn (PR #40 ships scripts as guest files) — do not work around via file counts |
| HPP leftover | failed backup deletes the attachment pod → krkn cleanup fails → `kraken.tmp` (up to ~pool-size) lingers on the SHARED pool; remove after evidence capture on HPP, preserve as evidence on ODF (contained) |
| Backup-startup (Initializing) window | vmbackup `Initializing=True`; ~11s on rhel9/large-odf; injector helper deploy ~40s after trigger — the fault may land slightly into the copy, an acceptable superset for startup-phase scenarios |
| pod-network-filter mechanics | krkn helper pod nsenters the target pod's netns on its node; N ports × tcp/udp × in/out rules apply serially (~30s for 88); `--ports` cannot express "all" (CLI validator) — a broad documented port list is the compromise |
| Full-only restore gating | restore-verify refuses full-only validation while incremental passes are planned — complete passes without chaos, or set `GUEST_INCREMENTAL_PASSES` before vm-setup |
| Removal proof | post-duration probe from inside the launcher (curl for network filters, df for fills) — rc=0 is not removal evidence |
| pod-scenarios targeting | `--pod-label` overrides `--name-pattern`; to kill one named pod use namespace + name-pattern only (CBT-F-13 r04 deleted the standby) |
| krkn trigger escaping | backslashes in `--trigger-command` are collapsed; jq/grep escapes silently break (CBT-F-13 r02) — slice instead of regex-escape |
| pod-scenarios latency | trigger → `Force deleting pod` ≈ 7 s (pod selection); `--force true` = grace period 0 |
| virt-controller failover | killed leader's replacement pod can win the Lease over the standby; Lease gap ≈ 15–17 s; replacement Ready ≈ 22 s |
| vmbackup copy→Done window | launcher `Backup has been completed successfully`, Done=True, `hp-volume-*` delete, unmount and `HotplugFailed` all land in the same second (sub-second) — offset-trigger from `Backup started` instead; rhel9/large-odf full copy ≈ 64–67 s, full backup 67–84 s |
| controller reconcile repeats | new leader logs ~6× `Successfully updated BackupTracker` / `performing cleanup` within 0.1 s for every completed backup (also without chaos) — idempotent, not a duplicate checkpoint |

Reference runs: `runs/20261111-cbtf08rh-r01/` (rhel9/ODF, all criteria PASS),
`runs/20261111-cbtf08win-r01/` (windows/ODF, all criteria PASS + recovery PASS),
`runs/20261111-cbtf11-r01/` (CBT-F-11 pod-network-filter during BACKUP_INITIALIZING, 90s —
RESILIENT, all criteria PASS; staged execution + Initializing trigger proven),
`runs/20261111-win-measure/evidence/storage-measurements.md` (HPP characterization + fill probe).
`runs/20261112-cbtf13-r05/` (CBT-F-13 virt-controller leader kill, offset trigger 50 s after
copy start — RESILIENT; r01–r04 are the documented failed attempts).
