# CBT-X-02: Restart the worker node kubelet during a full backup

**Purpose:** Validate that full backup, incremental backup, and restore workflows remain data-correct, state-consistent, and recoverable when key control-plane, execution, storage, resource, and network dependencies are disrupted. Test descriptions are written for both engineering and project-management review.

## Workflow

Full backup

## Test Objective / Description

Verify that restarting kubelet temporarily affects node management and status reporting without unnecessarily restarting the running VM or interrupting the backup.

## Chaos Target

Kubelet on the CBT worker node

## Chaos Action

Restart kubelet on the worker node

## When to Inject Chaos

During the active backup copy

## Injection Signal / Condition

Backup is actively copying

## Chaos Duration

Scenario-defined

## Expected Behavior

The running VM and backup should continue. Pod status reporting may pause and then recover. The test must first validate the scenario in dry-run mode because the environment is bare metal.

## Recovery

Kubelet restarts automatically

## How to Verify

Confirm node returns Ready, launcher pod identity and restart count remain unchanged, backup succeeds, tracker advances once, and restore validation passes.

## Expected Outcome

Validates node-management recovery without intentionally disrupting the VM workload.

## Priority

P3

## Technical Scenario

node-scenarios

## Chaos Phase

Active operation
