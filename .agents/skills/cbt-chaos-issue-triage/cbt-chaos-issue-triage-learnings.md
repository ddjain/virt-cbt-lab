# CBT Chaos Issue Triage Learnings

Reusable, evidence-backed guidance for resolving CBT issues, designing scenario artifacts, and troubleshooting triage validation. This file is separate from run-execution learnings so each skill loads only the knowledge relevant to its task.

## How to maintain this file

- Read only when performing CBT issue triage or troubleshooting triage validation.
- Add a dated entry only when triage or validation establishes reusable, actionable guidance.
- Include the affected scenario/stage, observed issue, resolution or validated workaround, and sanitized repository-relative evidence path(s).
- Keep entries concise and generally applicable; keep issue-specific decisions and outcomes in that scenario's artifacts.
- Never include secrets, credential values, private hostnames, environment-specific absolute paths, or unsupported speculation.
- When newer evidence invalidates a lesson, correct or remove the stale guidance rather than accumulating contradictory advice.
- Add entries only after the triage closeout confirms an important, generalizable learning; check for duplicates first and prefer updating an existing entry.
- Do not create a new learning file. If no appropriate existing file exists, ask before creating one.
- If a learning implies changing a main skill, propose the exact change and get user confirmation before editing that skill.

## Learnings

### 2026-10-10 — Krkn pod-scenarios selector semantics

In the inspected registry, `--name-pattern` filters pods only when `--pod-label` is omitted. Combining them can leave the exact-name filter ineffective and broaden the eligible target set. For dynamic leader or node-handler targeting, resolve and verify labels/readiness/node on the host, then pass Krkn the exact name pattern (and `--node-names` where needed) without `--pod-label`; dry-run the final arguments.

Evidence: `cbt-chaos/scenarios_v2/CBT-F-03/scenario-spec.md` §§3–4, `cbt-chaos/scenarios_v2/CBT-F-04/scenario-spec.md` §3, and `cbt-chaos/scenarios_v2/CBT-F-05/scenario-spec.md` §4.
