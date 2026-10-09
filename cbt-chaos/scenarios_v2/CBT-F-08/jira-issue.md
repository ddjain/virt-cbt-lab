# CBT-F-08: Run out of space on the full backup destination

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that the backup fails safely when the destination storage reaches capacity, without advancing the checkpoint or treating a partial backup as valid.

## Chaos Target

Full backup destination PVC

## Chaos Action

Fill the destination PVC to approximately 95% capacity

## When to Inject Chaos

After the destination is bound and the backup has started, before the copy completes

## Injection Signal / Condition

Backup is progressing and destination PVC is bound

## Chaos Duration

120 seconds

## Expected Behavior

The backup should hit insufficient-space conditions and terminate as a clean failure. The VM should remain running and the tracker should not advance.

## Recovery

Remove the filler or start a fresh run with a new destination PVC

## How to Verify

Check the failure reason, confirm tracker remains unchanged, verify the partial image is not considered valid, and confirm a fresh backup succeeds.

## Expected Outcome

Confirms safe handling of destination capacity exhaustion and prevents false-success backups.

## Priority

P1

## Technical Scenario

pvc-scenarios

## Chaos Phase

Operation start
