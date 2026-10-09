# CBT-I-05: Run out of space on the incremental backup destination

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Verify that incremental backup capacity exhaustion fails safely and leaves the previous full checkpoint and artifact usable.

## Chaos Target

Incremental backup destination PVC

## Chaos Action

Fill the incremental destination PVC to approximately 95% capacity

## When to Inject Chaos

After incremental backup starts and its destination is bound

## Injection Signal / Condition

Incremental backup is progressing

## Chaos Duration

120 seconds

## Expected Behavior

The incremental backup should fail cleanly. The tracker must continue to reference the previous full checkpoint, and the full backup artifact must remain restorable.

## Recovery

Use a fresh destination PVC and rerun

## How to Verify

Verify failure state, unchanged full checkpoint, valid full restore without the incremental marker, and successful retry.

## Expected Outcome

Confirms that storage exhaustion cannot invalidate the last known-good recovery point.

## Priority

P1

## Technical Scenario

pvc-scenarios

## Chaos Phase

Operation start
