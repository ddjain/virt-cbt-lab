# CBT-F-05: Restart the node backup handler during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify behavior when the node-level virtualization handler responsible for backup state reporting is interrupted during an active full backup.

## Chaos Target

Virtualization handler on the CBT worker node

## Chaos Action

Delete the virtualization handler pod on the CBT node

## When to Inject Chaos

During the active disk-copy period

## Injection Signal / Condition

Full backup is actively copying

## Chaos Duration

Immediate

## Expected Behavior

The system may either complete after the handler returns or fail with a clear backup-status-lost error. A successful-looking backup must never advance the checkpoint incorrectly.

## Recovery

Automatic DaemonSet recovery

## How to Verify

Confirm the handler returns, inspect the final backup result, verify the tracker is consistent, and run a clean follow-up backup.

## Expected Outcome

Confirms safe handling of node-level control-plane interruption.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Active operation
