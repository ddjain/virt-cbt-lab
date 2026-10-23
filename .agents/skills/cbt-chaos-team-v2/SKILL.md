---
name: cbt-chaos-team-v2
description: >
  Dispatch one CBT chaos scenario to the dedicated Sol Lead subagent. Main
  relays human approval and clarification requests; Lead owns preparation,
  execution, independent grading coordination, reporting and verified closeout.
user_invocable: true
arguments:
  - name: request
    description: Scenario ID, intent and optional execution host.
    required: true
---

# CBT Chaos Team v2 — Dispatcher

Main is a dispatcher and human-approval relay, not the execution Lead.
The canonical orchestration procedure is `cbt-chaos-lead-v2`; do not duplicate
it here or run a competing workflow. Do not execute chaos, prepare bundles,
write approval/run/analysis records, grade evidence or pull reports yourself.

Lead and its Chaos Engineer own two standing policies this dispatcher never
overrides or reimplements: (1) every lifecycle/preflight action goes through
the repository's documented `make` interface and `AGENTS.md`'s
agent-operating contract — never a reinvented script or a remembered
command/flag; (2) chaos injection is krknctl-first (native event trigger,
then wrapped krkn), falling back to raw oc/kubectl only when krkn cannot
express the fault, and that fallback requires explicit user consent on the
plain-language plan **before** any script is authored, obtained through the
clarification relay below. If a relayed preparation handoff proposes
oc/kubectl without that prior consent, or proposes a shortcut around an
existing Make target, decline to forward it for approval and tell the user
why.

## Dispatch once

Resolve the requested scenario directory under `cbt-chaos/scenarios_v2/` using
file tools. Preserve the user's exact intent, host and constraints. Do not ask
for information available from repository/configuration; Lead investigates
requirements, missing files and contradictions. Never treat a run request as
bundle approval.

Spawn exactly one `cbt-chaos-lead-sol` via `task`, with a stable unique name.
This is an intentional orchestration handoff, not a parallel research slice.
Supply the assigned agent ID, `main_agent_id: Main`, scenario ID and paths,
original request, execution host if supplied, local/control checkout and any
existing run/approval identities and constraints. Pass paths, not credentials.
Use the local/control checkout as Lead's working directory even for remote
execution, so Lead can perform the verified local report pull itself.

Require Lead to read `skill://cbt-chaos-lead-v2` explicitly if autoload did not
resolve it. If this session's skill snapshot lacks the new URI, use
`.agents/skills/cbt-chaos-lead-v2/SKILL.md` and its sibling `improvement.md`
directly. The project definitions in `.omp/agents/` pin role aliases
(`@cbt_lead` etc., resolved via `.omp/config.yml`), high thinking,
prewalk/advisor disabled, and permit nested Engineer/Analyst delegation.
Check effective routing; overrides or unavailable tools/models must not cause
silent fallback to main, a generic worker or a cheaper model. Default depth 2
supports main → Lead → specialist; insufficient depth blocks the workflow.
Use asynchronous dispatch and parent/child messaging. A blocking spawn cannot
serve approval requests while Lead waits; do not launch live work in that mode.

Keep the returned Lead ID. Reuse that agent through `write agent://<id>` for
follow-ups; do not spawn another Lead because it is waiting, idle or parked.
A hard-aborted Lead must not be blindly replaced: first report interruption,
resolve durable run state and ensure no owned execution is still active.

## Relay approval without taking ownership

Remain available for Lead messages. Use `wait` only while owned jobs are
running; messages/results arrive automatically. An interim `approval_pending`
or `clarification_pending` result is not scenario completion. Relay its
request and resume the same idle/parked Lead with `write agent://<id>`; never
spawn a replacement. Deduplicate the interim request against any identical
message already received so the user is not asked twice. Never poll, create a
dummy waiting process or finish the user request as completed while an answer
or Lead closeout is outstanding.

Accept an `approval_request` only from the assigned Lead, for the dispatched
scenario, with unique `approval_request_id`, matching `lead_agent_id`, complete
non-secret `package` and `bundle_fingerprint`. The protocol and package fields
are defined in the Lead skill's **Relay protocol (approval and clarification)**
section.
Recompute SHA-256 over the package's canonical UTF-8 JSON (`jq -cS .`, including
its final newline). Refuse mismatched/incomplete requests without asking for
approval. Keep one outstanding request and bind its identity to the exact
package; never reuse an earlier response for another bundle.

Present that exact package using structured `ask`: commands, file hashes,
parameters, execution target, condition/window and bounds, target scope and
exclusions, blast radius and rollback. Offer **Approve bundle** / **Do not run**
without recommending approval. Do not silently shorten away safety constraints,
edit the package, substitute parameters or invent a user's answer.

Send `write agent://<lead-id>` a JSON message with:
- `type: "approval_response"`;
- unchanged `approval_request_id`, `lead_agent_id`, `scenario_id`,
  `bundle_fingerprint`;
- `decision: "approve"` only for explicit approval of this exact package,
  otherwise `"reject"` for explicit rejection;
- `answered_at`: actual UTC response time;
- `user_answer`: exact structured-ask answer.

No answer means no approving response. An ambiguous/custom answer must be
clarified, never converted to approval. Tell Lead if the user cancels or changes
scope; a changed package needs a new request. Main relays consent but never
writes `approval.json`: Lead records and revalidates it before execution.
This is a workflow-level guard, not a security sandbox for Bash-capable agents.

For a matching `clarification_request`, present Lead's question/options using
`ask`; return `clarification_response` with matching `request_id`, Lead/scenario
IDs, exact `user_answer` and UTC `answered_at`. Clarification is not approval.

## Deliver the Lead result

Lead alone owns execution, specialist assignments, run records, reports,
retry limits and verified local synchronization. Only its named independent
grading owner writes `analysis.json`. Do not override a verdict or manufacture
missing closeout evidence. Relay the returned verdict, actual local paths,
synchronization result, created proposal IDs/paths and blockers/limits. If Lead
fails or closeout is incomplete, report that explicitly rather than claiming
completion. Scenario execution is not implied by installing this architecture.
