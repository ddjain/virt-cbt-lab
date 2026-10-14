# Scenario: Delete the VM launcher pod during an active incremental backup

## 1. Identity

- **Scenario ID:** CBT-I-02
- **Jira issue:** CBT-I-02 — "Stop the virtual machine launcher during an incremental backup" (P1, technical scenario: pod-scenarios, phase: active operation)
- **Run family:** incremental-backup workflow, workload-plane disruption

## 2. Objective and hypothesis

**Jira objective:** interrupting the actual incremental data copy must not advance the tracker to an invalid checkpoint; the previous full recovery point must remain usable; the incremental must fail cleanly and be retryable.

**Product question:** if the virt-launcher pod is deleted while the pass-1 incremental backup is actively copying (Progressing=True ∧ Done≠True), does the incremental fail cleanly with the tracker still referencing the full checkpoint, the full backup still restorable, the VM restart, and a retry incremental succeed on the recreated VM?

## 3. Workflow and prerequisites

Two-stage managed lifecycle as I-01: `make e2e TYPE=full` (RHEL 9, default variant, 1000 × 15–20 MiB), then the single planned incremental pass. The disruption targets the incremental stage's active-copy window.

Prerequisites:

- The incremental window is ~16–21 s wide (Progressing flips at copy start — F-11 r01 measured fact) — the trigger's own watcher (1 s cadence, existence-probed compound condition on the p01 backup) can reliably land inside it.
- Launcher pod name resolved live: `virt-launcher-vm-<RUN_ID>-<suffix>` in vm-cbt-demo.
- The workflow's incremental stage fails when the backup fails (the follow-up loop breaks); retry uses a fresh incremental name (p02) via the same stage on the same VM.

## 4. Target and validated disruption

**Target:** the run's virt-launcher pod (the pod hosting the QEMU process performing the CBT incremental copy).

**Action:** `oc delete pod <launcher> -n vm-cbt-demo --grace-period=0 --force` — the pod-scenarios-equivalent direct action (F-13 precedent: krknctl's pod-scenarios cannot express "the launcher of run R while backup B is Progressing"; the deletion is the identical disruption the plugin would apply).

**Condition:** p01 vmbackup exists ∧ Progressing=True ∧ Done≠True (existence probe first — F-11 r02 lesson), launcher pod name non-empty, 1 s cadence. The window (16–21 s) comfortably admits a 1 s-cadence watcher.

**Expected mechanics:** launcher teardown kills QEMU mid-copy → the incremental backup's copy errors → backup terminally fails (Done=True reason failure) → tracker NOT advanced past the full checkpoint → VMI recreated by the VM running strategy → retry incremental (p02) on the restarted VM succeeds and chains to the FULL checkpoint (p01 failed, not counted).

## 5. Verification criteria

- Injection validity: launcher deleted while p01 Progressing=True ∧ Done≠True (timestamps), launcher pod replaced (new suffix), VMI recreated.
- Clean failure: p01 terminal Done=True with a failure reason (not stuck Progressing); no partial/incomplete checkpoint recorded for p01.
- Checkpoint integrity: tracker still references the full checkpoint after the failure; no invalid p01 checkpoint; the retry (p02) chains to the FULL checkpoint; exactly one successful incremental checkpoint.
- Full recovery point usable: restore verification of the full backup PASSes (the workflow's final-pass restore verification covers this via the retry pass chain: full-only restore must match the baseline).
- VM recovery: VMI Running/Ready (new uid); retry incremental Done=True; cumulative restore (full + p02) matches the mutated workload.
- Failure reason recorded from p01 `.status.conditions[Done].reason`.

## 6. Pre-run guards

RUN_ID collision guard (observer pre-create allowed), full stage must exit 0 before the incremental stage launches the watcher, launcher existence in the condition, VMI nodeName determinism (informational).

## 7. Uncertainties

- Whether the workflow's incremental stage retries with p02 automatically on the same `make e2e TYPE=incremental` invocation or requires a second invocation — the trigger loops the stage until the planned pass completes or a retry cap (2 extra attempts) is hit; if the workflow aborts the lifecycle on backup failure, `make e2e TYPE=recover` is the documented recovery path (trigger falls back to it).
- The tracker's exact behavior on a failed incremental (skip vs error event) is an observation, not an assumption.
