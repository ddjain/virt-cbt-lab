# CBT-I-02: Stop the virtual machine launcher during an incremental backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Verify that interrupting the actual incremental data copy does not advance the tracker to an invalid checkpoint and that the previous full recovery point remains usable.

## Chaos Target

Virtual machine launcher pod

## Chaos Action

Delete the launcher pod

## When to Inject Chaos

During the active incremental disk-copy period

## Injection Signal / Condition

Incremental backup is actively copying

## Chaos Duration

Immediate

## Expected Behavior

The incremental backup should fail cleanly. The tracker must continue to reference the previous successful full checkpoint. The VM should restart and the incremental operation can be retried.

## Recovery

Automatic VM restart followed by retry

## How to Verify

Confirm failure reason, unchanged full checkpoint, VM recovery, successful restoration of the original full backup, and successful retry.

## Expected Outcome

Confirms that an interrupted incremental cannot corrupt the checkpoint chain.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Active operation
