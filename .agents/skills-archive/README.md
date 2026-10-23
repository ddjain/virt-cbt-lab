# Archived v1 CBT chaos skills

These 14 skills belonged to the earlier `cbt-chaos-team` worker-committee
architecture (a Lead plus short-lived Preflight/Trigger/Observer/Recovery
workers, three blind Checkers, and post-run Run Analyst/Flow Analyst/
Scenario Improver/Variation Decider agents). They are superseded by the
simplified v2 architecture: `cbt-chaos-team-v2` dispatches a single
`cbt-chaos-lead-v2` Lead, which owns orchestration/execution/reporting
directly and delegates only to `cbt-chaos-trigger-preparer-v2` (Engineer)
and `cbt-chaos-analyst-v2` (Analyst) — see `docs/agent-workflow-audit.md`.

Moved here (not deleted) on 2026-10-23 so the history and design intent
stay available for reference. Nothing in `.agents/skills/` or `.omp/agents/`
loads or references these; they are not part of the active workflow.

Kept active despite not being named `-v2` (verified still in use):
`cbt-chaos-run`, `cbt-chaos-issue-triage`, `krkn-scenario`.
