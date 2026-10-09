# CBT-I-01: Restart the virtual machine between full and incremental backups

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Exercise Changed Block Tracking checkpoint recovery after a VM restart and verify whether the next backup remains incremental or correctly falls back to a full backup.

## Chaos Target

Virtual machine instance

## Chaos Action

Delete the VMI after the full backup has completed and before the incremental backup begins

## When to Inject Chaos

After a successful full backup and before incremental backup creation

## Injection Signal / Condition

Full backup checkpoint is recorded and no incremental backup exists

## Chaos Duration

Immediate

## Expected Behavior

The VM should restart. Changed Block Tracking should reinitialize and attempt checkpoint redefinition. The next backup should either remain genuinely incremental or follow the documented full-backup fallback. A silent incorrect incremental is a failure.

## Recovery

Automatic VM restart and checkpoint recovery

## How to Verify

Record checkpoint-redefinition state, backup type, events, and restore data. Verify the actual resulting backup chain rather than assuming it is incremental.

## Expected Outcome

Validates the core CBT recovery mechanism after a VM lifecycle restart.

## Priority

P1

## Technical Scenario

vmi-outage

## Chaos Phase

Post-operation / pre-incremental
