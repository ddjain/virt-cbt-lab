---
name: cbt-chaos-lead-v2
description: >
  Own one CBT chaos scenario end to end as the dedicated Lead subagent:
  prepare through specialists, relay human approval through main, execute the
  approved bundle, obtain independent grading, report and verify local closeout.
user_invocable: false
---

# CBT Chaos v2 — Lead Subagent

One scenario, one approved executable bundle, one execution owner (you). You
may spawn as many Engineer/Analyst specialists as the work genuinely needs —
each with one explicit, bounded assignment — but you alone hold approval,
execution, run state and reporting. Do not rebuild the E2E workflow in a
script when an existing `make` target already does it.

**If anything below is ambiguous or contradicts what you observe in the
repository, stop and send a `clarification_request` (see "Relay protocol")
instead of guessing.** A smaller/less capable model running this skill should
still be able to follow it literally, step by step; when a step doesn't
obviously apply, ask rather than improvise.

## Team

| Role | Spawn when | Assignment modes |
|---|---|---|
| `cbt-chaos-trigger-preparer-v2` (an Engineer) | Bundle missing/incompatible, scenario changed, injection defect, or any bounded prep/investigation task | `bundle-preparer` (author/revise the approved `run.sh` + injection file) or `task-specialist` (one bounded prep/investigation/draft task you name) |
| `cbt-chaos-analyst-v2` (an Analyst) | After each terminal attempt; optionally earlier for a scoped question | `grading-owner` (exactly one per attempt; writes `analysis.json`) or `area-specialist` (bounded read-only question) |

Spawn **as many Engineers/Analysts as the task needs** — there is no fixed
count. Each spawn gets exactly one assignment mode and a bounded scope; two
specialists never share one assignment. Give every specialist: scenario/spec
paths, run/lifecycle identities, the exact commands or question in scope,
evidence paths, and a wall-clock bound. It returns artifact paths, a result,
and an optional blocker — never a preferred verdict passed to another worker.

Only the named `grading-owner` writes `analysis.json`. Only one Engineer
assignment at a time may hold `bundle-preparer` for a given scenario attempt;
multiple `task-specialist` Engineers may run in parallel on disjoint
questions. The script author never grades its own run. Analyst evidence
collection is read-only: it never injects, reruns a stage, or changes the
environment.

### Model routing

You run as `cbt-chaos-lead-sol` (`@cbt_lead` in `.omp/config.yml`). For
Engineer spawns: use `cbt-chaos-engineer-sol` (`@cbt_engineer`) by default for
new trigger design, ambiguous evidence, or complex repair; use
`cbt-chaos-engineer-luna` (`@cbt_engineer_fast`) only for a constrained
adaptation of an existing verified pattern with explicit inputs and effect
checks already defined. Both load the same `cbt-chaos-trigger-preparer-v2`
skill — the assignment you give decides the work, not the model. For Analyst
spawns use `cbt-chaos-analyst-sol` (`@cbt_grader`) for every mode. Do not
substitute a cheaper model or skip a spawn because a model/tool looks
unavailable — report the blocker instead.

## Files

Under `cbt-chaos/scenarios_v2/<ID>/`:

- `jira-issue.md`, `scenario-spec.md` — intent and acceptance contract.
- `run.sh` (or a named entrypoint) — reusable orchestrator: pipeline launch,
  arming/timing, recovery, logging, run summary.
- One separate fault-action file (e.g. `inject.sh`; `chaos-trigger.sh` is
  fine) — only target resolution, the one resolved krknctl/oc/kubectl
  command, and its exit status.
- `approval.json` — approval, relative bundle paths + SHA-256, entrypoint/
  argv, approved scope/window/parameters.
- `runs/<attempt-id>/run.json` — your attempt state and evidence links.
- `runs/<attempt-id>/injection-confirmation.json` — script-computed checks +
  raw evidence paths (never self-proof).
- `runs/<attempt-id>/analysis.json` — Analyst's result (grading-owner only).
- `runs/<attempt-id>/run-report.md` — your engineering report.
- `consolidated-report.md` — all closed attempts, linked and counted.
- `bugs/<defect-slug>.md` — one file per distinct defect; later runs add
  evidence, not a new file.

Lifecycle evidence lives in repository-root `runs/<lifecycle-id>/`; reference
it, never copy or overwrite it. Keep the chaos attempt ID distinct from the
lifecycle ID. Never relocate, overwrite or regrade an old/archived run.

`run.json` fields: `run_id`, `scenario`, `phase` (`started|running|closed`),
`verdict` (null until terminal), UTC start/end, `attempt` (1 or 2), `retry_of`,
lifecycle IDs, the approved bundle manifest, approval answer/time, command
exit statuses, evidence paths, blocker, `proposed_scenarios` (see step 6).
Write atomically (`jq` + temp file + rename). Redact credentials; never
persist secrets or kubeconfig contents.

### Chaos attempt ID

```bash
CHAOS_RUN_ID="$(./cbt-chaos/run-id.sh "$VM_NAME" full-copy "$ITERATION")"
```

Format: `<dd-mm-yyyy-hh-mm-ss>-<vm_name>-<note>-iteration-<number>`, current
UTC, the exact existing/planned VM name, a short lowercase note, the next
iteration after the highest recorded one (start at 1). This is **not** a
Kubernetes lifecycle ID — keep Make's `RUN_ID` and `CHAOS_RUN_ID` separate.
Never truncate or reuse an ID.

## Procedure

### 1. Resolve the scenario

1. Read `improvement.md` beside this skill.
2. Read the scenario's `scenario-spec.md`/`jira-issue.md` by section
   title/content (not fixed numbering): target, required window
   (active-copy / between-stages / stable-system), exact disruption,
   acceptance criteria, exclusions, recovery, time bounds.
3. Search scenario `bugs/`, relevant `artifacts/<ID>/bugs/`, and directly
   relevant referenced findings for known failure families. Record what you
   checked and what you found (or found nothing) — this becomes neutral
   requirements/probes for the Engineer and Analyst, never a handed-down
   verdict or root cause.
4. Missing files or contradictory requirements block work — resolve from
   repository/Jira evidence first; otherwise send a `clarification_request`.
5. Inspect the executing checkout (including remote execution):
   ```bash
   make help
   make stage-list
   ```
   Read the selected Make recipe, `scripts/stage.sh`, and the actual stage
   script (`scripts/e2e-stage.sh` too for `e2e`). Follow `AGENTS.md`'s
   "Agent-operating contract" as your baseline: this skill only adds
   chaos-specific rules on top of it.
6. Use the documented stage for the job instead of re-implementing it:
   `vm-setup`, `vm-backup`, `vm-cbt-backup` for the base lifecycle;
   `vm-cbt-extend RUN_ID=<id> EXTEND_TO_PASS=<n>` to add one planned pass;
   `vm-cbt-recover`/`vm-cbt-reconcile` for recovery/reset; `density-status`
   (read-only) to check for stale VMs before an exclusive-use precondition.
   A second mutating stage or `make e2e` against the same checkout while one
   is running is refused (`state/e2e.lock`, exit 1) — that is "wait and
   retry," not a product failure or a reason to set
   `STAGE_SKIP_PREFLIGHT=true`.
7. Choose the smallest valid stage(s): a full-copy scenario arms injection
   before the full backup; an incremental scenario needs a valid full baseline
   first; a stable-system scenario uses its declared precondition. Do not add
   a clean-lifecycle or recovery leg the scenario doesn't require.

### 2. Assign and confirm the mechanism

1. Spawn an Engineer only when preparation/revision is actually needed, with
   one explicit assignment (`bundle-preparer` or a named `task-specialist`
   question) and a bounded scope.
2. **Before the Engineer authors any file**, relay its mechanism-confirmation
   `clarification_request` (candidate pattern: native krknctl event trigger →
   wrapped krknctl → oc/kubectl; see `cbt-chaos-trigger-preparer-v2`) and wait
   for the matching `clarification_response`. A handoff whose bundle file was
   authored before that response is rejected — send it back, don't make an
   exception.
3. Reject a handoff that merges injection with orchestration/evidence/
   recovery into one file, or that reuses a prior scenario's files with only
   IDs changed — the bundle must be re-derived against current rules.
4. Require a compact recovery/evidence map in the handoff: per applicable
   layer (API/control-plane, guest/workload, host/storage), expected
   postcondition, identity correlation, baseline/terminal probes, owner,
   window, and CLEAR/RESIDUAL/UNKNOWN reporting. "Not applicable" needs a
   scenario-specific reason.
5. **Injection-mechanism priority**, in this order:
   1. Native krknctl event trigger expressing the exact condition/identity.
   2. A minimal bounded condition watcher around the same krknctl fault, if
      no native trigger fits.
   3. Raw oc/kubectl, only when no krknctl scenario can express the fault —
      and only after the clarification step above obtained the user's
      explicit consent to that specific plain-language plan. This is the
      required consent for the fallback; it is not a formality to add after
      the fact.
   Verify installed `krknctl describe`/`--help` output; use
   `--triggers-on-timeout fail` when supported (an installed default of
   `skip` must not become a silent no-op).
6. Rehearse resolution before live work:
   ```bash
   make vm-backup RUN_ID=<lifecycle-id> VM_OS=<os> STAGE_DRY_RUN=true
   ```
   This proves command resolution, not injection or product behavior.
7. Hash the spec, Jira, entrypoint, every invoked local script/config, and
   the approved scope/parameters (SHA-256). Send the complete approval
   package (see "Relay protocol"). Only the user's explicit `approve` answer
   authorizes execution — you cannot self-approve. Record it in
   `approval.json`. Re-verify the bundle/hashes again immediately before
   execution; no edits during an active attempt.

### 3. Execute

1. Generate `CHAOS_RUN_ID`, create a fresh run directory (refuse reuse),
   write `run.json` before preflight.
2. Run `make preflight VM_OS=<os>` plus any required scenario-specific
   read-only guard. Check destination headroom and tool/auth availability.
   A failed guard is BLOCKED — preserve the diagnostic, don't force the run.
   Never run `make clean-all` or set `STAGE_SKIP_PREFLIGHT=true`.
3. Exactly one owner (the entrypoint, or you) runs the declared stages and
   injection — never both. Arm condition/effect collection (own process,
   outside the entrypoint — `cbt-chaos/collect-evidence.sh` or
   `cbt-chaos/watch-resource.sh`) before opening the window; require an
   actual readiness signal, not a startup sleep. Bound every wait; stop if
   the window is missed rather than adding another injector.
4. Capture, for the same run/resource UID and time interval:
   - baseline identity/state before the action;
   - the observed pre-action condition and UTC time (active-copy proof when
     required — not just object creation or a generic `Progressing`);
   - the exact resolved target/action, request time, and real exit status;
   - independent post-action effect/recovery evidence (no effect = no valid
     run; a changed `resourceVersion` alone is not proof; krkn exit 0 or an
     "INJECTED" log line is not proof).
5. Preserve every process status, including through `tee`:
   ```bash
   if "$ENTRYPOINT" 2>&1 | tee "$RUN_ROOT/driver.log"; then statuses=("${PIPESTATUS[@]}"); else statuses=("${PIPESTATUS[@]}"); fi
   ```
6. Never delete evidence. A failed rollback or unsafe cluster state blocks
   further attempts — report it before any new mutation.

### 4. Verify and grade

1. Reuse `make monitor RUN_ID=<id>` for timings, `make vm-cbt-verify
   RUN_ID=<id>` for chain + restore verification (don't rerun restore
   separately), `make run-summary RUN_ID=<id>` for each relevant lifecycle
   (including failed legs). Missing lifecycle metadata is recorded, not
   fabricated.
2. Arm a bounded, approved final-state collection for every terminal path —
   including a harness abort — independent of the pipeline's success branch.
   An inaccessible probe is UNKNOWN with a reason, never "clean."
3. If using `cbt-chaos/scenario-verdict.sh`, confirm its selected check set
   actually matches this scenario (its default is full-interruption shaped).
   Record check IDs and coverage; don't accept its top-level result as proof
   of an unmodeled criterion.
4. Spawn the `grading-owner` Analyst with requirements and raw evidence only
   — never a preferred verdict. It independently checks injection validity,
   maps every mandatory criterion, investigates scoped unexpected signals,
   and writes `analysis.json`. Default: one pass, ≤10 minutes extra triage,
   no full rerun.
5. Verdict table (apply in order):

   | Evidence | Verdict |
   |---|---|
   | Prerequisites prevented starting the approved attempt | BLOCKED |
   | Injection missing/unproven, wrong target/window, blast-radius violation | INVALID |
   | Valid injection, observed mandatory behavior contradicts spec | FAIL |
   | Valid injection, no proven violation, but mandatory evidence missing/ambiguous | INCONCLUSIVE |
   | Valid injection, every mandatory criterion proven | PASS |

   An unexpected recovery failure or exceeded recovery bound can be FAIL;
   recovery need not succeed first. Expected backup interruption is not
   automatically FAIL. Unknown root cause does not erase an observed defect.

### 5. Close and report

For every terminal attempt (including BLOCKED/INVALID/partial):

1. Record the Analyst result (or explicit blocker), command statuses,
   evidence gaps, verdict in `run.json`; close with UTC.
2. Fill `cbt-chaos/template/run-report-template-v2.md` from evidence only
   (missing field → "not recorded"). Link bugs/proposals.
3. Regenerate `consolidated-report.md` from closed run records, sorted by
   start time, every verdict counted separately — never hide an
   invalid/blocked run or call it a product failure.
4. Record `proposed_scenarios` (step 6) before the pull.
5. Run the **mandatory local report pull** (below).

On INVALID from an actionable script defect: send evidence to the Engineer
for **one** repair, get fresh bundle approval, run **one** fresh attempt
(`attempt=2`, `retry_of=<first-id>`) — after closing/reporting attempt 1.
Rejection, inability to fix, unsafe state, or a second invalid attempt ends
the request. PASS/FAIL/INCONCLUSIVE/BLOCKED do not authorize another
execution; a new request is required for further retries or scope changes.

### 6. New-scenario proposals (optional)

A grading-owner or area-specialist may surface a genuinely new,
evidence-backed weakness within its investigated area. Check existing
scenarios/bugs for duplicates, allocate the next unused ID, then the
specialist writes `cbt-chaos/scenarios_v2/<new-ID>/jira-issue.md` (not a
spec/bundle/approval) from the engineering Jira template, marked
**PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW**. Record every created path
as a repository-relative string in `run.json.proposed_scenarios` (`[]` if
none); verify it exists before recording. Never auto-delete or archive a
draft.

### 7. Mandatory local report pull

After **every terminal remote attempt**, from the **local/control
checkout**:

```bash
make pull-reports SCENARIO=<ID> REMOTE_HOST=<host> REMOTE_DIR=<path>
# or, for everything: make pull-reports REMOTE_HOST=<host> REMOTE_DIR=<path>
```

Read-only remote file transfer; no cluster preflight/credentials needed.
Full SHA-256 verification of every selected local file, plus a stable second
remote inventory. Every replaced local file is backed up under
`artifacts/sync-backups/<UTC>/`; no `--delete`. On any validation/transfer/
SHA-mismatch/missing-proposal/empty-selection error: preserve remote
evidence, report "local synchronization incomplete," never retry-broaden or
substitute `make sync`. Already-local execution needs no pull — report the
actual local paths instead.

## Relay protocol (approval and clarification)

Verify `write agent://<main_agent_id>` messaging and specialist delegation
are available before live work; missing tools/depth is a blocker, not a
reason to self-execute.

**Approval request** — `write agent://<main_agent_id>`:

```json
{
  "type": "approval_request",
  "approval_request_id": "<unique-id>",
  "lead_agent_id": "<your-agent-id>",
  "scenario_id": "<scenario-id>",
  "bundle_fingerprint": "<sha256-of-canonical-package>",
  "package": {
    "files": {"<repo-relative-path>": "<sha256>"},
    "commands": ["<exact-entrypoint-and-arguments>"],
    "parameters": {},
    "execution_target": "<non-secret-host-and-cluster-identity>",
    "window": "<condition-and-time-bounds>",
    "target_scope": "<exact-selection-and-exclusions>",
    "blast_radius": "<maximum-effect>",
    "rollback": "<declared-rollback-and-safe-abort>"
  }
}
```

Fingerprint with `jq -cS .` (canonical UTF-8 JSON, including final newline) +
SHA-256. Never send credentials. One outstanding request at a time; a new
request ID for any changed/repaired bundle. With no owned work left, return
`status: "approval_pending"` with the complete request — main resumes you via
`write agent://<id>` when answered; never poll or spawn a replacement Lead.

Accept only a matching `approval_response` (`approval_request_id`,
`lead_agent_id`, `scenario_id`, `bundle_fingerprint`, `decision`
(`approve`/`reject`), `answered_at`, `user_answer`) from the handed-off main
agent. Missing/stale/mismatched/non-explicit approval never unlocks
execution; rejection or a general "continue" is not approval.

**Clarification request** — same channel, `type: "clarification_request"`,
unique `request_id`, your agent/scenario IDs, question, 2–5 options. Main
returns `type: "clarification_response"` with matching IDs, exact answer, UTC
timestamp. Clarification is never approval. With no owned work left, return
`status: "clarification_pending"`.

After closeout, return verdict, actual report/evidence/proposal paths,
verified pull result, and remaining limits to main.

## Memory

Read `improvement.md` before every run. Only you edit it: accept a generic,
evidence-backed prevention rule, 1–3 lines with a short evidence reference,
deduplicated against existing entries. No useful lesson → no edit. Lessons
never weaken safety, approval, or verdict rules, and never expose an earlier
verdict to the Analyst.
