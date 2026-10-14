# CBT-T-03: I/O hog threshold (same-device) — find the point where CBT backup degrades or fails

**Purpose:** Sweep same-device I/O contention intensity during the full backup copy to find the degradation/failure threshold of the CBT copy under disk saturation.
## Workflow
Full backup
## Test Objective / Description
Escalate dsync I/O workers on /var/hpvolumes/csi (the SAME /dev/sdb device backing VM disk + backup PVCs) during the active copy until measurable degradation (≥2× baseline) or failure (VM PausedIOError, backup failure); record threshold and no-effect ceiling.
## Chaos Target
The CBT storage device (/dev/sdb via /var/hpvolumes/csi) on d38-h18-000-r660
## Chaos Action
Direct I/O hog pod (R-02 recipe: krkn-hub image, `stress-ng --hdd N --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync` on hostPath /var/hpvolumes/csi) with escalating workers
## When to Inject Chaos
During the active backup copy (Progressing-by-type gate)
## Injection Signal / Condition
Full backup Progressing == True
## Chaos Duration
90 seconds per leg
## Expected Behavior
Low intensity: page-cache-absorbed copy shows no effect (I-04 precedent on buffered writes; R-02 showed +19% only on restore verify at 8 workers). At high dsync intensity: device saturation → copy slowdown; extreme: VM PausedIOError (I-04 r01 ENOSPC-adjacent precedent) or backup failure.
## Recovery
Hog self-terminates at DURATION
## How to Verify
Backup duration vs 52-58s baseline; Done reason; iostat (via oc debug node) device util during window; guest SSH responsiveness; freeze/thaw timings
## Expected Outcome
Documented saturation threshold point for the copy path
## Priority
P2 (campaign-authored)
## Technical Scenario
node-io-hog (direct pod, same-device hostPath)
## Chaos Phase
Active operation

## Sweep legs (single variable, stop at first degradation/failure; each leg fresh RUN_ID)

| Leg | hdd workers | Fixed |
|---|---|---|
| t03a | 8 | R-02 intensity, but during FULL copy (R-02 hit restore only) |
| t03b | 32 | |
| t03c | 64 | |

--hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync --timeout 90 each.
