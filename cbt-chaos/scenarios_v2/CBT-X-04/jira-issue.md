# CBT-X-04: Combine storage contention with launcher failure during backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full and incremental backup

## Test Objective / Description

Test a combined failure in which storage is under pressure and the backup execution process is then stopped, verifying that the system still fails cleanly and recovers end-to-end.

## Chaos Target

Virtual machine launcher plus CBT storage filesystem

## Chaos Action

Start controlled storage I/O pressure, then stop the launcher during the same active backup

## When to Inject Chaos

During the active backup copy

## Injection Signal / Condition

Backup is actively copying

## Chaos Duration

90 seconds of I/O load; launcher stopped approximately 20 seconds after load begins

## Expected Behavior

The backup should fail cleanly without advancing the tracker. The VM should recover. A complete clean full and incremental backup/restore cycle should work afterward.

## Recovery

Automatic VM recovery and storage load ends

## How to Verify

Verify node and VM recovery, failure reason, unchanged tracker after the failed backup, then run a complete clean full and incremental workflow with hash and marker validation.

## Expected Outcome

End-to-end combined test for the hardest-to-attribute failure condition; should be run last.

## Priority

P3

## Technical Scenario

pod-scenarios + node-io-hog

## Chaos Phase

Active operation
