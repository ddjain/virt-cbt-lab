# [Bug | Improvement]: <specific observable problem or requested contract>

> Jira-ready draft. Choose **Bug** only for a demonstrated violation of an established contract; choose **Improvement** for an ambiguous contract or requested behavior. Keep CBT product and test-harness issues in separate tickets. Do not invent a Jira key, claim submission, or mark an unproven cause as fact.

| Field | Value |
|---|---|
| Issue type | <Bug or Improvement> |
| Owning component | <product API/controller, test observer, etc.> |
| Priority | <proposed severity with impact, or unassigned pending triage; distinguish scenario priority> |
| Status / confidence | <confirmed behavior, contract question, reproduction limits> |
| Related scenario / execution | <scenario ID, unique run label, UTC date> |
| Affected versions | <observed OpenShift, OpenShift Virtualization/KubeVirt, oc, guest OS, storage, harness version if available; say “not recorded” rather than guess> |

## Description (plain language)

<What a user/engineer sees, why it matters, and whether this is a proven defect or a request for clarification.>

## Steps to reproduce

> Use a dedicated cluster and new run-scoped names. Include only commands actually validated or make clear when commands are illustrative. Never include credentials, private hostnames/paths, broad selectors, or namespace cleanup. State prerequisites and how to identify the exact target. For an injection test, do not treat backup creation as proof of active copying.

1. <Setup and baseline.>
2. <Repro action, exact condition and safely scoped command(s) if necessary.>
3. <Read-only inspection commands, with namespace/object placeholders explained.>

## Actual result

<Exact condition/status **and reason**, checkpoint/tracker values, VM/CBT/data result, affected UID, UTC timestamps, and whether the observation was independent or inferred.>

## Expected result / requested outcome

<Established product contract, or desired clarified contract/guardrail. State how acceptance will be checked.>

## Impact and workaround

<Consumer risk, frequency/reproducibility, blast radius, supported mitigation, and what remains unknown.>

## Additional information and evidence

- <Sanitized, run-scoped object/event/log excerpt and UTC timing; repository-relative evidence links may be used in internal tickets.>
- <Version source and any contradictory evidence.>
- <Independent-observation gaps and confidence limits. Do not present successful workflow exit or `Done=True` alone as product success.>

## Acceptance criteria

- <Observable product behavior or test-harness invariant.>
- <Regression check covering the original failure mode and relevant boundary.>

## Triage questions

- <Only questions whose answers affect Bug versus Improvement classification or remediation.>
