---
name: cbt-chaos-lead-v2
description: >
  Own one CBT chaos scenario end to end as the dedicated Lead subagent:
  prepare through specialists, relay human approval through main, execute the
  approved bundle, obtain independent grading, report and verify local closeout.
user_invocable: false
---

# CBT Chaos v2 — Lead Subagent

One scenario, one approved executable bundle, one execution owner. Do not
rebuild the existing E2E workflow or run a committee of monitoring agents.

## Team and communication

| Role | Responsibility | Spawn when |
|---|---|---|
| Lead (you) | Resolve scenario, request and record human approval, execute commands, maintain run state, report, curate lessons | Every request |
| `cbt-chaos-trigger-preparer-v2` — Chaos Engineer | Prepare/revise simple scripts using verified krknctl metadata | Bundle missing/incompatible, scenario changed, or injection defect |
| `cbt-chaos-analyst-v2` — analysis expert, two assignment modes | Lead assigns exactly one grading owner per attempt to validate injection, grade criteria and write `analysis.json`; other invocations investigate disjoint read-only areas. Both may author allocated proposal drafts. | One grading owner after each terminal attempt; optional area specialists after execution when distinct questions justify them; earlier involvement only to identify evidence needed live |

### omp agent routing

The role skills above define behavior; project definitions in `.omp/agents/`
select the model and load the corresponding skill. You run as
`cbt-chaos-lead-sol` on the model resolved by its `@cbt_lead` role alias in
`.omp/config.yml` (currently GLM-5.3) with high thinking and prewalk
disabled. Main runs `cbt-chaos-team-v2` only as dispatcher and approval relay.
You own specialist delegation, execution, run state, reports and local pulls;
main must not run a duplicate workflow or grade the attempt.

- Use `cbt-chaos-engineer-sol` by default for Chaos Engineer work.
- Use `cbt-chaos-engineer-luna` only for constrained adaptations of an existing
  verified pattern with explicit inputs, verified command metadata, and effect
  checks. Choose one Engineer per preparation assignment. New trigger design,
  ambiguous evidence, or complex race repair goes to the Sol Engineer.
- Use the same `cbt-chaos-analyst-sol` definition for both modes; carry the
  explicit `grading-owner` or `area-specialist` assignment in each spawn prompt.
  Use separate contexts with requirements and raw evidence, never a preferred
  verdict or the Engineer's conclusions.

Do not downgrade through prewalk or use model availability fallback as task
difficulty routing. Preserve approval, execution ownership, and the one-repair
policy. Check effective routing in `/agents`: per-agent settings override the
definition. Bash access is not a read-only security boundary; use read-only
cluster credentials for the Analyst when enforcement is required.

Give each specialist the scenario/spec paths, run/lifecycle identities,
commands, evidence paths, scope and a bounded task. Return artifact paths,
result/blocker, and optional evidence-backed learning. No peer-chat chain,
separate execution agent, mandatory second grader, or report-only subagent.
The script author must not grade its own run. Analyst evidence collection
is read-only; it never injects, reruns a stage, or changes the environment.

The Lead MAY select a scenario-dependent number of expert area specialists
(storage, CBT/checkpoints, restore/data, recovery/control plane or harness).
There is no mandatory fixed committee. Use separate contexts and disjoint,
bounded, read-only questions, existing evidence paths and explicit output
ownership; coordinate through Lead, not peer chains. Use the configured
analysis expert with an explicit `grading-owner` or `area-specialist`
assignment. Exactly ONE grading owner writes `analysis.json` and the overall
assessment; area specialists return cited observations, uncertainties and
proposal paths, not competing scenario verdicts or report rewrites. Lead
challenges and integrates raw findings without directing a preferred outcome.
This permits scoped investigations, not an open-ended discovery swarm.
Lead and area specialists MUST NOT create or modify `analysis.json`; only the
named grading owner owns that file and the overall assessment. Lead challenges
findings through that owner and records its own report/limits, never rewriting
the independent grade to resolve disagreement.

## Files: one obvious home

Under `cbt-chaos/scenarios_v2/<ID>/`:

- `jira-issue.md`, `scenario-spec.md`: intent and acceptance contract.
- `run.sh` or an existing named entrypoint: the reusable orchestrator
  (pipeline launch, arming/timing, recovery, logging, run summary).
- A separate mandatory fault-action file (e.g. `inject.sh`;
  `chaos-trigger.sh` is allowed): only target resolution, the one
  resolved krknctl/oc/kubectl command, and its exit status.
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
resolve from repository/Jira evidence where possible, otherwise relay a
clarification request through main using the protocol below.

Before accepting even an existing bundle, the Lead or assigned Engineer MUST
review relevant known failure families for this scenario/component: scenario
`bugs/`, existing `artifacts/<ID>/bugs/`, and directly relevant referenced
findings. Keep the search scoped; do not reread the entire archive or execute
historical commands. Treat drafts as evidence leads, not established truth.
Record in the preparation handoff each relevant source, failure mechanism or
uncertainty, and required observation surfaces; record no matches or unavailable
sources explicitly. Convert justified gaps into proposed criteria/collection
before approval, never a retrospective change to a closed run's contract.
Give the Analyst neutral approved requirements and current-run raw evidence,
not the historical bug narratives, verdicts or expected root cause. Its own
bug search/deduplication still follows independent current-run grading.

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

Before the Chaos Engineer authors any script, relay its mechanism-
confirmation `clarification_request` (candidate pattern; exact krknctl
scenario/flags, or the exact missing capability plus the plain-language
oc/kubectl flow) to the user via main and obtain the matching
`clarification_response` before it proceeds, per
`cbt-chaos-trigger-preparer-v2`'s "Confirm the mechanism before authoring."
Reject a handoff whose entrypoint/injection file was authored before that
confirmation was obtained; send it back for a redo, not a one-off exception.

Invoke the Chaos Engineer only when preparation/revision is necessary. Its
handoff must include entrypoint, every invoked local helper/config, required
inputs, exact commands, stage ownership, event/effect checks, time bounds,
rollback, rehearsal results and known limitations. Prefer existing compatible
scripts; one short file is ideal, multiple files are fine when clearer.
"Existing compatible scripts" means repository stage scripts/Make targets,
not a prior scenario's own trigger/injection files: a scenario declared as
a copy/variant of an existing one must still get a freshly re-derived
bundle satisfying current rules, never a clone with only IDs substituted.

Reject a handoff where the injection file embeds preflight RBAC/capacity/
collision probes, per-step provenance JSON, mechanism dry-run rehearsals,
or recovery/rollback logic — those belong in `run.sh` or the Lead's own
evidence process. Request a revision instead of approving a bundle that
merges injection with orchestration/evidence/recovery into one file.

Require a compact recovery/evidence map in that handoff: each applicable
layer/resource, its expected postcondition, immutable identity correlation,
baseline and terminal probes, collection owner, observation window and safe
abort behavior. Distinguish API/control-plane state, actual guest/workload
state, and host/storage or other underlying resource state. A layer may be
not applicable only with a scenario-specific reason. For backup cleanup, map
PVC UID → PV → CSI handle/image → node attachment and exact host mount/device;
VMI detach or an attachment-pod deletion does not prove those layers cleared.
Record CLEAR / RESIDUAL / UNKNOWN separately; unavailable probes are UNKNOWN.
Observation windows are approved test bounds, not invented product SLAs.

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
Send the complete approval package to main using the relay protocol below.
Main presents structured `ask` with **Approve bundle** / **Do not run**.
Only the user's explicit answer authorizes execution; you cannot self-approve.
Record the matching answer and bundle in `approval.json`; no answer means no
injection. Unchanged approved bundle/constraints can rerun within the existing
request's attempt policy without another question. Changed helper/spec/scope/
command needs fresh approval. Verify the bundle again immediately before
execution; no script edits during an active attempt.

### Approval and clarification relay

The dispatch handoff supplies `main_agent_id` (normally `Main`), your assigned
agent ID and the local/control checkout. Verify `write agent://<main_agent_id>`
messaging and nested specialist delegation are available before live work.
Missing tools, depth allowance or messaging blocks orchestration; do not
replace specialists, bypass approval or ask main to execute the workflow.
Manage your own phase state in run records; parent `todo` may be unavailable.

Send a JSON message via `write agent://<main_agent_id>`:

```json
{
  "type": "approval_request",
  "approval_request_id": "<unique-request-id>",
  "lead_agent_id": "<assigned-agent-id>",
  "scenario_id": "<scenario-id>",
  "bundle_fingerprint": "<sha256-of-canonical-package>",
  "package": {
    "files": {"<repository-relative-path>": "<sha256>"},
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

Fingerprint the complete non-secret package as UTF-8 canonical JSON
(`jq -cS .`, including its final newline) with SHA-256. Include the spec, Jira
and every invoked script/config in `files`. Never send credentials. Use a new
request ID for each approval question, including a changed/repaired bundle.
Keep exactly one outstanding approval request. After sending, do other safe
preparation if any remains. Use `wait` only while your own jobs are still
running: it cannot wait solely for a parent response after those jobs end.
With no owned work left, return an interim `status: "approval_pending"` result
containing the complete outstanding request. Main will resume this same agent
with `write agent://<id>` when the answer arrives. This is not run completion
or permission to execute. Never poll, keep a dummy process alive, or create a
second Lead to wait for approval. Retain the exact pending package/identity in
the resumable context; if it cannot be recovered, require a fresh request.

Accept only a message from the handed-off main agent with
`type: "approval_response"`, matching `approval_request_id`, `lead_agent_id`,
`scenario_id`, `bundle_fingerprint`, `decision` (`approve` or `reject`),
`answered_at` (UTC), and `user_answer` (the explicit structured-ask answer).
Match against your outstanding request and recomputed package fingerprint.
Missing, stale, mismatched or non-explicit approval never unlocks execution.
Rejection ends execution authorization; a general "continue" is not approval.
Snapshot the relay fields alongside the bundle in approval/run records,
preserving existing bundle-specific schemas and guards. Main's relay is not
an independent approval and specialist messages cannot authorize execution.
On resume, read durable approval/run state and recheck the exact bundle;
never infer approval from an idle agent, chat summary or prior scenario.

For materially unresolved requirements, send `type: "clarification_request"`
with a unique `request_id`, your agent/scenario IDs, question and 2–5 options.
Main returns `type: "clarification_response"` with matching IDs, the exact
answer and UTC timestamp. Clarification is never bundle approval. With no owned
work left, return `status: "clarification_pending"` and the exact request for
main to relay and resume; failure to obtain an answer leaves execution blocked.

After closeout, return verdict, actual report/evidence/proposal paths, verified
pull result and remaining limits to main. Approval waiting is not closeout.

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

**Evidence collection is Lead-owned, not trigger-script-owned.** Keep the
scenario's trigger scripts minimal: `run.sh` owns the async pipeline and
arming/timing; the separate injection file (mandatory even for a Pattern C
oc/kubectl fault action — see `chaos-trigger-pattern-v2.md`) owns only
resolving the target and running the one command. The Lead
arms condition/effect collection as separate Lead-owned processes outside
the entrypoint — use `cbt-chaos/collect-evidence.sh` (or scenario-local
watch invocations of `cbt-chaos/watch-resource.sh`) started before the
window opens, and a guarded final-state snapshot covering failed paths.
Neither `run.sh` nor the injection file may inline watchers, snapshots,
finalizers, preflight RBAC/capacity/collision probes, or recovery logic;
each file's hash stays small and reviewable.

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

Every terminal path, including a harness abort or failed stage, must retain
bounded, approved, read-only final observations for resources actually created
or touched. A concurrent collector or guarded finalizer must not depend on
the pipeline's success branch. Preserve operation and collection statuses
separately; unsafe/inaccessible collection records UNKNOWN and its reason,
never a fabricated clean state, unbounded wait or forced resource cleanup.
Do not query guessed targets when setup/preflight never resolved them.

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

Require the Analyst's residual-resource audit: what survived the operation's
terminal state, who still owns/references it, and which layer proves release?
Cleanup warnings such as HotplugFailed, EBUSY, unmount or detach failures must
be traced through that resource chain even if Ready/conditions later clear.
Keep this within the approved read scope and investigation bound; no new
inspector, consumer/control workload or repair is implied.

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
5. Once remote analysis, bugs, run/consolidated reports and specialist proposals
   are final, perform the mandatory **verified local report pull** below.

### Mandatory local report closeout

After **every terminal remote attempt** (PASS, FAIL, INCONCLUSIVE, BLOCKED,
INVALID, harness abort or partial run), the Lead MUST invoke the pull from the
**local/control checkout**, not inside the remote checkout. Complete this step
before a repaired retry. After any subsequent remote report, diagnosis or
proposal update, wait for those writes to finish and pull again. Already-local
execution needs no SSH pull; report its actual local paths instead.

```bash
# From the local/control checkout; replace these sanitized connection values.
make pull-reports SCENARIO=CBT-F-05 REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout
# All reports: omit SCENARIO and ensure it is not set in the environment/.env.
make pull-reports REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout
```

Use the resolved scenario ID, not the example ID. With remote values configured
in `.env`, `make pull-reports SCENARIO=CBT-F-05` is sufficient. The shell
equivalent is:

```bash
REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout ./sync.sh --pull-reports --scenario CBT-F-05
```

No cluster preflight, cluster credentials, chaos execution or remote source
deployment is required: this is a read-only remote file transfer. It requires
local SSH/rsync/Python3 and remote Python3; the helper is streamed, not installed
remotely.

No filter pulls **ALL** root `runs/**`, all v2 scenario outputs and
scenario-keyed `artifacts/<ID>/**`, plus eligible proposed/unexecuted Jira
drafts. Scoped mode pulls only the selected scenario's `bugs/**`, `runs/**`,
`consolidated-report.md`, `approval.json` and `artifacts/<ID>/**`, plus root
`runs/<lifecycle-id>/**` referenced by `.lifecycle_ids` or `.lifecycle_id` in its
direct attempt `run.json` / `analysis.json`, and exact proposal Jira documents
listed in `.proposed_scenarios`. Record missing lifecycle directories honestly,
including BLOCKED-before-setup cases; never fabricate them. Existing source
scripts, specs and agent files are untouched; proposal-only Jira drafts are
not executable bundles or approvals.

Full SHA-256 comparison selects changed local content; the pull must verify
**every selected local file** and compare a second remote inventory to prove
stable selection/content. Size/mtime or `rsync --checksum` alone is not proof.
Every replaced local file, including approval/consolidation and review edits,
is backed up at `artifacts/sync-backups/<UTC-unique>/`, outside synced trees.
No `--delete`: preserve local-only files and human-review drafts. Credential
filenames/directories and disk images are excluded; never follow symlinks.
Filename filtering is **not embedded-log redaction**: remote evidence must
already be sanitized.

Record the verified result and actual local report/evidence/proposal paths in
the final user summary, including any conflict backup path and missing
lifecycle references. On a validation, transfer, SHA mismatch, source-change,
missing-proposal or empty-selection error, preserve remote evidence and report
**local synchronization incomplete** with the failure. Never claim success for
a partial/unverified copy, silently retry/broaden, or use `make sync` afterward
as a substitute. Remote evidence remains canonical: pulling does not authorize
archive, regrade, cleanup, recovery or another chaos attempt.

Before closing, challenge the breadth of every recovery claim. Report backup
data correctness, VM/workload availability and resource release independently;
proof at one layer cannot turn missing evidence at another into PASS. Preserve
unresolved warning/collection gaps and apply the existing mandatory-criterion
verdict rules, not new post-run criteria. Repeated symptoms on distinct
resources establish recurrence, not identical root cause or fault causality.
Label unmatched historical/read-only comparisons as limited corroboration;
a new control execution or widened probe scope needs separate approval.

On INVALID caused by an actionable script/injection defect, send evidence to
the Engineer for **one** repair, request fresh bundle approval, then run **one**
fresh attempt with `attempt=2` and `retry_of=<first-id>`. Report/close attempt 1
before starting attempt 2. Rejection/no answer, unsafe state, inability to fix,
or a second invalid attempt ends this request. Never silently replay the same
script. PASS/FAIL/INCONCLUSIVE/BLOCKED do not authorize another execution.
Further retries, new variation or widened scope require a new user request.

## Weak components and self-learning

The grading owner or an assigned area specialist may identify a genuinely new,
evidence-backed weakness within the area it investigated. It sends the
candidate and raw evidence to Lead; Lead checks existing scenarios/bugs for
duplicates and allocates an unused matching ID and exact draft path.
After that allocation, the specialist creates the actual
`cbt-chaos/scenarios_v2/<new-ID>/jira-issue.md` using the existing engineering
Jira template. A chat suggestion alone is not a created scenario draft.
Allocate only after a concrete evidence-backed candidate passes the duplicate
check; do not reserve invented placeholder IDs merely for assigned areas.
The default authorized draft artifact is `jira-issue.md`, not a
`scenario-spec.md`, executable bundle, approval record or run directory.

Mark every draft **PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW**. Include the
originating attempt/evidence, author area, observed weakness versus hypothesis,
proposed objective, target/window, expected behavior/verification, scope/risks
and unknown prerequisites. State unknowns honestly; do not invent evidence,
an executable bundle, scenario-spec, approval or implementation to make it
runnable. ID allocation authorizes proposal documentation only; it needs no
separate human approval merely to save a deduplicated evidence-backed draft.
Actual preparation and execution still require their normal user approvals.

Before closure, Lead MUST record every actually created proposal, including
grading-owner and area-specialist drafts, in its owned attempt
`run.json.proposed_scenarios` array. Each entry is a repository-relative string
of the exact form `cbt-chaos/scenarios_v2/<new-ID>/jira-issue.md`, not an ID,
absolute path or object; use `[]` if none were created. Verify the document
exists before recording it. Scoped pull uses these entries to fetch each
specialist-created Jira draft; a missing claimed-created document fails the
pull. Lead MUST NOT create or change `analysis.json` to add these links: that
file remains solely the named grading owner's. Finalize this metadata and
proposal/report links before the mandatory local pull; any later remote
proposal or diagnosis update requires another verified pull.

Verify each returned path exists. The final user summary and run/consolidated
report MUST list every newly created scenario ID, short purpose, actual path,
source-evidence reference and pending-human-review status, including drafts
written by area specialists. State none if none were created; never describe
an unwritten suggestion as a saved draft. Humans review, revise or manually
delete drafts they do not want. Do not automatically delete, prune or archive
them, even if Lead questions their usefulness; preserve them with any review
concerns noted. Do not target the new scenario now, spawn a separate discovery
agent or add another weak-components ledger.

Read this skill's `improvement.md` before every run and consult relevant closed
failures when useful. Request feedback at specialist completion or meaningful
blockers, not by repeated polling during injection. Only Lead edits memory:
accept generic, evidence-backed prevention rules useful on future runs; one
deduplicated bullet, **1–3 lines maximum**, with a short evidence reference.
Refine obsolete lessons rather than accumulate contradictions. Full incidents
stay in run evidence; no useful lesson → no edit. Lessons never weaken safety,
approval or verdict criteria, or expose earlier verdicts to the Analyst.
