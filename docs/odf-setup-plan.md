# OpenShift Data Foundation setup plan for KubeVirt CBT

This guide describes the reusable storage decisions for an ODF/Ceph-backed KubeVirt CBT workflow. It is not a host-level deployment log. Keep physical host inventories, SSH aliases, kubeconfig paths, internal endpoints, credentials, and command transcripts in access-controlled environment records outside this repository.

## Goal and scope

Provide CSI-backed, pooled storage for KubeVirt VM disks and backup PVCs while retaining the local HPP profile for clusters that do not use ODF. ODF storage supports the repository's ODF manifest variants; it does not change the CBT checkpoint contract or provide an off-cluster backup by itself.

Do not perform cluster- or host-mutating setup from this planning guide without the target environment's required change approval. Use the platform-supported ODF operator and Local Storage Operator procedures; do not substitute manual device wipes or unreviewed host commands.

## Inputs to verify before deployment

Collect these values from the target cluster's approved inventory and keep host-specific results out of tracked documentation:

- OpenShift, OpenShift Virtualization, ODF, and CSI driver versions supported together.
- Eligible worker nodes and data devices, excluding OS/boot devices; record device identity in the controlled operations inventory.
- Raw capacity, replica policy, safety headroom, and expected concurrent VM/backup PVC requests.
- StorageClasses, CSI snapshot support, node affinity, and capacity required by the selected CBT profile.
- Operator health, network access to required registries, and permissions for storage provisioning.

Use Local Storage Operator discovery and device properties such as size/type to select eligible devices; avoid device-name allowlists. Confirm the selected disks' provenance before any operation that can erase data.

## Capacity planning

Estimate usable capacity from the eligible raw device capacity, the Ceph replication policy, metadata/operational reserve, and the expected workload. Keep enough headroom for recovery/rebalancing and concurrent workloads. PVC requests are reservations, not the size of the qcow2 artifact; `.status.capacity` is not bytes written.

CDI can expand an ODF root PVC request beyond its DataVolume request because of filesystem-overhead reservation. Check the resulting PVC request/capacity on the target cluster before treating manifest sizes as a capacity measurement.

## CBT profile PVC requests

| Guest/profile | Root request | Full-backup PVC | Each incremental PVC | Storage |
|---|---:|---:|---:|---|
| Debian default HPP | 5Gi | 5Gi | 3Gi | `cbt-demo-hpp` |
| Debian default ODF | 6Gi | 6Gi | 4Gi | `ocs-storagecluster-ceph-rbd` |
| Debian large HPP | 40Gi | 40Gi | 25Gi | `cbt-demo-hpp` |
| Debian large ODF | 48Gi | 48Gi | 30Gi | `ocs-storagecluster-ceph-rbd` |
| RHEL 9 HPP | 80Gi | 80Gi | 25Gi | `cbt-demo-hpp` |
| RHEL 9 ODF | 80Gi | 80Gi | 30Gi | `ocs-storagecluster-ceph-rbd` |

`MANIFEST_VARIANT=odf` is the default. RHEL 9 resolves HPP profiles to the large HPP sizing and ODF profiles to the large ODF sizing so the root disk can clone the platform DataSource. Each planned incremental pass adds another output PVC. Verify the target cluster's available capacity for the selected pass count before running a large workload.

## Deployment and validation sequence

1. Run the repository's read-only preflight and independently verify the target cluster's ODF/CSI health and capacity.
2. Install and validate the supported ODF and Local Storage Operator releases using the platform's documented deployment procedure.
3. Create the `StorageCluster` from approved devices with the chosen replica and failure-domain policy. Confirm the Ceph cluster is healthy and ODF StorageClasses are available.
4. Verify RBD PVC provisioning, filesystem mode, access mode, node affinity, snapshot support if required, and reclaim behavior.
5. Run the repository's `make preflight` and an E2E profile that fits the planned storage budget. Check actual root PVC request/capacity, backup PVC binding, checkpoint progression, and restore verification.
6. Record only sanitized measurements: storage class, declared PVC requests/capacities, workflow result, and artifact-level sizes. Keep cluster identities, host/device mappings, credentials, and raw command logs in the approved private operations system.

## Operational considerations

- `cbt-demo-hpp` is local, node-affine demo storage; it is not replicated or live-migratable.
- Ceph replication/rebalancing can affect VM I/O and backup duration. Use the repository's monitor for API creation-to-Done durations; that interval includes PVC/controller work, not only QEMU copying.
- A larger PVC does not by itself guarantee a longer copy window. Increase workload bytes when that is the goal, and measure the resulting run.
- Do not infer data consumption from a PV's reported backing-pool capacity. Compare PVC requests, filesystem/volume usage, and qcow2 artifact size separately.
- ODF cleanup and disk wiping are destructive operations. Use operator-supported workflows only after explicit approval and verified device provenance.

For the CBT resource contract and RHEL 9 storage details, see [`vm-cbt-workflow.md`](vm-cbt-workflow.md) and [`cbt/04-storage.md`](cbt/04-storage.md).
