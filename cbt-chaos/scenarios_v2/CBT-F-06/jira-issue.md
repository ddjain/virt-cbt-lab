# CBT-F-06: Restart storage access before the backup destination is attached

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that temporary loss of the storage access component delays destination provisioning and hotplugging but recovers without corrupting the backup workflow.

## Chaos Target

HostPath storage CSI node plugin

## Chaos Action

Delete the CSI node plugin pod

## When to Inject Chaos

After the backup starts but before the destination volume is bound and attached

## Injection Signal / Condition

Backup is progressing and destination PVC is not yet bound

## Chaos Duration

Immediate

## Expected Behavior

Destination provisioning or hotplugging should pause while the CSI component restarts. Once storage access returns, the destination should bind, attach, and the backup should continue or fail cleanly if the delay exceeds controller tolerance.

## Recovery

Automatic CSI plugin restart

## How to Verify

Confirm CSI recovery, destination PVC binding, successful volume attachment, final backup state, and tracker consistency.

## Expected Outcome

Shows whether the storage attachment path recovers cleanly from a transient outage.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Operation start
