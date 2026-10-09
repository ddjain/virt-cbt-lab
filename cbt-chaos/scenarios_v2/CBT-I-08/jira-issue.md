# CBT-I-08: Stop only the backup execution container during an incremental backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Verify container-level interruption during an incremental copy and compare it with complete launcher-pod interruption.

## Chaos Target

Compute container inside the virtual machine launcher

## Chaos Action

Stop or signal the compute container

## When to Inject Chaos

During the active incremental copy

## Injection Signal / Condition

Incremental backup is actively copying

## Chaos Duration

Immediate

## Expected Behavior

The incremental backup should fail cleanly and the tracker should remain on the previous valid checkpoint. VM recovery should restore the CBT state.

## Recovery

Automatic VM recovery

## How to Verify

Compare pod identity, backup result, tracker checkpoint, VM recovery, and retry restore validation.

## Expected Outcome

Confirms safe handling when only the actual backup execution process is interrupted.

## Priority

P2

## Technical Scenario

container-scenarios

## Chaos Phase

Active operation
