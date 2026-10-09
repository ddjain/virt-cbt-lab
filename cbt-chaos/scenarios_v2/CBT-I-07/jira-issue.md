# CBT-I-07: Disable the guest agent before an incremental backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Verify the documented best-effort behavior when the guest agent cannot freeze and thaw the VM filesystem during backup.

## Chaos Target

Guest qemu guest agent inside the VM

## Chaos Action

Stop the guest agent from inside the VM, then run the incremental backup

## When to Inject Chaos

Before the incremental backup begins

## Injection Signal / Condition

VM is ready and no backup is in progress

## Chaos Duration

Until guest agent is restarted

## Expected Behavior

The backup should complete with a warning rather than fail because freeze/thaw is best effort. The resulting backup should remain data-correct for the synchronized test data.

## Recovery

Restart the guest agent

## How to Verify

Confirm guest-agent disconnected state, warning event, successful incremental result, combined restore hash, marker presence, and clean follow-up backup.

## Expected Outcome

Validates backup consistency behavior when application/filesystem quiescing is unavailable.

## Priority

P2

## Technical Scenario

No direct Krkn scenario

## Chaos Phase

Pre-condition
