# CBT-F-13: Stop the controller during backup cleanup and checkpoint update

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Test the narrow transition window after the data copy finishes but before cleanup and checkpoint state updates are complete.

## Chaos Target

Current backup controller leader

## Chaos Action

Delete the controller leader during cleanup

## When to Inject Chaos

Immediately after the backup copy reports successful completion but before the backup becomes fully complete

## Injection Signal / Condition

Backup copy completed but final status has not yet been recorded

## Chaos Duration

Immediate

## Expected Behavior

The new controller should complete volume cleanup and update the tracker exactly once. No orphaned temporary volume attachment or duplicate checkpoint should remain.

## Recovery

Automatic controller leader election

## How to Verify

Confirm no temporary hotplug pod remains, no stale utility volume remains, tracker advances exactly once, backup succeeds, and a subsequent incremental backup works.

## Expected Outcome

Tests one of the most sensitive state-transition points where a successful copy becomes a durable recovery point.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Transition
