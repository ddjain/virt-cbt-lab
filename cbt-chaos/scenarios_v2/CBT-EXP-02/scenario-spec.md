# Scenario: EXP-2 — Delete the full-backup CustomResource mid-copy (push-mode abort semantics)

## 1. Identity

- **Experiment ID:** EXP-2 (adaptive)
- **Hypothesis source:** kubevirt source analysis: CR deletion mid-copy triggers the Abort command path (`DOMAIN_JOB_CANCELLED` → backup Failed); the hotplugged target PVC is detached only by controller cleanup; partial `.qcow2` files on the target PVC are cleaned only when `BackupBegin` itself fails (not mid-copy); a lost cancel event can leave the CR hanging with a stuck finalizer. No existing campaign scenario deletes a backup CR mid-copy (F-02/I-02 stop components, not the CR).
- **Ranked #2 new-defect candidate by the campaign Judge** (abort-path cleanup is a genuinely untested surface: no safety unfreeze, orphaned hotplug + frozen VMI plausible).

## 2. Objective / defect hypothesis

Deleting the backup CR ~20 s into an active full copy must: remove the finalizer promptly (no stuck `Aborting`), leave the VMI healthy and unfrozen, detach the hotplugged target PVC, retain a consistent tracker (no checkpoint from an unconfirmed backup), leave identifiable partial-image residue on the target PVC (recorded, not necessarily cleaned), and allow a fresh-named full backup on the same VM to complete and restore-verify. Failure modes: stuck finalizer; leaked hotplug attachment; frozen VMI; tracker advanced from the aborted backup (silent chain corruption); recovery backup failing.

## 3. Workflow

`make vm-setup` (fresh VM + baseline workload, no backup) → create the backup CR via the workflow's own manifest templating → wait for active copy (Progressing=True ∧ Done≠True) → sleep 20 s (mid-copy) → `oc delete vmbackup` → measure deletion velocity (finalizer removal, 300 s stuck threshold) → capture VMI/Paused/hotplug-attachment/tracker state + target-PVC residue listing → `make e2e TYPE=recover VM=<vm>` (fresh-named same-VM full backup `vm-recovery-full-<RUN_ID>-<attempt>` through the existing tracker + restore verification).

## 4. Injection

- **Target:** the run's VirtualMachineBackup object.
- **Action:** `oc delete vmbackup vm-backup-<RUN_ID>` at copy+20 s (copy is ~53 s; verified not-Done at deletion instant, else harness-invalid exit 4).
- **Signal:** active-copy compound condition (Progressing=True ∧ Done≠True, 1 s poll).
- **Recovery:** controller abort path (automatic); recovery oracle = same-VM fresh-named full backup.

## 5. Measurements / classification

- Deletion velocity (request → object gone); stuck-finalizer flag at 300 s.
- VMI phase + Paused condition 5 s post-abort; hotplug target PVC attachment state (volumeStatus).
- Tracker latestCheckpoint after abort (must NOT reflect the aborted backup).
- Target-PVC partial-image residue (node-local find, recorded).
- Recovery: fresh full backup Done/reason/duration + restore hashes.
- PASS: no stuck finalizer, VMI healthy/unfrozen, attachment cleaned (or documented), tracker clean, recovery backup + restore pass. FAIL: any of the failure modes above. Residue alone = observation (source says partial files are expected).

## 6. Blast radius / safety

Run-scoped: one VM, one backup CR, one target PVC (left in place as evidence; recovery uses a different PVC). The abort path is API-supported. The recovery stage creates one more backup + PVC. No shared-resource faults.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-02/runs/<RUN_ID>/`: trigger.log, backup-pre-delete.yaml, vmi-after-abort.yaml, tracker-after-abort.yaml, target-pvc-residue.txt, backups-after-recovery.txt, (backup-stuck.yaml if triggered), observer streams; lifecycle JSON under `runs/<RUN_ID>/`.
