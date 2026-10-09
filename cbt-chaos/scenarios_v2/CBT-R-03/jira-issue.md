# CBT-R-03: Restart storage access before restore volumes are mounted

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Restore verification

## Test Objective / Description

Verify that restore verification recovers when storage access is interrupted before its read-only backup volumes are mounted.

## Chaos Target

HostPath storage CSI node plugin

## Chaos Action

Delete the CSI node plugin pod before restore volumes are mounted

## When to Inject Chaos

After restore verification pod is created but before it starts using the PVCs

## Injection Signal / Condition

Restore pod is pending waiting for volume access

## Chaos Duration

Immediate

## Expected Behavior

The restore pod should remain pending while storage access is unavailable and should recover after the CSI plugin returns. If it cannot recover, it should fail cleanly without modifying artifacts.

## Recovery

Automatic CSI plugin restart

## How to Verify

Confirm CSI recovery, backup PVCs remain unchanged, restore pod eventually succeeds or fails cleanly, and rerun produces identical hashes.

## Expected Outcome

Validates restore startup behavior during a transient storage-access outage.

## Priority

P2

## Technical Scenario

pod-scenarios

## Chaos Phase

Restore startup
