# CBT-X-03: Block all network traffic to the virtual machine during the backup copy

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Confirm that blocking IP traffic to the launcher does not interrupt the node-local backup copy and identify the effect on guest access used by the test harness.

## Chaos Target

Virtual machine launcher pod network

## Chaos Action

Block all IP traffic to the launcher pod

## When to Inject Chaos

During the active disk-copy period

## Injection Signal / Condition

Full backup is actively copying

## Chaos Duration

45 seconds

## Expected Behavior

The backup copy is expected to continue. Guest SSH used by the test harness may stop working temporarily, but this should not affect the local backup data path.

## Recovery

Network traffic is restored automatically

## How to Verify

Confirm launcher remains running, backup succeeds, tracker advances, restore data is correct, and guest access recovers.

## Expected Outcome

Demonstrates that backup data movement is independent of pod networking.

## Priority

P2

## Technical Scenario

application-outages

## Chaos Phase

Active operation
