# CBT-I-06: Restart the node backup handler during an incremental backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Verify that interruption of the node-level backup handler during bitmap copying does not silently change an incremental backup into an incorrect full backup.

## Chaos Target

Virtualization handler on the CBT worker node

## Chaos Action

Delete the virtualization handler pod

## When to Inject Chaos

During the active incremental copy

## Injection Signal / Condition

Incremental backup is actively copying

## Chaos Duration

Immediate

## Expected Behavior

The incremental backup should recover or fail cleanly. Any resulting full backup must be explicitly explained by the checkpoint recovery behavior; an unexplained silent change from incremental to full is a finding.

## Recovery

Automatic handler restart

## How to Verify

Record backup type, tracker state, checkpoint-redefinition state, events, and restore correctness.

## Expected Outcome

Specifically tests the integrity of the incremental checkpoint chain under handler interruption.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Active operation
