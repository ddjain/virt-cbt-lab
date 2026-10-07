# 06. Incremental backup

## Purpose

The incremental backup captures disk blocks changed after the full checkpoint. The tracker, not a direct `fullBackupName` field, identifies the base checkpoint.

## Preconditions

`vm-cbt-backup.sh`:

1. Confirms the full backup is `Done=True` and `type=Full`.
2. Rejects a terminal failure reason.
3. Waits until tracker `latestCheckpoint` exactly matches the full checkpoint.
4. Verifies the baseline workload directory against the run manifest.
5. Adds M deterministic files, extends the manifest with their paths, sizes,
   and SHA-256 values, and flushes guest writes before the incremental backup.
6. After restore, the combined full-plus-incremental disk must match the
   manifest containing N+M files.

File names and sizes are stable across retries. The incremental disk remains a
delta; the combined restored disk is the N+M file-set assertion target.

## How the base is selected

The CRD's source description is explicit: when `source.kind` is `VirtualMachineBackupTracker`, KubeVirt resolves the source VM and uses the tracker to obtain the base checkpoint. On completion, the tracker is updated with the new checkpoint. There is no `fullBackupName` field in the manifest; the relationship is carried by the tracker and the libvirt checkpoint name.

For the cloud05 large run:

```text
full checkpoint:
  vm-backup-kb-large-0930-1248-2026-09-30_12-50-38
incremental checkpoint:
  vm-incremental-kb-large-0930-1248-2026-09-30_12-53-45
tracker latestCheckpoint:
  vm-incremental-kb-large-0930-1248-2026-09-30_12-53-45
libvirt tree:
  full
   └── incremental
```

The live launcher log also emitted `Generating incremental backup ... from checkpoint: ...`, which is the strongest direct evidence that the named full checkpoint was used as the base.

## Objects applied

```text
PVC vm-incremental-pvc-<run>-pNN
VirtualMachineBackup vm-incremental-<run>-pNN
  source.kind = VirtualMachineBackupTracker
  source.name = vm-tracker-<run>
  pvcName     = vm-incremental-pvc-<run>-pNN
```

## Incremental sequence

```mermaid
sequenceDiagram
    participant S as vm-cbt-backup.sh
    participant G as Linux guest (Debian/RHEL 9)
    participant A as OpenShift API
    participant T as tracker
    participant C as virt-controller
    participant P as hotplug pod
    participant L as virt-launcher/QEMU
    participant D as incremental PVC

    S->>A: Read full backup and checkpoint
    S->>T: Poll latestCheckpoint
    T-->>S: Full checkpoint available
    S->>G: Add deterministic file set; flush and hash workload manifest
    S->>A: Apply incremental PVC and backup CR
    C->>T: Resolve VM and latest checkpoint
    C->>P: Attach incremental PVC
    P->>L: Make destination available
    C->>L: Begin backup request
    L->>L: Select named full checkpoint as base
    L->>L: Create child checkpoint and copy changed blocks
    L->>D: Write incremental qcow2 overlay
    L-->>C: Backup completed + child checkpoint
    C->>T: Advance latestCheckpoint to child

    C->>A: Set type=Incremental, Done=True
    S->>A: Validate types, checkpoint distinctness, and tracker
```
## Restart boundary

The tracker has a `checkpointRedefinitionRequired` status flag. KubeVirt documents that `virt-handler` sets it when a VM restarts with an existing checkpoint, then `virt-controller` redefines the checkpoint in the new libvirt instance and clears the flag. A restart between full and incremental backup is therefore not automatically proof that CBT was lost; it is a specific recovery path that must be tested.

For chaos verification, capture the flag before and after the restart, inspect the new launcher checkpoint tree, and only then submit the incremental backup. Require the same parent/child relationship and restore hashes. A reported `Incremental` type without that evidence is insufficient.

The observed large run reached `Done=True` at `12:54:00Z` for the incremental object created at `12:53:45Z`. As with the full backup, this is API object lifetime including hotplug and reconciliation; use launcher log timestamps when measuring the actual copy window.

## Evidence of a real base relationship

The live virt-launcher log contains:

```text
Generating incremental backup <name> from checkpoint: <full-checkpoint>
```

The final incremental status must have:

- `type: Incremental`;
- `Done=True`;
- a non-empty checkpoint different from the full checkpoint;
- tracker latest checkpoint equal to the incremental checkpoint.

The repository's restore test additionally proves that applying the overlay reproduces the post-mutation guest file. It does not independently inspect qcow2 cluster allocation or backing-file metadata; that remains a separate artifact-level test gap.
## Source-grounded fallback and retry behavior

The type decision is [`isIncrementalBackup`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L418-L423): a tracker checkpoint is required and `forceFullBackup` must be false. The controller passes that checkpoint to the launcher in [`handleBackupInitiation`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/backup.go#L634-L647); the launcher puts it in libvirt backup XML in [`generateDomainBackup`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L207-L266).

If checkpoint redefinition after a VMI restart or migration returns HTTP 422, KubeVirt clears `latestCheckpoint` and the next tracker-backed request falls back to Full. A transient HTTP 503 leaves the checkpoint and requeues redefinition. A failed incremental copy does not advance the tracker. The controller and launcher also reject a different backup while one is active and reject replay of an already completed backup. These distinctions are required assertions for chaos testing; see [12. KubeVirt source reference](12-kubevirt-source-reference.md#tracker-recovery-after-restart-or-migration).
