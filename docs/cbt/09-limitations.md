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

There is no native KubeVirt restore API for this alpha feature. The repository's restore helper is a reference verification path, not a production restore controller. It requires a privileged pod and reads the demo's ext4 (Debian) or XFS (RHEL 9) filesystem directly.

## Current cloud05 topology limits

The audit observed OpenShift 4.22.15 with HCO 4.22.9/KubeVirt operator `v1.8.4`, `IncrementalBackup` enabled, and the CBT selector `cbt-demo=enabled`. HPP's `cbt-demo-pool` is host-path-backed on one selected worker. Six CBT-enabled VMs and multiple backup pairs were running on that worker during the audit. This is useful for reproducing a local-storage failure, but it is not evidence of a highly available backup design.

The VMI status also reported `AgentConnected=True`, `LiveMigratable=False` with reason `DisksNotLiveMigratable`, and VM-level `evictionStrategy: None`, even though the cluster-level KubeVirt default was `LiveMigrate`. Chaos plans must target the actual VM/node/storage layout, not the cluster default alone.

## Concurrency limitation discovered on cloud05

Kubernetes resource names are run-derived, so completed runs can coexist in one namespace. A single repository checkout is still not safe for concurrent workflow processes because `state/run-id`, `state/report-id`, and the active `report/<REPORT_ID>/` artifacts—including `workload-manifest.json` and report fragments—are shared.

A concurrent run can overwrite another run's IDs or manifest and mix report fragments from different run IDs. Serialize runs per checkout or use separate repository copies.

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

## Known implementation signals and proof gaps

- A controller resource-version conflict can requeue reconciliation and produce a duplicate backup-begin call. The virt-launcher idempotency check currently rejects a matching already-completed backup; controller restart/leader failover under this race is not proven.
- `HotplugFailed` events can occur while HPP is still materializing `disk.img`, then self-heal before `VolumeMountedToPod`. Event severity is not terminal backup state.
- Guest freeze/thaw is attempted for each backup. A successful artifact can still have a quiescing warning; decide separately whether crash consistency is acceptable.
- The persistent-state PVC keeps the CBT qcow2 layer outside the launcher pod, but the checkpoint-redefinition path after a VMI restart is only documented by the CRD and remains untested.
- The repository verifies restored guest data but does not independently prove incremental allocation/backing metadata. Use `qemu-img info/map` for that claim.
- The cluster currently contains a stale `vm-cbt-restore` namespace with manually named Pending restore PVCs/pods. Those objects are not the run-derived verifier and must not be confused with `vm-cbt-restore-test.sh` results.

## Cleanup warning

`make clean-all` deletes all workflow-managed resources in the configured namespace and waits for managed PV reclamation. With the demo storage class's `Delete` reclaim policy, this removes local backup artifacts. Preserve or replicate artifacts before cleanup if they are needed.

The cached golden-image namespace and shared storage class are outside the cleanup scope.
## Source review does not remove the proof boundary

The v1.8.4 source map in [12. KubeVirt source reference](12-kubevirt-source-reference.md) documents fallback and error paths, but source inspection is not a live failure test. Downstream patches, image versions, storage drivers, and timing can change behavior. Execute each chaos scenario and preserve settled API state, tracker/checkpoint state, artifact metadata, and restored data before claiming a result.
