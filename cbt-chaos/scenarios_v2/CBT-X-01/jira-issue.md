# CBT-X-01: Apply bounded memory pressure during backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full and incremental backup

## Test Objective / Description

Measure backup behavior under controlled memory pressure while ensuring the pressure is low enough to avoid intentionally killing the VM.

## Chaos Target

CBT worker node hosting the VM

## Chaos Action

Generate bounded memory pressure on the node

## When to Inject Chaos

During an active backup copy

## Injection Signal / Condition

Backup is actively copying

## Chaos Duration

90 seconds

## Expected Behavior

Backup may slow down. The launcher VM must not be unintentionally OOM-killed; if it is, the result becomes equivalent to a launcher failure and must be classified separately.

## Recovery

Memory load stops automatically

## How to Verify

Check for OOM kills, backup result, tracker consistency, restored data, and clean follow-up run.

## Expected Outcome

Measures resource pressure while separating graceful degradation from uncontrolled VM termination.

## Priority

P2

## Technical Scenario

node-memory-hog

## Chaos Phase

Active operation
