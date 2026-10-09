# CBT-R-01: Stop restore verification while rebuilding the backup image

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Restore verification

## Test Objective / Description

Verify that interrupting the restore verification process does not alter the backup artifacts and that verification can be safely rerun.

## Chaos Target

Restore verification pod

## Chaos Action

Delete the restore verification pod during conversion or rebase

## When to Inject Chaos

While restore verification is running

## Injection Signal / Condition

Restore verification pod is running

## Chaos Duration

Immediate

## Expected Behavior

The verification should stop. Because backup PVCs are mounted read-only, the backup artifacts should remain unchanged.

## Recovery

Rerun restore verification

## How to Verify

Confirm backup PVCs remain bound and unchanged, then rerun verification and compare hashes and marker semantics with the baseline.

## Expected Outcome

Shows that restore validation is isolated from backup artifact integrity.

## Priority

P2

## Technical Scenario

pod-scenarios

## Chaos Phase

Active restore
