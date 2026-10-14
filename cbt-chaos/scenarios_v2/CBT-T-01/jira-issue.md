# CBT-T-01: CPU hog threshold — find the point where CBT backup degrades or fails

**Purpose:** Sweep CPU hog intensity during the full backup copy to find the degradation/failure threshold of the CBT backup process under CPU starvation, providing engineering a concrete sensitivity number.
## Workflow
Full backup
## Test Objective / Description
Escalate CPU pressure (workers/load) during the active copy until the backup measurably degrades (≥2× baseline duration) or fails; record the threshold point and no-effect ceiling.
## Chaos Target
Node CPU (d38-h18-000-r660, 112 cores — same node as VM/launcher/backup PVCs)
## Chaos Action
Direct CPU hog pod (krkn-hub image, HOG_TYPE=cpu CPU_METHOD=all) with escalating WORKERS/LOAD_PERCENTAGE
## When to Inject Chaos
During the active backup copy (Progressing-by-type gate)
## Injection Signal / Condition
Full backup Progressing == True
## Chaos Duration
90 seconds per leg
## Expected Behavior
Below threshold: no measurable effect (F-10 precedent: 32 workers @60% = none). At/above threshold: copy slowdown, freeze/thaw stretch, guest unresponsiveness; extreme: backup failure or VM pause.
## Recovery
Hog self-terminates at DURATION
## How to Verify
Backup duration vs 52-58s baseline; Done reason; freeze/thaw timings; guest SSH probe; launcher restartCount; node load
## Expected Outcome
A documented threshold point (or proof of absorption across the full range)
## Priority
P2 (campaign-authored)
## Technical Scenario
node-cpu-hog (direct pod — krknctl hog unusable in-cluster, bugs #1/#10)
## Chaos Phase
Active operation

## Sweep legs (single variable, stop at first degradation/failure)

| Leg | WORKERS | LOAD_PERCENTAGE | Rationale |
|---|---|---|---|
| t01a | 32 | 100 | F-10 was 32@60% no-effect; raise load to full |
| t01b | 64 | 100 | Over half the cores |
| t01c | 96 | 100 | Most cores |
| t01d | 112 | 100 | Every core (QEMU/virt-launcher/handler compete) |

DURATION=90 each; CPU_METHOD=all. Each leg = fresh RUN_ID (fresh VM + full backup).
