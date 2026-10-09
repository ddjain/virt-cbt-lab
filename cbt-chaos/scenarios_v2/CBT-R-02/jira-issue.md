# CBT-R-02: Create storage I/O contention during restore verification

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Restore verification

## Test Objective / Description

Measure how storage contention affects offline restore conversion without changing the stored backup artifacts.

## Chaos Target

CBT storage filesystem on the worker node

## Chaos Action

Generate controlled I/O load on the CBT storage path

## When to Inject Chaos

While restore verification is converting or rebasing the images

## Injection Signal / Condition

Restore verification pod is running

## Chaos Duration

180 seconds

## Expected Behavior

Restore processing should slow down but complete within the existing verification timeout and produce the same hashes and marker results.

## Recovery

I/O load stops automatically

## How to Verify

Confirm restore succeeds, compare full and combined hashes with baseline, verify marker semantics, and confirm backup artifacts are unchanged.

## Expected Outcome

Measures restore performance under storage contention while protecting data correctness.

## Priority

P2

## Technical Scenario

node-io-hog

## Chaos Phase

Active restore
