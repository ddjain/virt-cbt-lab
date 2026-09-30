# 06. Incremental backup

## Purpose

The incremental backup captures disk blocks changed after the full checkpoint. The tracker, not a direct `fullBackupName` field, identifies the base checkpoint.

## Preconditions

`vm-cbt-backup.sh`:

1. Confirms the full backup is `Done=True` and `type=Full`.
2. Rejects a terminal failure reason.
3. Waits until tracker `latestCheckpoint` exactly matches the full checkpoint.
4. Mutates `hello.txt` through the temporary guest SSH path.
5. Calls `sync` so the mutation is flushed before the snapshot/copy.
6. Saves the post-mutation hash.

The marker line is idempotent so a retry does not append it twice.

## Objects applied

```text
PVC vm-incremental-pvc-<run>
VirtualMachineBackup vm-incremental-<run>
  source.kind = VirtualMachineBackupTracker
  source.name = vm-tracker-<run>
  pvcName     = vm-incremental-pvc-<run>
```

## Incremental sequence

```mermaid
sequenceDiagram
    participant S as vm-cbt-backup.sh
    participant G as Debian guest
    participant A as OpenShift API
    participant T as tracker
    participant C as virt-controller
    participant P as hotplug pod
    participant L as virt-launcher/QEMU
    participant D as incremental PVC

    S->>A: Read full backup and checkpoint
    S->>T: Poll latestCheckpoint
    T-->>S: Full checkpoint available
    S->>G: Append payload + marker; sync; hash file
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
