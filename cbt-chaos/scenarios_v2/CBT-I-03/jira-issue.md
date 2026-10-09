# CBT-I-03: Interrupt the controller during the incremental checkpoint update

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Verify that a controller restart around the checkpoint update does not leave the tracker in an incomplete or duplicated state.

## Chaos Target

Backup controller leader

## Chaos Action

Delete the controller leader during the checkpoint-update gap

## When to Inject Chaos

After the full backup completes but before its checkpoint is visible to the incremental workflow

## Injection Signal / Condition

Full backup succeeded but tracker update is delayed or incomplete

## Chaos Duration

Immediate

## Expected Behavior

The new controller should finish the tracker update. A harness timeout must be distinguished from an actual KubeVirt state-consistency failure.

## Recovery

Automatic controller leader election

## How to Verify

Measure failover time, confirm tracker eventually contains the correct checkpoint exactly once, then perform an incremental restore validation.

## Expected Outcome

Tests consistency of the handoff between backup completion and durable tracker state.

## Priority

P1

## Technical Scenario

pod-scenarios

## Chaos Phase

Post-operation transition
