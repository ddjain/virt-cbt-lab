# CBT-I-04: Create storage I/O contention during an incremental backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Incremental backup

## Test Objective / Description

Measure whether sustained storage contention slows an incremental backup while preserving its incremental nature and data correctness.

## Chaos Target

CBT storage filesystem on the worker node

## Chaos Action

Generate controlled I/O load on the CBT storage path

## When to Inject Chaos

During the active incremental copy

## Injection Signal / Condition

Incremental backup is actively copying

## Chaos Duration

60 seconds

## Expected Behavior

The incremental backup should take longer than the normal approximately 15-second baseline but should still complete as an incremental backup with the correct changed data.

## Recovery

I/O load stops automatically

## How to Verify

Confirm backup type is incremental, checkpoint is distinct and correct, compare duration with baseline, and verify combined restore hash and marker.

## Expected Outcome

Measures incremental performance under storage contention while validating data correctness.

## Priority

P1

## Technical Scenario

node-io-hog

## Chaos Phase

Active operation
