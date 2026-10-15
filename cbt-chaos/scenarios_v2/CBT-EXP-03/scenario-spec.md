# Scenario: EXP-3 — Repeated virt-controller leader deletions at the backup completion boundary

## 1. Identity

- **Experiment ID:** EXP-3 (adaptive)
- **Hypothesis source:** kubevirt source analysis + campaign cross-run observation. Source: `execute()` uses full UpdateStatus from informer cache (a second worker with a stale copy can overwrite a just-written terminal condition); `cleanupVMIState` persists BEFORE `resolveCompletion`'s Done condition — a controller crash in that gap can produce `SourceLost` for a completed backup while the tracker already advanced. Campaign observation: transient `VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` warning event at the success instant on 4/5 runs — a stale-reconcile signature.
- **Differentiation from CBT-F-13** (single leader kill at the same boundary, PASS): EXP-3 runs 3 independent legs (fresh VM each) with kill timing jittered at boundary+0/+1/+2 s, and its PRIMARY measurement is whether the failure signal is event-only (misleading signal) or a condition flip (terminal state overwritten — a reportable defect).

## 2. Objective / defect hypothesis

Deleting the virt-controller leader pod inside the VMI-state-cleanup→Done window of a full backup, repeatedly and at jittered offsets, either reproduces the observed stale-reconcile race deterministically (condition flip: Done/reason changes after first terminal observation, or SourceLost-after-Done persists) or excludes it at n=3 (event-only transients that self-heal). Secondary: chain integrity (incremental + restore) under a raced completion.

## 3. Workflow

Three legs, fresh lifecycle each (`<RUN_ID>-l1..l3`): `make e2e TYPE=full` with a background watcher polling the leg's backup at 1 s; when Progressing flips from True to not-True (completion boundary), sleep the leg's offset (0/1/2 s), delete the controller leader (resolved live from the virt-controller lease), then let the e2e finish; capture full condition/event timeline; `make e2e TYPE=incremental` + restore verification on the same VM. RHEL 9, HostPath variant, 1000-file base workload.

## 4. Injection

- **Target:** virt-controller leader pod (openshift-cnv), resolved from the `virt-controller` Lease at action time.
- **Action:** `oc delete pod <leader> --wait=false`.
- **Signal:** backup Progressing True→not-True (the cleanup→Done gap opens), 1 s poll.
- **Window:** boundary + {0,1,2} s per leg.
- **Recovery:** automatic (deployment recreates the replica; standby takes the lease).

## 5. Measurements / classification

- Per leg: kill executed (leader name, time, offset); every backup condition transition and event with timestamps (legN-final-backup.yaml, legN-events.txt); whether any failure condition/event appears AFTER the first Done=True observation (condition flip = defect; event-only = misleading signal); final Done reason; incremental chain; restore hashes.
- PASS (product resilient): all legs complete with Done/success, no condition flip, chain + restores pass (event-only transients recorded as the known cross-run observation).
- FAIL: any leg's terminal condition overwritten after first observation, persistent SourceLost-after-Done, stuck backup, or restore mismatch.

## 6. Blast radius / safety

Leader deletion affects the shared virt-controller deployment (2 replicas; standby takes over — F-12/F-13 precedent shows backup lifecycles survive). Blast radius is a transient controller gap of seconds; no data-plane impact. Campaign VMs in the namespace are idle. Run-scoped resources only.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-03/runs/<RUN_ID>/`: trigger.log, legN-kill-result.txt, legN-final-backup.yaml, legN-events.txt, legN-tracker.yaml, observer streams; lifecycle JSON under `runs/<RUN_ID>-lN/`.
