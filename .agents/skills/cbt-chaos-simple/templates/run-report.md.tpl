# <SCENARIO_ID> <os>/<backend> leg — run report <RUN_ID>

Scenario: <SCENARIO_ID> (<one-line failure mode from jira-issue.md>) — **<os>, <backend>**.
Executed <date> by `state/<run-script>.sh` (armed injector + `make e2e TYPE=<stage>`).
Control: `runs/<control-run-id>/` (same profile, no chaos, Done=True success, <Ns> copy).
Precheck: `state/<precheck-script>.sh` (collision-clear, trigger parse-validated, sizing OK).

## Attempt history (omit when the first armed run was the valid one)

| run | outcome | cause |
|---|---|---|
| <r01> | <no injection / wrong target / valid> | <trigger never fired / parse error / wrong pod / ...> |

## Injection timeline (UTC, from injector log + virt-launcher logs)

- <hh:mm:ss> — injector armed (pid <pid>), trigger polling every 3s, <timeout>s budget
- <hh:mm:ss> — <target backup/pvc> created (<capacity>, <storageclass>)
- <hh:mm:ss> — virt-launcher "Backup started" (copy begins)
- <hh:mm:ss> — trigger satisfied (<lag> after copy start)
- <hh:mm:ss> — before fault: <measured state, e.g. capacity/used/utilization>
- <hh:mm:ss> — fault applied: <requested/actual/timing, e.g. fill 57.2GiB in 1.3s → 3.1GiB free>
- <hh:mm:ss> — <failure moment, e.g. "Backup has failed" (ENOSPC)>; copy survived <X>s of the
  <control>Ns window (<Y>GiB of <Z>GiB written)
- <hh:mm:ss> — injector cleanup <result> (rc 1 expected when the target pod is gone — r06)

## Product checks (scenario criteria)

| criterion | result |
|---|---|
| <criterion from jira-issue.md / scenario-spec.md> | PASS/FAIL — <evidence> |
| Backup terminates as a failure with a real reason | <e.g. PASS — Done=True, "<signature>"> |
| No checkpoint advanced (tracker latestCheckpoint) | <PASS — null> |
| No usable partial image on destination | <PASS — only kraken.tmp; partial cleaned> |
| VM unaffected (Running, CBT Enabled, agent connected) | <PASS — …> |
| Workflow detects the failure honestly | <PASS — run.json <stage>_failed, e2e exit 2> |

## Classification

<RESILIENT / DEFECT per the scenario-spec's rules, with the deciding evidence.>

**Scope caveat:** <which interleavings/windows this run did NOT exercise, e.g. "kill landed 8.6 s
before copy completion; leader dying mid-cleanup not tested">.

## Findings

1. <What the run proved, keyed to the scenario's question.>
2. <Mechanism notes: self-adjustment, timing, injector rc interpretation.>
3. <Anything that differed from the plan or the control.>

## Preserved state (never clean)

- <Failed backup + PVC + leftover injector artifacts (evidence)>
- `runs/<RUN_ID>/` (run.json <state>, summary.json <verdict>)
- <VM state>

## Evidence files (this directory)

- `trigger-command.txt`, `krknctl.log`/`<injector>.log`, `krknctl.pid`, `injector.rc`, `armed.utc`, `ended.utc`
- `e2e-<stage>.log`, `make-<stage>.rc`
- `verify-output.txt` (criteria checks), `dest-contents.txt` (destination inspection)

## Recovery leg (only if requested)

<PENDING or result: make e2e TYPE=recover → r001 forced full + baseline restore
(file count / bytes / manifest sha256 match), elapsed; summary.json verdict.>
