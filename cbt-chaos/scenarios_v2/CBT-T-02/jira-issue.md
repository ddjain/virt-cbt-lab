# CBT-T-02: Memory hog threshold — find the point where CBT backup degrades or fails

**Purpose:** Sweep memory hog intensity during the full backup copy to find the degradation/failure threshold under node memory starvation.
## Workflow
Full backup
## Test Objective / Description
Escalate memory pressure (VM_BYTES fraction of node memory) during the active copy until measurable degradation (≥2× baseline) or failure (OOM kill of a CBT-relevant process, backup failure, VM pause); record threshold and no-effect ceiling.
## Chaos Target
Node memory (d38-h18-000-r660, ~503GiB — same node as VM/launcher/backup PVCs)
## Chaos Action
Direct memory hog pod (X-01 recipe: emptyDir /work copy + run.sh; HOG_TYPE=memory WORKERS=4 DURATION=90) with escalating VM_BYTES
## When to Inject Chaos
During the active backup copy (Progressing-by-type gate)
## Injection Signal / Condition
Full backup Progressing == True
## Chaos Duration
90 seconds per leg
## Expected Behavior
Below threshold: no effect (X-01: 40% = none, zero OOM). At/above: node memory pressure → kernel OOM killer selects victims (launcher/QEMU/hog), guest memory pressure, copy slowdown. Node has no swap.
## Recovery
Hog self-terminates; OOM-killed processes restart via kubelet
## How to Verify
Backup duration/reason; kernel OOM lines; launcher restartCount + OOMKilled statuses; VMI state; node memory metrics before/during/after
## Expected Outcome
Documented OOM threshold point and victim-selection behavior
## Priority
P2 (campaign-authored)
## Technical Scenario
node-memory-hog (direct pod — krknctl unusable, bugs #9/#10)
## Chaos Phase
Active operation

## Sweep legs (single variable, stop at first failure; each leg fresh RUN_ID)

| Leg | VM_BYTES | Notes |
|---|---|---|
| t02a | 50% | X-01 was 40% no-effect |
| t02b | 70% | Serious pressure |
| t02c | 85% | Expect OOM activity |
| t02d | 95% | Near-total starvation |

Node: ~503GiB; VM guest 4GiB; kubelet/system reserves apply. Hog = stress-ng vm workers (allocates + touches).
