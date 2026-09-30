# 09. Limitations and production cautions

## Feature maturity

The incremental-backup API is alpha/preview and requires the `IncrementalBackup` feature gate. Confirm compatibility with the installed OpenShift Virtualization release before adopting it.

## Storage and recovery

The demo uses local RWO HPP storage. The VM root disk, persistent CBT state, and backup destinations are node-affine. This means:

- the VM is not live-migratable with the demo storage;
- a node or local-pool failure can affect VM and backup state together;
- backup PVCs are not automatically replicated off cluster;
- a full base and its incremental chain must be retained together;
- this is not a disaster-recovery topology.

## Consistency

KubeVirt attempts guest filesystem freeze through qemu-guest-agent. The default workflow does not fail solely because freeze returns a warning; it checks the terminal reason and then verifies restored data. A production consistency policy must decide whether a freeze warning is acceptable or should fail the backup.

## Restore

There is no native KubeVirt restore API for this alpha feature. The repository's restore helper is a reference verification path, not a production restore controller. It requires a privileged pod and reads the demo's ext4 filesystem directly.

## Concurrency limitation discovered on cloud05

Kubernetes resource names are run-derived, so completed runs can coexist in one namespace. A single repository checkout is still not safe for concurrent workflow processes because these files are shared:

```text
state/run-id
state/report-id
state/full-backup.sha256
state/incremental-backup.sha256
```

A concurrent run can overwrite another run's IDs, hashes, and report fragments. The observed large-copy experiment produced a mixed report containing VM/backup objects from different run IDs and failed the full-only hash comparison for that reason. Serialize runs per checkout or use separate repository copies.

## Untested failure/recovery paths

The normal workflow does not establish behavior after:

- virt-launcher termination during live block-copy;
- destination PVC capacity exhaustion;
- HPP node/storage failure;
- VMI restart between full and incremental backups;
- `checkpointRedefinitionRequired` recovery;
- virt-controller restart during reconciliation;
- API-server/network partition during backup;
- restore from a longer multi-increment chain;
- booting a reconstructed VM.

These are appropriate targeted resilience tests. Validate final conditions, checkpoint relationships, qcow2 metadata, and restored guest/application data for each one.

## Cleanup warning

`make clean-all` deletes all workflow-managed resources in the configured namespace and waits for managed PV reclamation. With the demo storage class's `Delete` reclaim policy, this removes local backup artifacts. Preserve or replicate artifacts before cleanup if they are needed.

The cached golden-image namespace and shared storage class are outside the cleanup scope.
