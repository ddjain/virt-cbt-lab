# CBT-F-09: Create sustained storage I/O contention during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Measure how the backup behaves when the underlying CBT storage filesystem is under sustained I/O pressure.

## Chaos Target

CBT storage filesystem on the worker node

## Chaos Action

Generate controlled I/O load on the CBT storage path

## When to Inject Chaos

During the active disk-copy period

## Injection Signal / Condition

Full backup is actively copying

## Chaos Duration

90 seconds

## Expected Behavior

The backup should take longer than the normal approximately 29-second baseline but should still complete successfully and produce correct data.

## Recovery

I/O load stops automatically

## How to Verify

Compare backup duration with the baseline, confirm successful completion and checkpoint advancement, and verify restored data matches the expected hash.

## Expected Outcome

Measures performance degradation while preserving backup correctness.

## Priority

P1

## Technical Scenario

node-io-hog

## Chaos Phase

Active operation
