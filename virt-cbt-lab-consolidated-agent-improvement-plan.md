# Updated Agent Improvement Plan for `virt-cbt-lab`

**Revision:** 2026-10-16  
**Status:** Proposed; audit the actual skill/delegation chain before implementation.

## 1. Executive recommendation

The harness has changed: E2E work can now be split into individual Make targets, and `make help` documents the supported workflow. The agent plan must take advantage of that instead of treating every experiment as a fresh, monolithic E2E run.

**Recommended design:** keep `chaos test team` as the single lead/controller; use Make targets and existing scripts for predictable stages and objective checks; retain one focused lifecycle monitor where independent observation is needed; invoke autonomous investigation only for unexpected evidence or meaningful coverage gaps.

The lead should not spawn an agent for every skill or verification step. A skill is reusable procedural knowledge, not necessarily a separate agent process.

This follows the practical distinction in Anthropic's guidance: predefined workflows suit well-defined tasks; autonomous agents are useful when the next action depends on uncertain evidence. Add complexity only when it demonstrably improves outcomes. See [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) and [Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents).

## 2. Current harness capabilities to use

The current repository README, `AGENTS.md`, and `Makefile` describe a staged lifecycle, stage dispatch, run-scoped artifacts, and individual targets. The implementation agent must verify these against the current checkout with `make help` and `make stage-list` before changing anything.

### First actions for every coding/agent run

```bash
make help
make stage-list
```

Use `make stage-list` as the machine-readable source for available stage names, Make targets, arguments, and purpose. Use `make help` for human-readable commands and constraints. Do not hard-code assumptions about the older E2E interface.

### Relevant Make targets

| Purpose | Preferred command shape | Agent policy |
|---|---|---|
| Readiness | `make preflight` | Run before starting; never install tools or mutate the cluster during preflight. |
| Create VM and baseline workload | `make vm-setup RUN_ID=<id>` | Use once per experiment lifecycle unless the scenario explicitly requires a new VM. |
| Full backup | `make vm-backup RUN_ID=<id>` | Run only when the hypothesis needs a full-backup stage. |
| Incremental backup / workload mutation | `make vm-cbt-backup RUN_ID=<id>` | Prefer for a single incremental stage; do not rerun the entire E2E by default. |
| Extend a completed chain | `make vm-cbt-extend RUN_ID=<id> EXTEND_TO_PASS=<n>` | Use only when the intended lifecycle requires one additional pass and the target is valid. |
| Recover failed full backup | `make vm-cbt-recover RUN_ID=<id>` | Use only for the documented same-VM recovery condition; preserve failed artifacts. |
| Verify checkpoint chain | `make vm-cbt-verify RUN_ID=<id>` | Deterministic verification; use after relevant stages and when evidence needs rechecking. |
| Verify restored data | `make vm-cbt-restore-test RUN_ID=<id>` | Use when restore/data-integrity is part of the claim; don't infer correctness from backup status alone. |
| Lifecycle timings | `make monitor RUN_ID=<id>` | Run as a separate observer when timing/injection correlation matters; capture actual timestamps. |
| Summary and verdict | `make run-summary RUN_ID=<id>` | Use the structured run summary instead of manually rebuilding the report. |
| Inspect current fleet | `make density-status [POOL=<pool>]` | Read-only; use for existing density-pool state when relevant. |
| Dry-run dispatch | `STAGE_DRY_RUN=true make <stage> ...` | Use to validate target/identity/command resolution without contacting the cluster. |
| Offline regression tests | `make test` | Run after relevant harness/script/skill changes. |

The current Makefile also documents staged `make e2e TYPE=full|incremental|recover|extend|reconcile|verify` paths and `make e2e-incremental`. Prefer the narrow direct stage target when it expresses the desired action clearly; use the `e2e TYPE=...` interface when its lifecycle semantics are needed. Confirm exact arguments in `make help` and `make stage-list`.

**Never default to `make e2e` / `TYPE=all` for each chaos experiment.** The full path is for end-to-end validation. If setup and full backup are already valid, execute only the stage needed by the current hypothesis and then run the necessary verification. Reuse the same `RUN_ID`/VM only when lifecycle state and scenario requirements allow it.

### Critical safeguards already documented by the repo

- Mutating stages run preflight automatically. Do not set `STAGE_SKIP_PREFLIGHT=true` just to save time unless a separately reviewed workflow explicitly justifies it.
- `STAGE_DRY_RUN=true` prints resolved identity/command without contacting the cluster; use it when validating dispatch.
- `make clean-all` is destructive across workflow-managed resources in the namespace. Never use it as routine scenario cleanup or triage. Use the documented run-/pool-scoped cleanup procedure.
- Run-scoped artifacts live under `runs/<run-id>/`, including structured reports/state. Read those artifacts rather than repeatedly reconstructing facts from cluster queries.
- Run sequentially from one checkout where workflow state is shared; do not assume that unique VM names alone make all concurrent operations safe.
- `make preflight` proves prerequisites/readiness, not that a backup will succeed.

Sources: [repository README](https://github.com/ddjain/virt-cbt-lab), [AGENTS.md](https://github.com/ddjain/virt-cbt-lab/blob/main/AGENTS.md), [Makefile / `make help`](https://github.com/ddjain/virt-cbt-lab/blob/main/Makefile).

## 3. Four expert review lenses

These are separate review perspectives to apply during Phase 0. They are not a claim that separate runtime subagents were launched.

### A. Harness / workflow reviewer

Check whether the lead calls the smallest Make stage needed, preserves lifecycle state, reuses a `RUN_ID`, and avoids full E2E reruns for one-phase experiments. Verify command syntax and stage semantics from `make help` and `make stage-list`, not memory.

### B. Multi-agent orchestration reviewer

Trace every agent spawn: trigger condition, task boundary, input artifacts, output contract, timeout, mutation permissions, and overlap with other agents. Identify agents that merely relay information or repeat a script's job. Keep parallelism for independent read-only research; serialize shared-cluster mutations.

### C. Deterministic verification reviewer

Read the actual scripts and tests. Map every repeated check to an existing script/Make target, a missing capability, or a reasoning-only task. Ensure evidence from the environment—not the agent's final prose—determines objective results.

### D. Agent evaluation / safety reviewer

Create a small regression set of real workflow tasks and failure cases. Evaluate final environment state, tool choice, correctness, time, retries, repeated reads, and false PASS behavior. Use bounded budgets and explicit stop conditions for autonomous exploration.

Anthropic's evaluation guidance recommends clearly specified tasks, objective graders for objective properties, traces/tool-call checks, and tracking latency/tool usage as well as final outcomes. See [Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents).

## 4. Target team: keep capabilities, reduce unnecessary spawns

Audit actual skills before deciding which agent names to remove. Target behavior:

| Role/capability | Target policy | Reason |
|---|---|---|
| `chaos test team` lead | **Keep; always active** | Owns RUN_ID, lifecycle state, experiment selection, budget, mutation authorization, recovery, and final verdict. |
| Injection/lifecycle monitor | **One focused monitor when needed** | Independently observes target identity, actual injection effect, and backup lifecycle timing. Do not spawn one agent per log source. |
| Evidence/injection/CBT verifiers | **Keep verification capability; make objective checks scripts** | Hashes, resource identity, timestamp order, artifact completeness, checkpoint consistency, and structured report assembly are deterministic. Keep independent verification, not necessarily an LLM per check. |
| Scenario/spec/Jira investigator | **Conditional** | Run when context is missing, inconsistent, or requires interpretation. Reuse a compact investigation summary on later runs. |
| Krkn command/scenario preparer | **Use existing skill/workflow for known cases** | Do not rediscover known command construction. Validate target and trigger with deterministic checks. |
| Flow analyst / forensic investigator | **On demand** | Invoke for unexpected failures, ambiguous/contradictory evidence, unknown root cause, or meaningful coverage gaps. Do not run deeply after every successful experiment. |
| Report generator | **Script first** | Read `report.json` / `summary.json` and evidence files; avoid another agent rewriting the same facts. |
| Autonomous experiment planner | **Bounded and conditional** | Propose the next informative experiment; must not bypass lead-controlled execution or budgets. |

Do not assume every skill needs a separate spawned agent. The lead should directly invoke a deterministic script or existing skill when independent reasoning and separate context are not useful.

## 5. Deterministic-tool-first policy (mandatory in relevant skills)

Before any repeated operational check or verification using LLM reasoning:

1. Inspect the relevant script, Make target, shared helper, test, and documentation.
2. Understand purpose, inputs/defaults, outputs, exit codes, side effects, timeout/retry behavior, and limitations.
3. Reuse an existing capability if it proves the required claim; do not create a duplicate.
4. If a repeatable capability is missing, add the smallest reusable script consistent with repository conventions.
5. Test success, negative results, missing resources/evidence, malformed inputs, and command errors as applicable.
6. Return non-zero on failed checks/errors; missing evidence must never silently become success.
7. Prefer structured machine-readable results (JSON where practical) with check name, status, expected/actual values, and evidence references.
8. Update the relevant skill immediately so future runs call the script.
9. Document why existing scripts were insufficient and which skill uses the new script.

Prefer deterministic tools for:
- Preflight and stage selection
- Resolving the correct RUN_ID/VM and lifecycle state
- Backup/checkpoint status and chain invariants
- Actual injection target and timing evidence
- Artifact presence, run-ID matching, hashes, and timestamps
- Restore and deterministic guest-data integrity
- Retry/timeout/cleanup state
- Run summary/report generation

The LLM decides what to test, interprets unexpected outcomes, and proposes follow-up experiments. It should not manually repeat an objective check already provided by a tested script.

### Script audit deliverable

Read all scripts involved in setup, backup, incremental mutation, verification, restore, monitoring, chaos trigger, cleanup, and reporting. Include all scripts called by the current lead/skills—not just the files named in README.

Create `docs/agent-workflow-audit.md` (or the repository's established equivalent) with a matrix:
- Script/Make target and purpose
- Inputs, defaults, and output/artifact path
- Exit codes and failure behavior
- Read-only vs mutating
- Retry, timeout, and cleanup semantics
- Existing tests
- What the script proves and does not prove
- Skills/agents that should invoke it

Do not add a backup verifier until `vm-cbt-verify.sh`, `vm-cbt-restore-test.sh`, `run-summary`, and their helper/test paths have been inspected for the specific missing assertion. Checkpoint validity is not automatically proof of restored guest-data integrity or chaos recovery.

## 6. Lead-agent execution policy

The lead follows this sequence for every experiment:

1. Read `make help` and `make stage-list` when the current checkout/interface is unknown or changed.
2. Establish the experiment objective, hypothesis, expected behavior, injection window, target, acceptance criteria, abort condition, and budget.
3. Resolve a unique run identity and inspect `runs/<run-id>/` before creating or reusing resources.
4. Run preflight and verify the existing lifecycle state.
5. Select the **smallest valid stage** for the hypothesis; use dry-run if identity/dispatch is uncertain.
6. Start/confirm the monitor before a timing-sensitive injection.
7. Route all mutations through the lead's approved execution path and use the existing Krkn Hub/`krknctl` workflow.
8. Collect evidence once, with run ID and resource UID where applicable.
9. Call the deterministic verifier(s) needed for the claim; don't re-run unrelated stages.
10. Produce the verdict and structured summary; invoke the investigator only if needed.
11. Ensure recovery/cleanup is safe and recorded.

### Avoid blocking and redundant work

Every delegated task must define objective, scope, input artifacts, read-only/mutating permission, timeout, output contract, and terminal status (`COMPLETED`, `FAILED`, `TIMED_OUT`, `BLOCKED`). No indefinite waits.

Pass artifact paths and concise structured summaries to agents. Do not ask each agent to reread the same logs, specs, or resource state. If two tasks require the same evidence collection, collect once and share it. Use narrow rechecks rather than full E2E reruns.

The lead is the sole authority for shared-cluster mutations and final verdict. An agent's narrative is not proof that a command succeeded.

## 7. Verdict contract

Use a deterministic evaluator over structured evidence and scenario-specific acceptance criteria:

- `PASS`: Intended chaos was independently observed; all required CBT criteria passed; restore/data integrity passed where required.
- `FAIL`: A valid experiment demonstrated a product/resilience failure supported by evidence.
- `INVALID`: The intended condition was not exercised (e.g. injection never happened or targeted the wrong resource).
- `INCONCLUSIVE`: Evidence is missing, contradictory, or insufficient to decide.
- `BLOCKED`: Preflight or environment health prevented safe execution.

Rules:
- Missing mandatory evidence cannot PASS.
- A backup object's `Completed` status alone does not prove data correctness.
- Keep product defects separate from trigger, observer, harness, and environment failures.
- The injecting agent cannot be the sole authority for the result.
- LLM explanation can contextualize a verdict but cannot override mandatory deterministic checks.
- Record unexecuted work explicitly; never claim a scenario passed unless it was actually executed and verified.

## 8. Autonomous investigation and exploration

### Invoke only when

- A valid stage fails unexpectedly.
- Evidence is ambiguous or contradictory.
- A deterministic verifier finds an unexplained mismatch.
- Recovery fails or a new failure mechanism is plausible.
- A meaningful CBT lifecycle/coverage gap remains.
- Bounded retry of a transient/harness error is exhausted.

### Required investigation output

- Question and scope
- Observed facts with run artifact paths/source references
- Hypotheses explicitly labeled as hypotheses
- Missing evidence and limitations
- Smallest experiment that distinguishes plausible causes
- Expected observation for each outcome
- Exact Make target/stage and verification script(s)
- Target, safety constraints, timeout, and experiment budget

### Exploration loop

1. Establish or reuse a valid baseline.
2. Choose the highest-value untested lifecycle phase or failure hypothesis.
3. Vary one factor at a time by default; test combinations only where evidence suggests an interaction or meaningful risk gap.
4. Run only the relevant stage, not full E2E, unless the experiment genuinely requires a fresh lifecycle.
5. Verify with scripts and independent observation.
6. Record outcome and select the next experiment based on evidence.
7. Stop when the budget is exhausted, no useful new test remains, environment health degrades, target identity is ambiguous, or cleanup fails.

Suggested initial configurable limits: maximum 5 experiments per exploration batch; maximum 2 attempts for a suspected transient/harness failure before stopping for diagnosis; caller-defined wall-clock budget; immediate stop on unhealthy environment or failed cleanup. Tune after measuring baseline; these must be explicit configuration, not hidden prompt assumptions.

## 9. Evidence-backed learning

Use existing `learning.md` and run artifacts unless the audit proves they are insufficient. Do not introduce a vector database or memory service at this stage.

Each finding should record:
- Finding ID and scenario
- Run ID and evidence paths
- Confirmed observation vs hypothesis
- Injection type, target, lifecycle phase, and environment/version context
- Expected vs actual behavior
- Reproduction count and status (`unconfirmed`, `reproduced`, `confirmed`, `rejected`)
- Known limitations and next experiment/rationale

Do not promote one anomalous result to a confirmed rule. Link to detailed logs rather than copying them into learning files. Learning must help select experiments or prevent repeated work without blocking routine execution.

## 10. Implementation phases

### Phase 0 — Audit the current checkout and agent delegation

Tasks:
- Read current `make help`, `make stage-list`, `AGENTS.md`, relevant README/docs, and the actual lead skill plus every skill it invokes.
- Trace every spawned agent: trigger, input, output, timeout, mutation permissions, and overlapping responsibilities.
- Read all scripts used for setup, backup, incremental stages, verification, restore, monitoring, chaos injection, cleanup, and reports.
- Build the script/Make-target capability matrix.
- Identify full-E2E reruns that can become stage-level commands, duplicated checks, repeated artifact reads, and unnecessary agents.
- Record baseline run time, agent/model calls where measurable, retries, evidence quality, and cleanup result.

Deliverables:
- `docs/agent-workflow-audit.md` or equivalent
- Current lead-to-agent delegation map
- Script/Make-target capability matrix
- Prioritized file-by-file changes with tests and acceptance criteria

Exit criterion: every repeated operational check maps to an existing deterministic capability, a justified missing capability, or a genuine reasoning task.

### Phase 1 — Make the lead stage-aware and deterministic-first

Tasks:
- Keep one lead as lifecycle/mutation owner.
- Make it use `make help` / `make stage-list` rather than hard-coded stale assumptions.
- Require it to choose the smallest valid Make stage for each experiment.
- Reuse one run ID and prior artifacts where lifecycle rules permit.
- Keep one focused monitor for timing-sensitive tests; make forensic agents conditional.
- Update skills to call existing scripts and Make targets.
- Add only missing narrow scripts, tests, and skill references.
- Ensure retries, timeouts, and cleanup are bounded.

Exit criteria:
- Pod and container scenarios can run the relevant stage without unnecessary full-E2E repetition.
- Every run has explicit state and terminal outcome.
- No duplicate verifier is added without documented justification.

### Phase 2 — Deterministic verdict and regression tests

Cover at least:
- Valid backup/checkpoint chain and successful restore
- Backup status reports success but restore/data check fails
- Missing/duplicate/mismatched checkpoint evidence
- Chaos not injected or wrong target
- Observer missing/not ready
- Contradictory timestamps or mismatched RUN_ID
- Missing artifacts/hash mismatch
- Command timeout/non-zero exit
- Recovery/cleanup failure
- Unsafe/unhealthy preflight
- Stage dispatch chooses the expected target and does not accidentally run TYPE=all

Use fixtures/mocks for evaluator and dispatch tests where possible; separate offline tests from destructive/live cluster tests.

Exit criteria: negative cases cannot PASS, and stage dispatch is tested against the current `make help`/stage table.

### Phase 3 — Bounded autonomous investigator

Tasks:
- Trigger only for unexpected results, ambiguous evidence, or meaningful coverage gaps.
- Require evidence-backed hypotheses and a minimal discriminating experiment.
- Enforce parent authorization, target scope, safety gates, budgets, and stop conditions.
- Execute through the same Make-stage workflow and deterministic verifiers.
- Parallelize independent read-only research only.

Exit criteria: no agent can bypass execution policy; every proposal includes evidence, stage command, expected observations, and budget.

### Phase 4 — Learning and experiment selection

Tasks:
- Store compact evidence-backed findings.
- Avoid duplicate experiments using run metadata and prior findings.
- Prefer informative uncovered lifecycle phases over random combinations.
- Confirm that prior findings actually change next-experiment selection.
- Update skills when a reusable script/procedure is validated.

Exit criteria: later runs cite prior findings and avoid redundant tests; unconfirmed hypotheses stay labeled.

### Phase 5 — Evaluate and expand

Tasks:
- Compare metrics to Phase 0 baseline.
- Reduce repeated agent invocations, artifact reads, and full E2E reruns.
- Expand to more scenarios one at a time after pod/container gates pass.
- Permit parallel mutations only in proven isolated environments.
- Add advanced exploration strategies only if simple hypothesis-driven selection plateaus.

Exit criteria: measurable improvement without reducing verification quality or recovery reliability.

## 11. Agent evaluation suite and metrics

Start with 10–20 realistic tasks based on existing manual checks and known failures; expand as the team learns. Include positive and negative cases so the agent is not rewarded for always investigating or always passing.

Evaluation cases should include:
- Correctly select `make vm-cbt-backup` rather than rerunning full E2E for a single incremental experiment.
- Reuse an existing `RUN_ID` only when lifecycle state is valid.
- Refuse unsafe/destructive `make clean-all` during normal triage.
- Detect that preflight success does not prove backup success.
- Detect missing injection evidence and return `INVALID`/`INCONCLUSIVE`, not PASS.
- Detect backup completion with failed restore/data integrity.
- Handle missing artifacts and stage timeouts without indefinite blocking.
- Invoke autonomous investigation only for a real unknown/coverage gap.
- Avoid duplicate script creation when an existing script already covers the assertion.
- Stop at experiment budget and record the reason.

Measure per run:
- End-to-end wall-clock time and per-stage duration
- Agent spawns/model calls where measurable
- Repeated source reads, API queries, and evidence collections
- Make target chosen and whether it was the narrowest valid target
- Retries/timeouts and reason
- Injection validity and evidence completeness
- Verdict correctness against fixture/ground truth
- Recovery/cleanup success
- New validated failure modes or coverage added

Track consistency across repeated trials for agent-level decisions. Keep environment outcomes and the agent's process quality separate: a correct product failure is not an agent failure if it was correctly detected and reported.

Initial targets to validate after baseline:
- Zero false PASS outcomes in the negative evaluator suite.
- 100% of mandatory checks run or explicitly marked unavailable.
- Zero unbounded retries/planning loops.
- One owner for shared-cluster mutations.
- Every run reaches an explicit terminal state, including interruption.
- Fewer unnecessary full-E2E reruns and duplicate investigations than baseline.
- Every new reusable script has tests, documented behavior, and a skill reference.

Do not optimize speed by skipping preflight, weakening verification, or suppressing failures.

## 12. Required skill changes

Update existing skills in place; do not create one skill for each check.

Relevant skills should:
- Require `make help` and `make stage-list` when the interface is unknown or has changed.
- Use the smallest valid stage target and avoid full E2E for each experiment.
- Inspect current run artifacts before creating/reusing a VM or lifecycle.
- Enforce deterministic-tool-first behavior.
- Document target inputs, exit codes, evidence paths, and failure handling.
- Use run summary/report outputs instead of reconstructing results in prose.
- Route unexpected outcomes to bounded investigation.
- Require new scripts to be tested and documented before use.
- Explicitly prohibit routine `make clean-all` use and unsafe preflight bypasses.
- Preserve existing triage behavior when scenario specs, triggers, or canonical issue artifacts are missing.

Avoid duplicating the full Makefile documentation into every skill. Link to `make help`, `make stage-list`, and the shared audit/contract document.

## 13. Keep PRs small and reviewable

Keep skill-layout changes separate from behavior changes unless a concrete discovery/discovery bug blocks the workflow. Recommended implementation sequence:

1. Audit-only change: delegation map + script/Make target matrix.
2. Lead skill update: stage-aware deterministic-first policy.
3. Script/verdict gaps with tests, one demonstrated gap at a time.
4. Conditional autonomous investigator and budgets.
5. Evaluation suite and before/after measurement.

Do not combine a broad orchestration rewrite with a simple skill-path consolidation. Do not commit or push automatically.

## 14. Final implementation report

Report:
1. Actual agents invoked before/after and why each remains or becomes conditional.
2. Files changed and purpose.
3. Existing Make targets/scripts reused.
4. New scripts added and the specific demonstrated gap each fills.
5. Skills updated to use the targets/scripts.
6. Offline tests and live tests run, separately, with results.
7. Example run artifacts and verdicts.
8. Before/after duration, unnecessary full-E2E count, agent calls, repeated checks, and verdict accuracy.
9. Remaining gaps and scenarios not executed, with reasons.

Never claim a scenario passed unless it was executed and its evidence supports that conclusion. Record unexecuted work in `NOT_EXECUTED.md` or the repository's established equivalent.
