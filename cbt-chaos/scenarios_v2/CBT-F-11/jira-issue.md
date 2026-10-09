# CBT-F-11: Block network traffic to the virtual machine during backup startup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that pod network isolation does not incorrectly interrupt the local backup data path or backup control mechanism.

## Chaos Target

Virtual machine launcher pod network

## Chaos Action

Apply an IP-level network filter to the launcher pod

## When to Inject Chaos

After the backup request starts but before the actual copy begins

## Injection Signal / Condition

Backup is progressing but the copy has not started

## Chaos Duration

60 seconds

## Expected Behavior

The backup is expected to continue because the backup copy and handler-to-launcher control path are node-local rather than dependent on pod IP traffic. The test validates this architectural isolation.

## Recovery

Network filter is removed automatically

## How to Verify

Confirm the pod remains running, backup completes, tracker advances correctly, and restore validation succeeds.

## Expected Outcome

Confirms that the backup data path is independent of pod networking.

## Priority

P2

## Technical Scenario

pod-network-filter

## Chaos Phase

Operation start
