# CBT-F-01: Stop the virtual machine backup process during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that an in-progress full backup fails safely when the component performing the actual disk copy is stopped, without advancing the backup checkpoint or corrupting the VM state.

## Chaos Target

Virtual machine launcher pod running the backup

## Chaos Action

Delete the launcher pod

## When to Inject Chaos

During the active disk-copy period, after the backup has started and before it completes

## Injection Signal / Condition

Backup is actively copying data

## Chaos Duration

Immediate

## Expected Behavior

The backup should report a clear failure. The backup checkpoint must not advance. The VM should restart and Changed Block Tracking should return to its enabled state.

## Recovery

Automatic VM restart; run a fresh full backup to confirm recovery.

## How to Verify

Check backup result and failure reason, confirm checkpoint did not advance, confirm VM and Changed Block Tracking recover, then perform a fresh backup and restore validation.

## Expected Outcome

The system must fail safely rather than report a successful backup with an invalid or incomplete recovery point.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Active operation
