# CBT-F-04: Restart the backup controller during the active disk copy

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that a controller restart during the actual copy does not interrupt the data copy and that the new controller can complete reconciliation correctly.

## Chaos Target

Current backup controller leader

## Chaos Action

Delete the current controller leader pod

## When to Inject Chaos

While the full backup is actively copying data

## Injection Signal / Condition

Backup is actively copying

## Chaos Duration

Immediate

## Expected Behavior

The disk copy should continue because it runs in the virtual machine launcher. The new controller should detect completion, clean up the temporary attachment, update the tracker, and mark the backup successful.

## Recovery

Automatic controller leader election

## How to Verify

Confirm leader failover, successful backup completion, one tracker update, cleanup of temporary volume attachment, and successful restore.

## Expected Outcome

Shows separation between the data-copy process and controller reconciliation.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Active operation
