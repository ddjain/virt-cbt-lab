# CBT-F-10: Create CPU pressure during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Measure the effect of node CPU pressure on backup completion and data correctness.

## Chaos Target

CBT worker node hosting the VM

## Chaos Action

Generate controlled CPU load on the node

## When to Inject Chaos

During the active disk-copy period

## Injection Signal / Condition

Full backup is actively copying

## Chaos Duration

90 seconds

## Expected Behavior

The backup may take longer and freeze/thaw may produce a warning, but the operation should complete with correct backup data.

## Recovery

CPU load stops automatically

## How to Verify

Confirm node and VM remain healthy, record duration and any warning, then validate the restored data.

## Expected Outcome

Measures resilience to compute contention without introducing uncontrolled VM failure.

## Priority

P2

## Technical Scenario

node-cpu-hog

## Chaos Phase

Active operation
