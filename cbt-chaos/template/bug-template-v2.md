# Bug: <one-line, observable problem — the symptom, not the guessed cause>

> Standalone doc. An engineer with cluster access but no knowledge of this
> harness should be able to read this file alone and reproduce the problem.
> The independent CBT Analyst writes one scenario-root
> `bugs/<defect-slug>.md` per deduplicated defect, adding corroborating runs.
> A confirmed valid injection and an observed required product violation are
> mandatory; do not file bugs for unknown outcomes, injection or harness issues.
> Every claim needs an object field, output or timestamp; root cause may be
> unknown. A draft does not create a Jira issue; never invent a filed key.

## Summary

<2-4 sentences: what broke, what you were doing when it broke (scenario id +
the fault that was injected), and why it matters.>

## Component & Version

| Component | Version / identifier |
|---|---|
| Suspected component | |
| OpenShift | |
| OpenShift Virtualization / KubeVirt | |
| Storage (ODF/Ceph or other) | |
| Krkn / krknctl | |

## Steps to Reproduce

<Exact reproduction steps with sanitized placeholders and explicit safety,
approval, precondition, target UID, fault window and blast-radius boundaries.
Link the scenario's reusable `run.sh` and approved injection helpers (names are
not prescribed), and explain the underlying operations so an engineer without
this repo can understand reproduction. Include a read-only defect check.
Commands describe reproduction, not authorization for a live fault or follow-up.>

1.
2.
3.

## Current Behavior

<Observed violation: exact status/condition/reason, UTC timestamps and object
UIDs, short decisive output quotes, scoped logs and deterministic check results.
Distinguish the expected disruption from the unexpected product failure.>

## Expected Behavior

<What should have happened instead, per the scenario's acceptance criteria.>

## Additional Notes

<Root cause: confirmed / hypothesis / unknown, with supporting evidence.
Record approved bundle/hash reference, independent injection-validity proof,
blast radius, observed recovery and limits, workaround if evidenced, supporting
attempt IDs and links to their `run-report.md`, `analysis.json` and raw evidence.
Reference lifecycle evidence in place. Add corroborating runs to this defect
rather than creating a per-run duplicate. No fix proposal is required.>
