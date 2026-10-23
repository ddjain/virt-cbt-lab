---
name: cbt-chaos-team
description: >
  Orchestrate a team of subagents for a CBT Chaos scenario run: one Lead agent
  that manages the run, plans and starts short-lived Workers, keeps the
  per-run state files, and reconciles the verdict; blind Checkers that
  independently pass or reject injection validity, evidence sufficiency, and
  report fidelity; and post-run Analyst/Improver agents that propose scenario,
  harness, and CBT-product improvements plus a bounded re-run matrix. Delegates
  the live run protocol (phases, safety, evidence rules) to the cbt-chaos-run
  skill; this skill adds the team topology, role contracts, and per-run state
  file schema. Use for planning or executing an agentic team chaos run.
user_invocable: true
arguments:
  - name: request
    description: >
      Scenario ID or directory plus intent, e.g. "run CBT-V3-01 with the agent
      team" or "plan a team campaign for cbt-01". For execution, the scenario
      must already have a validated spec and trigger per cbt-chaos-issue-triage.
    required: true
---

# CBT Chaos Team Orchestration

Run one CBT chaos scenario with an agent team instead of a single agent. The
Lead is the only agent that mutates anything; Workers each do one job; blind
Checkers gate the verdict; post-run agents improve the scenario, harness, and
skills between runs. All live-run safety, evidence, and reporting rules come
from the `cbt-chaos-run` skill — read it first; this skill only defines the
team layer on top. Never run `make clean-all`.

Each role has its own skill. The Lead reads `cbt-chaos-team` (this file) and
`cbt-chaos-run`; when spawning an agent, it embeds or references that role's
skill in the spawn contract so the worker loads exactly its own protocol:

| Role skill | Spawned as |
|---|---|
| `cbt-chaos-preflight-worker` | Preflight Worker |
| `cbt-chaos-observer-worker` | Observer Worker |
| `cbt-chaos-trigger-worker` | Trigger Worker |
| `cbt-chaos-recovery-worker` | Recovery Worker |
| `cbt-chaos-report-writer` | Report Writer |
| `cbt-chaos-krkn-preparer` | Krkn Command Preparer (design-time: triage + improvement) |
| `cbt-chaos-injection-checker` | Injection Validity Checker |
| `cbt-chaos-evidence-checker` | Evidence Sufficiency Checker |
| `cbt-chaos-report-checker` | Report Fidelity Checker |
| `cbt-chaos-run-analyst` | Run Analyst |
| `cbt-chaos-scenario-improver` | Scenario Improver |
| `cbt-chaos-flow-analyst` | CBT Flow Analyst |
| `cbt-chaos-variation-decider` | Variation Decider |

## Team roles and authority

| Role | Lifespan | One job | Authority |
|---|---|---|---|
| Lead | whole run | sequencing, run ledger, verdict reconciliation | sole mutator; cannot self-grade |
| Preflight Worker | minutes | spec↔trigger↔cluster GO/NO-GO | GO/NO-GO only |
| Observer Worker | whole run | read-only watches, ARMED/PRESERVED/FINAL handoffs, bounded analysis | none |
| Trigger Worker | injection window | execute verified trigger, preserve exit codes | none; gated on watch health |
| Recovery Worker | post-PRESERVED | same-VM recovery backup + restore checks | lead-authorized per action |
| Report Writer | post-verdict | fill both report templates from evidence pack | none |
| Krkn Command Preparer | design-time (triage/improvement) | disruption intent → validated krknctl argv + dry-run evidence, or justified oc/kubectl fallback | propose only; never executes live |
| Injection Validity Checker | post-terminal | correct window, exact target UID, independent effect proof | PASS/REJECT |
| Evidence Sufficiency Checker | post-terminal | every criterion has run-scoped proof; hunt false positives | PASS/REJECT |
| Report Fidelity Checker | pre-delivery | standalone, observed-facts-only, no harness leaks | PASS/REJECT |
| Run Analyst | post-run | timeline, criterion table, product vs harness | analysis only |
| Scenario Improver | post-run | weaknesses in spec/trigger → diffs + harness tickets | propose only |
| CBT Flow Analyst | post-run | weaknesses in CBT product → engineering-ticket drafts | propose only |
| Variation Decider | post-run | bounded re-run matrix proposal | propose only |

Rules that bind every role:

- The Lead cannot assign itself a checker's job, and checkers never receive
  the Lead's tentative verdict, worker narratives, or analyst conclusions —
  only run-scoped artifacts and the spec/issue files.
- Exactly one Observer per run. If its handle seems stale, investigate the
  handle; never spawn a duplicate observer or second live watcher.
- Workers and Checkers receive a written task contract (file under the run's
  `contracts/` directory) naming exactly which paths they may read and which
  single file they own. Reading outside the contract is a harness finding.
- Run isolation per `cbt-chaos-run`: no agent reads other runs' artifacts,
  history, or reports during a live run. Post-run agents may read the current
  run's closed artifacts only, never a live run's.

## Lead operating policy (stage-aware, deterministic-first)

The Lead owns stage selection and mutation authority, so the plan-then-run
policy belongs here rather than in each role:

- **Interface.** Read `make help` (human-readable) and `make stage-list` (the
  machine-readable stage/target/args/purpose table), and consult
  `docs/agent-workflow-audit.md` — the shared capability matrix (inputs,
  outputs, exit codes, read-only vs mutating, retries/timeouts, and what each
  entry point proves and does *not* prove). Never assume a variable is honoured
  merely because Make accepts it, and confirm the staged interface exists in
  the active checkout before relying on it.
- **Smallest valid stage per leg.** Prefer the narrowest stage that answers the
  current hypothesis (`vm-backup`, `vm-cbt-backup`, `vm-cbt-verify`,
  `vm-cbt-restore-test`, `monitor`, `run-summary`) over a full
  `make e2e`/`TYPE=all` rerun. Stages are state-machine transitions, not freely
  re-runnable commands: check `runs/<id>/run.json` state before choosing one,
  and treat a rejection as a state error rather than a product failure. A full
  fresh lifecycle is correct only when the scenario's own acceptance criteria
  demand it (for example the separate clean restore lifecycle in CBT-F-01).
- **Deterministic first.** Reuse the existing script or Make target for every
  repeated operational check; spawn a role only for judgement the scripts
  cannot express. `cbt-chaos/scenario-verdict.sh` (see `cbt-chaos-run`)
  computes the objective verdict from recorded artifacts and exits non-zero
  unless every mandatory check passed: checkers grade the evidence, the
  evaluator computes the outcome, and neither replaces the other. A script
  `PASS` carrying an `UNKNOWN` check is at most PASS WITH FINDINGS; a script
  `FAIL`/`INCONCLUSIVE`/`BLOCKED`/`INVALID` is reported as returned.
- **Reuse before you build.** Inspect the script, Make target, test, and
  `docs/agent-workflow-audit.md` row before adding anything: a new script is
  justified only by an assertion none of them makes. It needs an offline test
  under `tests/` wired into `make test`, an audit-matrix row, and a skill
  reference in the same change, and `make test` must pass after any script,
  Makefile, or skill edit — an edit to what the flow executes is not verified
  by inspection alone (see `cbt-chaos-run`'s deterministic-tools policy).
- **Spawn economy.** One Observer per run (below); the three Checkers are the
  only judgement agents; never spawn an agent to perform what a documented
  script or Make target already does, and never spawn a worker per
  verification step. The Report Writer assembles its output from the evaluator
  JSON, the evidence pack and the templates — it does not re-derive results
  from prose.
- **Timings are evidence.** Record each leg's duration
  (`cbt-chaos/scenarios_v2/<id>/runs/<RUN_ID>/driver-timings.json`,
  `run.json .stage_timings`, `summary.json .phases`) and attribute the run's
  wall clock per phase at closeout.
- **Rehearse before syncing.** After any trigger edit, and before the single
  `make resync` of the run: `bash -n`, confirm every variable the action
  command references is still defined, and run `bash <trigger> --plan`.
- **Never bypass the guards.** No `make clean-all`, and never
  `STAGE_SKIP_PREFLIGHT=true`: preflight is the fail-closed identity/resource
  gate for every mutating stage.
- **Bounded work.** Every spawned task carries a wall-clock budget, an attempt
  cap and a terminal status (`COMPLETED`, `FAILED`, `TIMED_OUT`, `BLOCKED`);
  the heartbeat audit and the matrix stop conditions are the enforcement
  points.

## Per-run state files (single source of truth)

Every run has one root: the scenario's `runs/<RUN_ID>/` directory on the
remote checkout (pulled locally via `make pull-reports` plus targeted rsync of
the scenario folder). **Chat messages are notifications; files are truth.** A
handoff, decision, or verdict exists only when its file exists and its ledger
entry is appended.

```
runs/<RUN_ID>/
  ledger.jsonl            append-only event log; Lead is the ONLY writer
  state.json              phase machine; Lead is the ONLY writer
  contracts/              one immutable task contract per agent (Lead writes
                          before spawning; never edited after acceptance)
    preflight.md observer.md trigger.md recovery.md report-writer.md
    check-injection.md check-evidence.md check-report.md
  observer/               Observer-owned
    ARMED  PRESERVED  FINAL    handoff marker + JSON payload each
    watches/                        raw watch streams, never into model context
    finding.md                      compact final analysis
  trigger/
    command.txt  trigger.log  action-request.json
    effect-check.json  exit-statuses.json      Trigger-owned
  recovery/                Recovery-owned logs and backup/restore evidence
  checkers/                one JSON verdict per checker (each checker-owned)
    injection-validity.json  evidence-sufficiency.json  report-fidelity.json
  reports/                 Report Writer-owned
    test-run-result.md  test-run-report.md
  evidence-index.json      Lead-owned manifest of evidence files + sha256
```

### Lead context management (restart-on-rehydrate)

The Lead's context grows quadratically with turns; long runs and multi-leg
matrices must not accumulate chat history across phases. The Lead restarts
with a fresh context:

- **Between matrix legs** — always. A leg's Lead rehydrates exclusively from
  `runs/<RUN_ID>/ledger.jsonl`, `state.json`, `contracts/`, and
  `evidence-index.json`; nothing load-bearing may live only in chat.
- **Within a run** — at phase boundaries (`final → checked`, `reported →
  closed`) if the Lead's context is visibly degrading (re-reading files it
  already read, losing track of contract names). Restart is safe precisely
  because files are truth; if a restart would lose information, that
  information was wrongly kept in chat — record it in the ledger first,
  then restart.
- A restart appends a `lead_restarted` ledger event with the rehydration
  source paths; no other agent observes the restart.

### Heartbeat audit

During `executing`, `recovering`, and any phase expected to exceed 10
minutes, the Lead (or a mechanical ticker acting for it) probes liveness
every 10 minutes **from disk and API, never from agent self-report**:

- Observer: each recorded `watch_pid` still alive (`kill -0`), ready files
  present, watch stderr not growing with auth errors.
- Trigger/Recovery processes: exit statuses recorded or process still
  running; a process exceeding its expected window without terminal state
  is classified stalled, not assumed working.
- Phase progress: the expected next artifact (handoff marker, log growth,
  state.json transition) has appeared since the last tick.

On a failed probe the Lead does not immediately kill anything: it
investigates the handle/process, and classifies the phase stalled (BLOCKED
candidate) if it cannot be confirmed live. The heartbeat writes compact
probe results to the ledger (`heartbeat` events); it never spawns a second
observer to "check on" the first.

### Reject verification

A checker REJECT is not automatically final. Before finalizing BLOCKED on a
REJECT, the Lead verifies the reject's cited evidence itself,
artifact-by-artifact, with the same skepticism the adversarial
completeness review applies to a PASS: does each cited file exist, match
`evidence-index.json`, and actually support the claimed defect? A wrong
reject costs a full redo; a verified reject proceeds to BLOCKED. A reject
whose citations do not hold is a harness finding (checker defect) and the
checker is re-run once with the corrected inputs — the run is never passed
on the basis of an overturned reject alone.

### Checker model independence

Checkers must not share blind spots with the workers they grade:

- Checkers always run on a model at least as capable as the workers whose
  output they grade; never economize on checker models (they are the
  cheapest agents by token share).
- Where the harness supports model selection, checkers should run on a
  **different model** than the workers they grade; when only one model is
  available, state the shared-blind-spot limitation in the run ledger and
  rely on the blindness-by-path contract as the compensating control.
- Mechanical roles that do not judge (raw-stream supervision, template
  filling) may use a low-reasoning model; judgment roles (Lead, checkers,
  analysts) may not.

### Ownership and write rules

1. **Single writer per file.** The owning role is fixed by the schema above.
   The Lead writes `ledger.jsonl`, `state.json`, `contracts/`, and
   `evidence-index.json`; nothing else writes those. A worker writing outside
   its owned files is a harness failure and the run is BLOCKED.
2. **Append-only ledger.** Every event is one JSON line:
   `{"utc": "...", "actor": "lead|observer|...", "event": "...",
   "phase": "...", "refs": ["path", ...]}`. Events include: run resolved,
   contract issued, GO/NO-GO, ARMED/PRESERVED/FINAL received (with payload
   path), action requested, phase transitions, checker verdicts, verdict
   reconciliation, human-gate approvals, run closed. Never rewrite or delete
   ledger lines; a correction is a new line referencing the old one.
   Append events through `cbt-chaos/ledger-append.sh` (jq-escaped, validated
   before commit) — hand-written `printf` lines produced invalid JSON in run
   20261015-cbtf04-r03 (line 8) and cost a checker flag.
2a. **Index ordering (mechanical, checker-enforced).** The evidence index is
   valid only if it is the LAST evidence write OF THE PHASE: append every ledger
   line for that phase FIRST, then regenerate `evidence-index.json`, then freeze
   it, then write nothing further to any indexed file until every checker of
   that phase has returned. Exactly this sequence, immediately before the
   checker spawn (`<run-root>` = the run directory):
   `cbt-chaos/evidence-index.sh <run-root> && cbt-chaos/pack-validate.sh --freeze <run-root>`.
   `--freeze` validates (ledger JSON validity, state/ledger phase agreement,
   indexed sha256s, index-vs-file mtimes) and records the index/ledger sha256 in
   `checkers/pack-freeze.json`, so a ledger append after the index becomes
   detectable instead of merely discouraged.
   Each checker runs `cbt-chaos/pack-validate.sh --verify-freeze <run-root>` as
   its FIRST action and again immediately before writing its verdict, and
   records both exit codes plus `pack-freeze.json#index_sha256` in its output.
   A closing failure means the pack moved under the grade: re-freeze, re-spawn
   that checker, and record the re-run as a harness finding.
   Rationale: post-index ledger appends cost a reject in 20261015-cbtf04-r03
   and reappeared as a measured 23171-vs-27415-byte index drift in
   20261016-exp06-r02, where the run carried no gate that could have caught it.
2b. **Run-root sync (mechanical).** A run root is never PUSHED from the
   workstation: `sync.sh` already excludes `cbt-chaos/scenarios_v2/*/runs/`, so
   any bare `rsync` of a run root is a defect — the r02 in-run push truncated
   `ledger.jsonl` and six events had to be re-appended (recorded as
   `ledger_recovered` in `ledger.jsonl`), and the post-close mirror is stale
   again (workstation 37 ledger lines + the 151-file pre-checker index vs the
   remote's 42 lines + the 157-file index). After `closed`: `make pull-reports`
   (remote → local, one direction only), then run
   `cbt-chaos/pack-validate.sh <pulled run-root>` and require exit 0. If it
   fails, the mirror is not evidence — re-pull it; never re-push over it.
3. **Phase machine in `state.json`.** Allowed transitions, nothing else:
   `resolved → preflight_go → armed → executing → preserved → recovering →
   final → checked → verdict → reported → closed`. `closed` is the firewall
   boundary: post-run agents run only after `closed`, and their outputs go to
   the campaign level (`scenario/analysis/<RUN_ID>.md`, bug drafts,
   matrix-proposal.md) — never back into the run directory.
4. **Immutability after phase close.** When a phase transitions, the Lead
   records sha256 of the files that phase produced into `evidence-index.json`.
   Checkers must REJECT any evidence file whose checksum does not match the
   index or that is absent from it. Raw evidence (watches, logs, snapshots) is
   write-once during the run.
5. **Handoffs are files.** `observer/ARMED` etc. each contain a JSON payload
   (UTC time, watch PIDs, selectors, target identity checks) plus their ledger
   entry. The Lead still independently verifies watch health (`kill -0` on
   recorded PIDs, ready files) per `cbt-chaos-run` before accepting ARMED.
6. **Blindness is enforced by contract paths.** Checker contracts list exactly
   `checkers/`-external inputs: spec/jira files, `observer/`, `trigger/`,
   `recovery/`, `evidence-index.json`, and the report drafts (report-fidelity
   checker only). They never receive `contracts/` of other agents, worker
   chat, or the Lead's reasoning.
7. **Cross-run isolation.** All contracts scope reads to `runs/<RUN_ID>/` and
   the scenario's spec/issue files. The Lead rejects any agent request to read
   another run directory, historical reports, or the learnings file during a
   live run (learnings are read at planning closeout only, per
   `cbt-chaos-run`).

## Execution sequence (Lead checklist)

1. Resolve scenario, `RUN_ID`, lifecycle `NAME`/`VM` per `cbt-chaos-run`
   Phase 0; read `make help` and `make stage-list` and select the smallest
   valid stage for the leg; create run root, `ledger.jsonl`, initial
   `state.json` (`resolved`).
2. Issue `contracts/preflight.md`, spawn Preflight Worker → GO/NO-GO.
   Capacity preflight is mandatory: destination PVC headroom must fit the
   planned full AND follow-up incremental (prior starvation incident).
3. On GO: run the trigger's `--plan` rehearsal (and the variable-definition
   check after any edit), then `make resync` (the only sync of the run), issue
   observer and trigger contracts, spawn Observer Worker. Accept ARMED only
   after independent watch-health verification; transition `armed`.
4. Spawn Trigger Worker; transition `executing`. Wait for PRESERVED before
   any recovery; transition `preserved`. Heartbeat audit is active during
   `executing`, `recovering`, and any phase expected to exceed 10 minutes.
5. Issue recovery contract; spawn Recovery Worker (lead-authorized actions);
   transition `recovering`. Wait for FINAL; transition `final`.
6. Spawn the three Checkers in parallel (blind contracts). On all verdicts,
   Before spawning: `cbt-chaos/evidence-index.sh <run-root>` then
   `cbt-chaos/pack-validate.sh --freeze <run-root>`; no ledger append until all
   three have returned. A checker whose closing `--verify-freeze` fails has
   graded a moved pack — re-freeze and re-spawn it (harness finding, not a
   product finding).
   apply reject verification to any REJECT (see Reject verification), then
   reconcile against lifecycle records and API evidence per `cbt-chaos-run`
   Phase 4; assign PASS / PASS WITH FINDINGS / FAIL / BLOCKED; transition
   `checked` → `verdict`. Any verified checker REJECT on injection or
   evidence forces BLOCKED, never a downgraded PASS.
   Run `cbt-chaos/scenario-verdict.sh` for the run's objective verdict and
   reconcile it with the checker verdicts: the script verdict is the objective
   core (a non-PASS verdict is never upgraded by prose, and a PASS carrying an
   `UNKNOWN` check is at most PASS WITH FINDINGS), while a disagreement
   between the script and the checkers is itself a harness finding to resolve
   before a verdict is assigned. Record the script's JSON path in the ledger.
7. Spawn Report Writer (assembling from the evaluator JSON, the evidence pack
   and the templates, not re-derived prose); spawn Report Fidelity Checker
   (max 2 revision loops, then stop for human). Rsync reports both ways,
   `make pull-reports`; transition `reported` → `closed`.
8. Post-run (firewall lifted): spawn Run Analyst, Scenario Improver, CBT Flow
   Analyst, Variation Decider in one parallel batch, each with the closed
   run's artifacts. Outputs to scenario-level files, not the run directory.
9. Learning closeout per `cbt-chaos-run`: dedupe candidate lessons against
   the canonical learnings file; every lesson must cite a run artifact.
   Append every checker reject reason (self-contained, as written by the
   checker) to the scenario-level `reject-reasons.tsv` — one line per
   reject: run ID, checker, failure class, citation. Apply the twice-rule
   (see Repeat-failure escalation). Propose skill/spec diffs and wait for
   human approval. Present the Variation Decider's next matrix leg for
   approval before queuing it.

### Repeat-failure escalation (twice-rule)

A failure class seen once is a run anomaly; seen twice it is a skill or
spec defect that must be resolved, not re-observed:

- The scenario-level `reject-reasons.tsv` (written only after `closed`, so
  run isolation holds) is the cross-run failure index: columns are
  `run_id`, `checker`, `failure_class`, `citation`.
- At learning closeout, the Lead groups the current run's rejects into
  failure classes and counts prior occurrences in the index.
- **A failure class appearing in ≥2 runs makes the corresponding skill/spec
  edit mandatory**: the Scenario Improver must produce the exact diff, and
  the human either approves it or explicitly declines it with a reason
  recorded in the ledger. Silent skip is not an option.
- Failure classes come from the checkers' reject_reasons as written — the
  Lead does not reclassify rejects into more convenient classes, and an
  overturned reject (per Reject verification) is not recorded in the index
  as a failure of the graded unit.

Between matrix legs, the Lead restarts with a fresh context and rehydrates
from state files only (see Lead context management).

## Auto-chain matrix (Variation Decider)

- Proposes at most 4 sequential legs per approved matrix: dimensions are
  backup mode (Full/Incremental), injection window position, storage backend,
  workload sizing, OS.
- Hard stop conditions (Lead must stop and ask): any FAIL verdict, 2
  consecutive BLOCKED, same-VM recovery failure, cluster degradation (ODF not
  healthy, controller not at ready replicas), capacity starvation.
- A leg requiring `backup-reset`, backup-object deletion, or the CBT-V3-11
  cleanup gate stops for human approval before mutating.

## Approval tiers

Not all improver proposals require a human:

- **Trigger script edits (harness code) — approved by the Lead**, not the
  human. The Lead applies a trigger-hardening diff between runs only
  (never mid-run: an edit between validation and execution would break the
  checksum chain that guarantees the executed artifact is the validated
  artifact). Before approving, the Lead must itself verify the diff: it
  passes `bash -n`, preserves the exact one-workflow/one-action contract,
  and — after application — the trigger's `--plan` rehearsal and checksum
  are re-recorded. A Lead-approved trigger edit is recorded in the ledger
  with the diff, the verification results, and the new sha256. Mechanical
  gates (preflight rehearsal, checksum, Krkn dry-run) re-validate every
  approved trigger before the next run fires it, which is what makes
  Lead-level approval safe for this artifact class.
- **Spec edits, SKILL.md edits, and any rule governing behavior or
  judgment — human gate, never bypassed.** These change what the team
  accepts as truth; no downstream mechanical gate re-validates them.
- **Live-mutation approvals** beyond the exact approved run, `backup-reset`,
  and any cleanup gate — human.
- **The next matrix leg** after the first approved leg sequence, or any
  stop condition hit — human.

## Findings separation

Product findings (CBT behavior) go in the reports and bug drafts per
`cbt-chaos-run`. Harness findings (worker/observer/checker/state-file defects,
contract violations, missed handoffs) go in the final chat under
**Harness findings (not a CBT product finding)** and, when actionable, the
Scenario Improver's harness-ticket draft. Ledger or state-file inconsistencies
are always harness findings, never product verdicts.
