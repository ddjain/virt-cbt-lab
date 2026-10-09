# CBT-F-12: Block controller access to the Kubernetes API during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that controller failover can recover from loss of API connectivity to the current controller leader without creating duplicate checkpoint state.

## Chaos Target

Current backup controller leader network access

## Chaos Action

Block API-server traffic from the controller leader

## When to Inject Chaos

While the backup is being reconciled

## Injection Signal / Condition

Backup is progressing

## Chaos Duration

60 seconds

## Expected Behavior

The isolated leader should lose its lease and the standby controller should take over. The backup should complete with one checkpoint and no duplicate state.

## Recovery

Network filter is removed; leader election settles

## How to Verify

Confirm new leader, both replicas ready, exactly one checkpoint, correct tracker update, successful restore, and successful subsequent incremental backup.

## Expected Outcome

Validates controller failover when the active leader temporarily loses API connectivity.

## Priority

P2

## Technical Scenario

pod-network-filter

## Chaos Phase

Operation start
