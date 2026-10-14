# Scenario: Delete the backup controller leader during the checkpoint-update gap

## 1. Identity

- **Scenario ID:** CBT-I-03
- **Jira issue:** CBT-I-03 — "Interrupt the controller during the incremental checkpoint update" (P1, technical scenario: pod-scenarios, phase: post-operation transition)
- **Run family:** incremental-backup workflow, control-plane disruption

## 2. Objective and hypothesis

**Jira objective:** a controller restart around the checkpoint update must not leave the tracker in an incomplete or duplicated state; the new leader must finish the tracker update; a harness timeout must be distinguished from a real state-consistency failure.

**Product question:** if the virt-controller leader is killed in the window between the full backup reaching Done and the tracker recording the checkpoint (post-operation transition), does the new leader complete the update exactly once, with correct failover, and does the subsequent incremental pass chain correctly and restore?

## 3. Workflow and prerequisites

Two-stage lifecycle (I-01/I-02 pattern): `make e2e TYPE=full` then `TYPE=incremental` (RHEL 9, default variant, 1000 × 15–20 MiB).

Window analysis (measured facts from prior runs): full backup Done flip and tracker checkpoint update land within the same second (F-13: Done + unmount + attachment-pod delete all in the same second; the tracker write follows immediately). The literal window is sub-second — but the Jira's condition is "full backup succeeded but tracker update is delayed or incomplete". Practical gating (F-13 precedent): superset condition with 1 s cadence — full backup exists ∧ Done=True ∧ tracker's latestCheckpoint ≠ full checkpoint (i.e., update pending). If the update is already complete before the watcher fires (likely, given same-second timing), fall back to the transition's other edge: kill the leader the instant Done flips True (Progressing→Done transition), which still disrupts the controller's reconcile that performs cleanup + checkpoint bookkeeping. Prove post-hoc from events + tracker watch whether the disrupted reconcile spanned the checkpoint write.

Controller facts: deployment virt-controller (2 replicas, jkr6h @ d38-h08, x7svc @ d38-h09), leader via Lease `virt-controller` in ns openshift-cnv (leaseDuration 15 s, renewTime current — x7svc leader at triage). Leader resolution: `.spec.holderIdentity` at condition time (F-13 precedent; krknctl cannot express lease-resolved targets — bug #4 in krknctl-bugs.md).

## 4. Target and validated disruption

**Target:** the current virt-controller leader pod (resolved from the Lease at condition time).

**Action:** `oc delete pod/<leader> -n openshift-cnv --grace-period=0 --force` (pod-scenarios-equivalent direct action, F-13 precedent — the command form `oc delete pod/<name>` is live-tested per I-02 lessons).

**Condition:** full vmbackup Done=True (existence probe first) ∧ tracker latestCheckpoint ≠ full checkpoint name, 1 s cadence, TRIGGERS_TIMEOUT bound. Post-hoc proof from tracker watch + events whether the kill landed before the checkpoint write.

**Expected mechanics:** leader dies mid-reconcile (or just after backup Done) → lease expires/fails over (~15–21 s, F-12 measured) → new leader re-reconciles → backup object re-read → tracker updated exactly once → incremental pass proceeds on the correct checkpoint.

## 5. Verification criteria

- Injection validity: leader resolved from Lease at condition time; deletion timestamp vs full Done timestamp vs tracker checkpoint-write timestamp (from tracker watch stream); old leader name recorded; replacement leader eventually elected.
- Failover: lease holderIdentity changes; gap ≤ ~15–21 s (F-12 baseline); controller pods' restartCount/ready telemetry.
- Tracker consistency: checkpoint recorded EXACTLY once (watch stream shows one MODIFIED with the full checkpoint, no duplicates/flips); no incomplete intermediate state persisted; no CheckpointRedefinitionFailed-class events.
- Incremental chain: p01 proceeds on the full checkpoint (chains to it, not re-based); duration ~16–21 s; type Incremental.
- Restore verification: full-only + cumulative hashes PASS (the incremental stage's final pass runs it).
- Harness-timeout distinction: any tracker delay resolves within the stage's own waits; a timeout is a harness/infra issue, a persistent inconsistent tracker is a product failure.

## 6. Pre-run guards

RUN_ID collision guard (observer pre-create allowed), full stage must exit 0, tracker exists, leader resolvable, second vmbackup watch for p01.

## 7. Uncertainties

- The literal checkpoint-update window may close before the 1 s watcher fires (same-second writes). Mitigation: dual condition — fire on the update-pending window if caught, else on the Done flip (both are the same reconcile loop; both test leader handoff around the tracker update). The tracker watch stream provides post-hoc proof of which edge was hit.
- If the full stage's own `wait_for_checkpoint_in_tracker` (20 × 1 s) outlives the failover gap, the stage may fail on tracker timeout — that is the Jira's "harness timeout must be distinguished from actual failure" clause; handle by re-running the incremental stage after failover settles, and record the distinction.
