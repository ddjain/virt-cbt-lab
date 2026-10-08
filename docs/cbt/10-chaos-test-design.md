# 10. Chaos-test design

## Purpose

This page turns the CBT architecture into testable failure boundaries. It is a guide for someone new to the feature; the executable scenario details remain in [`../../cbt-chaos/chaos-plan.md`](../../cbt-chaos/chaos-plan.md).

Chaos must test two different claims separately:

1. **Control-plane correctness:** the API objects, conditions, checkpoints, tracker, and reconciliation settle coherently.
2. **Data-plane correctness:** the full and incremental qcow2 artifacts reconstruct the expected guest state.

A test passes only when both claims are checked. `Done=True`, an event, or an `Incremental` string alone is not proof.

## Before injecting failure

1. Use a unique immutable run ID for each workflow. Per-run artifacts live under `runs/<run-id>/`; the `make e2e` wrapper serializes its own invocations, and direct lifecycle commands for one VM must remain sequential.
2. Use a deterministic run name and record `RUN_ID`, VM, launcher pod, tracker, full backup, incremental backup, and PVC names.
3. Prefer `MANIFEST_VARIANT=large` with increased `GUEST_BASE_FILE_COUNT`, `GUEST_INCREMENTAL_FILE_COUNT`, or `GUEST_FILE_SIZE_MIN_MIB`/`GUEST_FILE_SIZE_MAX_MIB` when a scenario needs a sustained copy window. The old single-file timing measurements do not predict this workload; confirm the actual window with `scripts/monitor.sh`. PVC size alone is not a timing control.
4. Confirm the VM reports `changedBlockTracking.state=Enabled`, the VMI is `Running`, and `AgentConnected=True` before testing guest-consistency behavior.
5. Capture the baseline tracker and checkpoint tree:

   ```sh
   oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml
   oc exec -n "$NAMESPACE" "$LAUNCHER_POD" -c compute -- \
     virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree
   ```

6. Save the baseline object YAML, events, launcher log, and PVC/PV mapping. Chaos may delete the pod that contains the most useful log.

## Injection boundaries

```text
backup CR applied
      |
      +-- PVC Pending / HPP provisioning
      |
      +-- hp-volume-* attachment pod
      |       |
      |       +-- first mount attempt; disk.img may not exist yet
      |       +-- VolumeMountedToPod
      |
      +-- Backup begin called
              |
              +-- guest freeze -> thaw       [consistency boundary]
              |
              +-- Backup started             [live copy trigger]
              |       |
              |       +-- QEMU reads local CBT chain
              |       +-- QEMU writes destination PVC
              |       +-- guest continues running
              |
              +-- Backup completed successfully
                      |
                      +-- controller status/reconcile
                      +-- destination unmount and attachment cleanup
                      +-- tracker checkpoint update

full Done + tracker checkpoint
      |
      +-- VMI/launcher restart and checkpoint redefinition
      |
      +-- guest mutation + sync
      |
      +-- incremental backup from named full checkpoint
```

Use the launcher log line `Backup started` for the live-copy trigger. Object creation time includes binding, hotplug, and controller work. Use `Progressing=True` only as a broad state check, not as the precise byte-copy boundary.

## Scenario map

| Scenario | Target | Primary boundary | Main question |
|---|---|---|---|
| [01. virt-launcher kill](../../cbt-chaos/scenarios/01-virt-launcher-pod-kill-during-copy/scenario-spec.md) | `virt-launcher` compute/QEMU | Live copy | Can interruption ever produce terminal success over a damaged destination? |
| [02. destination PVC fill](../../cbt-chaos/scenarios/02-backup-destination-pvc-fill/scenario-spec.md) | Full/incremental destination PVC | Live copy | Does capacity exhaustion fail cleanly without a false `Done=True`? |
| [03. checkpoint PVC fill](../../cbt-chaos/scenarios/03-checkpoint-pvc-fill/scenario-spec.md) | Persistent-state PVC | Checkpoint write | Does checkpoint-state pressure preserve or corrupt the chain? |
| [04. VMI restart](../../cbt-chaos/scenarios/04-vmi-restart-between-backups/scenario-spec.md) | VMI/launcher between backups | Redefinition | Does `checkpointRedefinitionRequired` recover the parent checkpoint? |
| [05. controller kill](../../cbt-chaos/scenarios/05-virt-controller-pod-kill-post-done/scenario-spec.md) | `virt-controller` | Reconcile/status | Does retry/idempotency avoid duplicate or regressed checkpoint state? |
| [06. storage throttle](../../cbt-chaos/scenarios/06-incremental-copy-storage-throttle/scenario-spec.md) | Incremental destination PVC | Slow live copy | Does a wider race window expose duplicate-begin behavior? |
| [07. hotplug pod kill](../../cbt-chaos/scenarios/07-hotplug-attachment-pod-kill/scenario-spec.md) | `hp-volume-*` | Before mount | Does hotplug retry or fail within a bounded time? |
| [08. guest network filter](../../cbt-chaos/scenarios/08-guest-network-filter-during-mutation/scenario-spec.md) | VM tap/SSH path | Guest mutation | Does guest SSH fail closed without conflating network and backup I/O? |
| [09. node stop/start](../../cbt-chaos/scenarios/09-node-stop-start-during-copy/scenario-spec.md) | HPP/launcher node | Compound failure | What happens when VM, checkpoint PVC, and destination share one node? |
| [10. node I/O hog](../../cbt-chaos/scenarios/10-node-io-hog-during-copy/scenario-spec.md) | HPP node | Slow storage | Does generic node pressure match PVC-scoped throttle behavior? |

Run isolated scenarios first. Scenario 09 compounds the failure domains and is not a substitute for understanding scenarios 01, 03, and 04 independently.
## Source-grounded failure matrix

The following outcomes come from the v1.8.4 implementation, not from assumptions about generic Kubernetes controllers:

| Injection point | Source behavior to verify | Required verdict |
|---|---|---|
| `virt-controller` restart before or after launcher start | Backup and tracker workqueue items are rate-limited and reconciliation is idempotent; the finalizer protects an unfinished Backup. | No duplicate successful backup should advance the tracker twice. Capture any replayed launcher request and compare backup name/start time. |
| `virt-launcher`/QEMU termination during copy | The VMI-side metadata may become unavailable; controller logic can classify lost VMI backup status as terminal failure and clean up. | Never accept `Done=True` without the terminal reason, destination artifact inspection, and restore result. |
| Destination PVC full or I/O error | Libvirt job failure is recorded as `failed`; Push-mode cancellation is also failure. Failed status does not update the tracker. | Existing full checkpoint remains the only valid base; the next attempt must not silently use a partial destination. |
| VMI restart or migration after a checkpoint | `virt-handler` moves CBT to `Initializing`, marks trackers, and `virt-controller` calls checkpoint redefinition. | `503` must retry with the checkpoint retained; `422` must clear the checkpoint and make the next backup Full. |
| Persistent-state PVC unavailable or bitmap corrupt | QMP bitmap lookup or `CreateCheckpointXML(...REDEFINE_VALIDATE)` can classify the checkpoint invalid. | Distinguish lost checkpoint state from destination-PVC failure; preserve evidence before cleanup. |
| Target PVC pending, block mode, or hotplug failure | The controller waits for a missing PVC/attachment or rejects a block-mode target; it patches a filesystem target as a VMI Backup utility volume. | Record PVC phase, node affinity, utility-volume status, attachment-pod events, and whether the controller eventually detaches the volume. |
| Guest-agent freeze/thaw failure | Freeze/thaw is best effort; a successful copy can carry `backupMsg` and complete with warning. | Separate crash-consistency policy from byte-copy success. Record `AgentConnected`, launcher log, Done reason, and restored data. |
| Backup delete or Pull TTL expiry | The controller sends Abort for an unfinished job, then detaches the target; Pull expiry also removes the VMExport. | Verify aborting/deleting conditions, no tracker advancement, PVC cleanup, and no stale utility volume. |

These are implementation-backed hypotheses, not executed results. The exact source paths are collected in [12. KubeVirt source reference](12-kubevirt-source-reference.md#control-plane-reconciliation) and [its checkpoint error section](12-kubevirt-source-reference.md#checkpoint-redefinition-and-error-classification).


## Required verification layers

### 1. Settled API state

Wait for a terminal condition and record:

- full: `type=Full`, `Done=True`, non-empty checkpoint;
- incremental: `type=Incremental`, `Done=True`, non-empty checkpoint different from full;
- tracker: latest checkpoint equals the incremental checkpoint;
- Done reason does not begin with KubeVirt's terminal `Backup has failed` wording;
- `includedVolumes` still identifies the expected `vda`/`rootdisk` volume.

Read the object twice after reconciliation if the test concerns races. A transient event can report failure before the final object is successfully updated.

### 2. Libvirt checkpoint state

Inside the current `virt-launcher` compute container:

```sh
oc exec -n "$NAMESPACE" "$LAUNCHER_POD" -c compute -- \
  virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree
```

The expected one-increment tree is:

```text
full-checkpoint
  |
  +- incremental-checkpoint
```

After a VMI restart, also record `status.checkpointRedefinitionRequired` before and after redefinition. A successful API type without the expected tree is an incomplete result.

### 3. Artifact state

The repository's restore helper verifies guest semantics. A CBT-specific chaos claim should additionally inspect both qcow2 files with `qemu-img info` and `qemu-img map --output=json`, recording backing-file relationship, virtual size, physical size, and allocated clusters. File size alone is not proof of a delta.

### 4. Guest/data state

Run the repository restore verification:

- the full-only image's file count and canonical manifest hash match the N-file baseline;
- the combined image's file count and canonical manifest hash match the N+M file set.

The helper reads the guest filesystem from reconstructed raw images. It does
not boot a reconstructed VM or prove application-level consistency.

## Expected result categories

| Result | Interpretation |
|---|---|
| Terminal failure, no false success, artifacts rejected/absent | Expected safe failure; record recovery and cleanup |
| Terminal success plus checkpoint tree plus restored data | Successful recovery; inspect artifact metadata for delta claims |
| `Done=True` with terminal failure reason | Failed backup; never treat the condition boolean alone as success |
| Warning event followed by successful settled state and valid restore | Benign/intermediate reconcile signal; document exact event timeline |
| `Incremental` type but wrong/missing parent tree | CBT correctness failure even if guest hash happens to pass |
| Restore hash passes but qemu-img metadata is wrong | Data-state success but delta-representation failure |
| Workflow hangs in Pending/Progressing | Capture PVC, hotplug pod, events, controller/launcher logs before cleanup |

## Cloud05-specific cautions

The audited cluster had OVN-Kubernetes, one HPP pool on one selected worker, local RWO storage, and multiple simultaneous CBT VMs on that worker. This makes node and storage chaos highly attributable to the demo, but it also means a test can fail because of shared-worker contention rather than the targeted component. Record node placement and active runs for every scenario.

Do not use the stale manually named objects in `vm-cbt-restore` as proof of the run-derived restore verifier. The verifier created by the repository is `vm-restore-verify-<run-id>` in the workflow namespace and is deleted after collection.
