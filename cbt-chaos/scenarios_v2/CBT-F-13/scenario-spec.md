# Scenario: Delete the backup controller leader during post-copy cleanup and checkpoint update

## 1. Identity

- **Scenario ID:** CBT-F-13
- **Jira issue:** CBT-F-13 — "Stop the controller during backup cleanup and checkpoint update" (P1, technical scenario: pod-scenarios, phase: transition)
- **Run family:** full-backup workflow, controller-plane disruption

## 2. Objective and hypothesis

**Jira objective:** validate the narrow transition window after the data copy finishes but before cleanup and checkpoint state updates complete. Expected: the new controller completes volume cleanup and updates the tracker exactly once; no orphaned temporary volume attachment and no duplicate checkpoint.

**Product question:** if the virt-controller leader is killed exactly as the backup transitions from copy-complete to Done (during hotplug volume unmount + attachment-pod deletion + tracker checkpoint write), does the takeover replica finish the cleanup idempotently — no leftover `hp-volume` attachment pod, no stale utility volume, tracker advanced exactly once, and the backup chain still restores?

## 3. Workflow and prerequisites

Same managed lifecycle as F-09/F-10/F-12: `make e2e TYPE=full` with `RUN_ID`, RHEL 9 guest, host-path (`default`) variant for the 52–55 s baseline and node determinism. 1000-file × 15–20 MiB baseline workload, 1 planned incremental pass, restore verification in the final pass.

Prerequisites:

- `virt-controller` deployment ≥2 replicas, leader resolved from the `virt-controller` Lease in `openshift-cnv` at satisfaction time (never hard-coded).
- Hotplug attachment pods (`hp-volume-*`) must exist for this cluster's backup flow (verified in F-12 r05: `hp-volume-cwjm9` created at backup start, deleted at cleanup).

## 4. Target and validated disruption

**Cleanup window (measured live from F-12 r05 evidence, 2026-10-13):** the copy completes and the controller flips the backup to terminal + runs hotplug cleanup at essentially the same instant: `VirtualMachineBackupCompletedSuccessfully`, `VolumeUnMountedFromPod`, `SuccessfulDelete` (attachment pod hp-volume-cwjm9 killed/deleted), and `HotplugFailed` (the informational "failed to mount filesystem hotplug volume" event on unmount) all land at 03:49:53Z — the same second as Done=True. The externally observable window "copy completed but final status not yet recorded" is therefore SUB-SECOND on this stack: no poll-based condition on the vmbackup object can gate on it.

**Workable gating (superset boundary with pod-liveness postcondition):** fire when the backup approaches terminal state and the hotplug attachment pod is still present — condition: vmbackup `Done != True` (with existence probe, F-11 r02 lesson) AND `hp-volume-<run-specific>` pod exists (proves the cleanup has not yet completed), polled at the trigger's own 1 s cadence (not krkn's ~5–15 s deploy latency; the F-11 r01 lesson kills slower paths). The kill lands either in the last seconds of the copy or in the cleanup second — both inside the Jira's intended transition; the exact landing instant is recorded from controller-pod deletion timestamps and the events timeline.

**Action:** delete the CURRENT leader pod (grace period 0 for immediacy): `oc delete pod <leader> -n openshift-cnv --grace-period=0 --force`. This is a pod-scenarios-equivalent disruption applied directly (krknctl's pod-scenarios plugin cannot express "the pod named by a lease at condition-satisfaction time" — the same CLI limitation as F-12's target field, bug #4 in `cbt-chaos/krknctl-bugs.md`; the delete is the identical action krkn's pod-scenario would perform).

**Expected timeline:** leader deleted mid-transition → ReplicaSet replaces the pod → new/standby replica acquires lease → cleanup of the hotplug volume + attachment pod + tracker checkpoint completes on the takeover replica → backup Done=True, exactly one checkpoint.

## 5. Verification criteria

- Injection validity: leader pod deletion timestamp inside the backup's pre-terminal window (backup created → Done transition), attachment pod still present at deletion request.
- Cleanup correctness: NO leftover `hp-volume-*` attachment pod for this run after the backup is Done (5-minute post-Done grace), no stale VolumeAttachment for the backup-target PVC on the VM's node.
- Tracker correctness: exactly ONE checkpoint for the full backup; tracker advanced exactly once (duplicate checkpoint = FAIL).
- Backup terminal: Done=True reason `Successfully completed VirtualMachineBackup`, type Full; duration recorded vs 52–55 s baseline.
- Controller recovery: both replicas Ready within ~2 min; post-run leader functional (it must reconcile the follow-up incremental).
- Follow-up: incremental pass + restore verification on the same VM pass (proves the post-chaos controller is fully functional).

## 6. Pre-run guards

VMI nodeName determinism guard, RUN_ID collision guard (observer pre-create allowed), leader re-resolution at satisfaction with abort-on-rotation, attachment-pod existence gate in the condition itself.

## 7. Uncertainties

- Sub-second window means the kill may land just before Done flips (copy tail) or just after (cleanup): both are documented as in-window for the Jira's "copy completed but final status not yet recorded" intent; the events timeline disambiguates post-hoc.
- If the takeover replica re-reconciles from scratch, a duplicate checkpoint could appear — that is precisely the failure mode under test and would be a product finding (FAIL), not a harness problem.
