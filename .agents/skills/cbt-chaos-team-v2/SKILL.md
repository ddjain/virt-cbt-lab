---
name: cbt-chaos-team-v2
description: >
  Run one CBT chaos scenario with a Lead and two expert capabilities: a Chaos
  Engineer prepares reusable scenario scripts, and an independent CBT Analyst
  verifies injection evidence, evaluates results, investigates failures, and
  drafts supported bugs or proposed follow-up scenarios. Reuse the Make pipeline
  and krknctl native event triggers; the Lead executes approved scripts, writes
  per-attempt and consolidated reports, and curates short reusable lessons.
user_invocable: true
arguments:
  - name: request
    description: >
      Scenario ID and intent, for example run CBT-F-01 with the chaos team.
      Resolve scenario-spec.md and jira-issue.md under cbt-chaos/scenarios_v2/.
    required: true
---

# CBT Chaos Team v2 — Lead

One scenario, one approved executable bundle, one execution owner. Do not
rebuild the existing E2E workflow or run a committee of monitoring agents.

## Team and communication

| Role | Responsibility | Spawn when |
|---|---|---|
| Lead (you) | Resolve scenario, approve, execute commands, maintain run state, report, curate lessons | Every attempt |
| `cbt-chaos-trigger-preparer-v2` — Chaos Engineer | Prepare/revise simple scripts using verified krknctl metadata | Bundle missing/incompatible, scenario changed, or injection defect |
| `cbt-chaos-analyst-v2` — CBT Analyst | Independently establish injection validity, assess criteria, investigate anomalies, write supported bugs and proposed scenario drafts | After each terminal attempt; earlier only to identify evidence that must be captured live |

Give each specialist the scenario/spec paths, run/lifecycle identities,
commands, evidence paths, scope and a bounded task. Return artifact paths,
result/blocker, and optional evidence-backed learning. No peer-chat chain,
separate execution agent, mandatory second grader, or report-only subagent.
The script author must not grade its own run. Analyst evidence collection
is read-only; it never injects, reruns a stage, or changes the environment.

## Files: one obvious home

Under `cbt-chaos/scenarios_v2/<ID>/`:

- `jira-issue.md`, `scenario-spec.md`: intent and acceptance contract.
- `run.sh` or an existing named entrypoint, plus optional local helpers/configs:
  reusable pipeline + injection. `chaos-trigger.sh` is allowed, not required.
- `approval.json`: explicit approval, relative bundle paths + SHA-256 hashes,
  entrypoint/argv, approved scope/window and non-secret parameter constraints.
- `runs/<attempt-id>/run.json`: Lead-owned attempt state and evidence links.
- `runs/<attempt-id>/injection-confirmation.json`: script-computed checks and
  paths to raw target/condition/effect/exclusion evidence; never self-proof.
- `runs/<attempt-id>/analysis.json`: Analyst result, criteria, investigation,
  bug/proposed-scenario references and optional feedback.
- `runs/<attempt-id>/run-report.md`: Lead's engineering-facing report.
- `runs/<attempt-id>/`: scoped raw API snapshots, logs and command statuses.
- `consolidated-report.md`: all closed attempts, with links and separate counts.
- `bugs/<defect-slug>.md`: one bug per distinct supported product defect;
  subsequent runs add evidence to that bug, not another bug per run.

Lifecycle evidence remains in repository-root `runs/<lifecycle-id>/`; reference
it instead of copying or overwriting it. Keep the scenario attempt ID distinct
from lifecycle IDs when a scenario requires interrupted/recovery/clean legs.
No extra verdict file, events log, ledger, contracts tree, or evidence index is
required. Do not relocate, overwrite, or regrade old/archived runs as part of
this cutover. Never automatically archive the scenario-local outputs.

`run.json` records `run_id`, `scenario`, `phase` (`started`, `running`, `closed`),
`verdict` (null until terminal), UTC start/end, `attempt` (1 or 2), `retry_of`
(null or the first attempt ID), lifecycle IDs, the approved bundle manifest,
approval answer/time and non-secret constraints, command exit statuses, evidence
paths and any blocker. Snapshot approval into this record so later repairs
cannot change an earlier attempt's approval history. Write JSON atomically
with jq + temporary file/rename; do not infer state from chat. Record commands
with credentials redacted; never persist secrets or kubeconfig contents.

### Chaos run ID format

Every new chaos attempt ID is
`<dd-mm-yyyy-hh-mm-ss>-<vm_name>-<note>-iteration-<number>`, using the current
**UTC** time, the exact existing or planned VM name, a short lowercase note
such as `full-copy`, and a positive iteration. Generate it only with:

```bash
CHAOS_RUN_ID="$(./cbt-chaos/run-id.sh "$VM_NAME" full-copy "$ITERATION")"
```

Choose the next scenario iteration after the highest `iteration` in its existing
run records; start at 1 when none are recorded. Each executed attempt, including
a repaired retry, consumes the next iteration. Record `iteration`, `vm_name`
and `note` in `run.json`; `attempt` remains 1 or 2 within the current request.
Keep the generated ID identical in directory names, evidence and reports.
Never truncate it, rename earlier runs, or reuse an existing run directory.

This descriptive ID is **not** a Kubernetes lifecycle ID: lifecycle IDs remain
the short values from `scripts/run-id.sh` (40-character limit). Resolve the
exact VM name before generating the chaos ID; for a new VM, preselect its
lifecycle ID and use the setup stage dry run to resolve its planned VM name.
Use separate chaos/lifecycle arguments or variables; never pass `CHAOS_RUN_ID`
as Make's `RUN_ID` or derive Kubernetes resource names from it.

## 1. Resolve and inspect before doing work

Read `improvement.md` beside this skill. Resolve the scenario using file tools;
read its spec and Jira issue, by **section title/content, not fixed numbering**.
Extract target, required state/window (active copy, between stages, or stable
system), exact expected disruption, acceptance criteria, exclusions, recovery
and time bounds. Missing files or contradictory requirements block execution;
resolve from repository/Jira evidence where possible, otherwise use `ask`.

Inspect the **executing checkout**, including remote execution:

```bash
make help
make stage-list
```

Read the selected Make recipe, `scripts/stage.sh`, and actual stage script;
for `e2e`, also read `scripts/e2e-stage.sh`. Do not trust remembered commands
or an archived trigger. If a documented script is absent, have the Engineer
prepare it; do not quietly run an archived variant. Sync only intended source
changes; `sync.sh` excludes `.agents/` and does not deploy these skills.

Choose the smallest valid stage(s). A full-copy scenario must arm injection
**before** the full backup; an incremental-copy scenario first needs a valid
full baseline. Stable-system scenarios use their declared precondition, not
an invented active-copy requirement. Do not add clean-lifecycle or recovery
legs unless the scenario requires them.

## 2. Prepare and approve the whole bundle

Invoke the Chaos Engineer only when preparation/revision is necessary. Its
handoff must include entrypoint, every invoked local helper/config, required
inputs, exact commands, stage ownership, event/effect checks, time bounds,
rollback, rehearsal results and known limitations. Prefer existing compatible
scripts; one short file is ideal, multiple files are fine when clearer.

Priority: krknctl native event trigger → bounded wait + krknctl when native
triggers are unavailable → oc/kubectl only when krkn cannot express the fault.
Verify installed help, trigger execution environment and auth/tools. Use
`--triggers-on-timeout fail` when that flag is supported: the installed default
may be `skip`, which must not become a silent no-op. Start krkn before opening
the window; late container startup alone is not a reason to bypass krkn.

Before live work, rehearse supported plan/dry-run paths and stage resolution:

```bash
make vm-backup RUN_ID=<lifecycle-id> VM_OS=<os> STAGE_DRY_RUN=true
```

Use the actual selected target/inputs. Dry runs prove command resolution, not
injection or product behavior. Check supported krkn dry-run flags from help;
never run the disruption to discover whether its flags work.

Compare SHA-256 hashes (`sha256sum`, or `shasum -a 256`) for the spec, Jira
requirements, entrypoint, **all** invoked local scripts/configs, and the approved
non-secret scope/parameter constraints. A script-only hash is insufficient.
Use structured `ask`: show exact entrypoint/commands, window, target scope,
blast radius and rollback; offer **Approve bundle** / **Do not run**. Record the
explicit answer and bundle in `approval.json`; no answer means no injection.
Unchanged approved bundle/constraints can rerun without another question.
Changed helper/spec/scope/command needs fresh approval. Verify the bundle again
immediately before execution; no script edits during an active attempt.

## 3. Execute commands, not live agent coordination

Generate the chaos ID with `./cbt-chaos/run-id.sh` as specified above, create
a fresh scenario run directory (refuse reuse), and record `run.json` before
preflight. The entrypoint
must accept this Lead-created run root when its run ID matches, while refusing
existing action/effect outputs; it must not reject the pre-armed directory as
a collision. Run `make preflight VM_OS=<os>` and required scenario-specific
read-only guards.
Check destination headroom for required full + incremental data and tool/auth
availability. A failed guard means BLOCKED: preserve the diagnostic and report,
not a forced workflow. Never `make clean-all` or set `STAGE_SKIP_PREFLIGHT=true`.

The inspected entrypoint owns the sequence, or the Lead runs the declared Make
stages and injection command; **never both**. Explicitly assign each stage and
injection to exactly one owner. Arm condition/effect collection before opening
the window; if separate processes are needed, require an actual readiness
signal, then start the pipeline stage. Do not wait for injection completion
before starting the stage it is waiting for. Use bounded waits and stop when
the window is missed; no additional injector or unbounded reconnect loop.

Save raw evidence for the same run/resource UID and time interval:

- baseline identities/state and any required untouched siblings;
- observed condition and UTC time **before** the action; active-copy proof
  when required, not merely object creation or a generic Progressing flag;
- exact resolved target/action, request time and real process exit statuses;
- independent API/log effect and recovery observations, with expected identity
  or condition transitions and blast-radius checks; no effect → no valid run.

A changed resourceVersion alone does not prove the requested fault. A log line
saying INJECTED, krkn exit 0, or a JSON `valid: true` is not independent proof.
Capture all process statuses even when a faulted backup is expected to fail.
If streaming through tee, preserve the original status, not just tee's:

```bash
if "$ENTRYPOINT" 2>&1 | tee "$RUN_ROOT/driver.log"; then
  statuses=("${PIPESTATUS[@]}")
else
  statuses=("${PIPESTATUS[@]}")
fi
# statuses[0] is the entrypoint; statuses[1] is tee. Save both immediately.
```

Use Bash with pipefail for the enclosing runner. The entrypoint itself must
preserve child-stage/krkn statuses too. Trap only owned background processes
and declared fault rollback; never delete evidence. A failed rollback or unsafe
cluster state blocks further attempts; report it before any new mutation.

## 4. Use deterministic checks, then one independent analysis

Complete the scenario's required lifecycle legs and verification. Reuse
`make monitor RUN_ID=<id>` for timings and `cbt-chaos/watch-resource.sh` for
supported authenticated scoped watches (read its readiness/timeout contract).
`make vm-cbt-verify RUN_ID=<id>` already runs restore verification: do not run
restore again without a distinct requirement. Generate summaries with
`make run-summary RUN_ID=<id>` for each relevant lifecycle, including failed
legs with saved state. Missing lifecycle metadata is recorded, not fabricated.

Inspect `cbt-chaos/scenario-verdict.sh --help`, `--list-checks` and
`--list-check-sets`. Use it only when the selected set and evidence layout
actually match this scenario's criteria. Its default is full-interruption
shaped, **not** a universal incremental grader. Record check IDs and coverage;
do not accept an automatic fallback set or its top-level result as proof of
unmodeled criteria. Keep per-check FAIL/UNKNOWN results visible; do not
narratively override them. If mismatched, mark it not applicable and give the
Analyst the pipeline results plus remaining named checks.

Spawn the independent CBT Analyst with scenario requirements and raw evidence,
not a preferred verdict or prior-run conclusions. It checks injection evidence
itself, maps every mandatory criterion, investigates scoped unexpected CR/log
signals, and writes `analysis.json`. Pre-identify any ephemeral evidence before
the run if the existing script cannot capture it. Time/attempt bounds are part
of the handoff; default one analysis pass, at most 10 minutes of extra read-only
triage, no full rerun. No new root-cause claim without evidence.

Terminal rules (apply in this order):

| Evidence | Verdict |
|---|---|
| Prerequisites prevent starting the approved injection attempt | BLOCKED |
| Injection missing/unproven, wrong target/window, or blast-radius violation | INVALID |
| Valid injection and observed mandatory product behavior contradicts the spec | FAIL |
| Valid injection, no proven violation, but mandatory product evidence missing/ambiguous | INCONCLUSIVE |
| Valid injection and every mandatory criterion proven | PASS |

Unexpected product recovery failure or an exceeded required recovery bound can
be FAIL; recovery need not succeed before filing a product bug. Expected backup
interruption is not automatically FAIL. An unknown root cause does not erase an
observed defect; unknown attribution/evidence does not justify inventing one.

## 5. Close, report, then at most one approved repaired retry

For **every terminal attempt**, including BLOCKED/INVALID and partial runs:

1. Record Analyst result (or the explicit blocker if analysis could not run),
   command statuses, evidence gaps and verdict in `run.json`; close with UTC.
2. Fill `cbt-chaos/template/run-report-template-v2.md` as `run-report.md` from
   evidence only. Link product bugs and proposed follow-ups; no duplicate
   grader/report agent. Missing field → “not recorded”, not a plausible value.
3. Regenerate scenario `consolidated-report.md` with its v2 template from closed
   run records/reports and bug links, sorted by start time. Count each verdict
   separately, relate repaired attempts, never hide invalid/blocked runs or
   describe them as product failures. Do not re-read all raw logs to report.
4. Collect specialist feedback and update generic memory only when warranted.

On INVALID caused by an actionable script/injection defect, send evidence to
the Engineer for **one** repair, request fresh bundle approval, then run **one**
fresh attempt with `attempt=2` and `retry_of=<first-id>`. Report/close attempt 1
before starting attempt 2. Rejection/no answer, unsafe state, inability to fix,
or a second invalid attempt ends this request. Never silently replay the same
script. PASS/FAIL/INCONCLUSIVE/BLOCKED do not authorize another execution.
Further retries, new variation or widened scope require a new user request.

## Weak components and self-learning

The Analyst may draft `scenarios_v2/<new-ID>/jira-issue.md` for a genuinely new,
evidence-backed weakness, using the existing engineering Jira template. Lead
checks existing scenarios/bugs for duplicates and allocates an unused matching
ID; distinguish observation from proposed test/hypothesis. Mark proposed and
unexecuted, link the originating evidence, and do **not** target it now. Missing
scenario-spec means it cannot run until prepared and approved. Do not spawn a
separate discovery agent or add another weak-components ledger.

Read this skill's `improvement.md` before every run and consult relevant closed
failures when useful. Request feedback at specialist completion or meaningful
blockers, not by repeated polling during injection. Only Lead edits memory:
accept generic, evidence-backed prevention rules useful on future runs; one
deduplicated bullet, **1–3 lines maximum**, with a short evidence reference.
Refine obsolete lessons rather than accumulate contradictions. Full incidents
stay in run evidence; no useful lesson → no edit. Lessons never weaken safety,
approval or verdict criteria, or expose earlier verdicts to the Analyst.
