# CBT-F-07: Restart storage access during an active full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Determine whether an already-mounted backup destination remains usable when the storage access component is restarted during active writes.

## Chaos Target

HostPath storage CSI node plugin

## Chaos Action

Delete the CSI node plugin pod

## When to Inject Chaos

During the active disk-copy period

## Injection Signal / Condition

Full backup is actively copying

## Chaos Duration

Immediate

## Expected Behavior

The behavior is intentionally being established by the test. The copy may continue because the volume is already mounted, or it may fail cleanly. In either case, the system must not report invalid data as successful.

## Recovery

Automatic CSI plugin restart

## How to Verify

Verify CSI recovery, PVC state, backup result, checkpoint state, backup image integrity, and restore result.

## Expected Outcome

Identifies the actual recovery behavior of active storage I/O after a CSI restart.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Active operation
