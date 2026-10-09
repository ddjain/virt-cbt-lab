# CBT-F-02: Stop only the backup execution container during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Determine whether stopping only the container that performs the backup produces the same safe failure behavior as stopping the entire launcher pod.

## Chaos Target

The compute container inside the virtual machine launcher pod

## Chaos Action

Stop or signal the compute container

## When to Inject Chaos

During the active disk-copy period

## Injection Signal / Condition

Backup is actively copying data

## Chaos Duration

Immediate

## Expected Behavior

The full backup should fail cleanly, the checkpoint should remain unchanged, and the VM should recover. The test also determines whether container-level disruption differs from pod-level disruption.

## Recovery

Automatic VM/container recovery

## How to Verify

Compare pod identity before and after, inspect the backup result and checkpoint, confirm Changed Block Tracking is enabled, then rerun backup and restore.

## Expected Outcome

Confirms that a failure at the actual backup execution process is handled consistently.

## Priority

P1

## Technical Scenario

container-scenarios

## Chaos Phase

Active operation
