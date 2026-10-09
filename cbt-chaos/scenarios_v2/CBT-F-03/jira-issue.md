# CBT-F-03: Restart the backup controller when a full backup is starting

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that the backup controller can fail over to its standby instance without creating duplicate backups or checkpoints.

## Chaos Target

Current backup controller leader

## Chaos Action

Delete the current controller leader pod

## When to Inject Chaos

After the backup request is accepted and is being reconciled, before the operation is complete

## Injection Signal / Condition

Backup request is progressing and has no final result

## Chaos Duration

Immediate

## Expected Behavior

Leadership should move to the standby controller. Backup reconciliation should resume and the full backup should complete successfully without duplicate checkpoints.

## Recovery

Automatic controller leader election

## How to Verify

Confirm a new leader is elected, both controller replicas become ready, exactly one checkpoint is created, the tracker is updated once, and the backup can be restored.

## Expected Outcome

Demonstrates controller failover without duplicate or lost backup state.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Operation start
