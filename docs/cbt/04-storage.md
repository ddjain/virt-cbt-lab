# 04. Storage topology

## Cloud05 storage class

The observed `cbt-demo-hpp` class used:

- provisioner: `kubevirt.io.hostpath-provisioner`;
- `WaitForFirstConsumer` binding;
- `ReadWriteOnce` access;
- `Delete` reclaim policy;
- HPP pool `cbt-demo-pool` on node-local host-path storage.

This is demonstration storage. It is not replicated storage, off-cluster backup, or disaster recovery.

## Cloud05 storage facts

The live HPP resource was:

```text
HostPathProvisioner: cbt-demo-hpp
pool: cbt-demo-pool
pool path: host-local path configured by the HPP resource
pool backing claim: HPP-generated claim on the selected worker
pool backing capacity: 1489Gi in this audit
HPP workload node: one selected worker, dynamic
```

The HPP pool template requests `1Ti`, but the backing PV and every observed workload PVC reported `1489Gi`. That is the provisioned backing-pool/PV capacity, not the amount requested or the amount of qcow2 data written. The destination PVCs still request only 5/3 GiB in the default manifests or 40/25 GiB in the large manifests.

`WaitForFirstConsumer` means a PVC can remain Pending until a consumer supplies scheduling information. The golden image is the exception: `manifests/debian-image.yaml` sets `cdi.kubevirt.io/storage.bind.immediate.requested: "true"` because it has no VM consumer of its own. CDI clones also create temporary source/clone pods and PVCs; those are part of image preparation, not CBT backup data.

All observed CBT workload PVCs were `ReadWriteOnce`, `Filesystem`, and selected to the same HPP worker. The current cloud05 layout is a single-node storage failure domain.

## Topology

```text
HPP node-local pool
|
+-- vm-cbt-images/debian-golden PVC (one-time source image)
|
+-- vm-cbt-demo/vm-disk-<run> PVC
|      root disk backing file: disk.img
|
+-- vm-cbt-demo/persistent-state-for-vm-<run>-<suffix> PVC
|      +-- meta/  backend metadata
|      +-- cbt/   rootdisk.qcow2 CBT overlay/checkpoint state
|
+-- vm-cbt-demo/vm-backup-pvc-<run> PVC
|      full qcow2 output
|
+-- vm-cbt-demo/vm-incremental-pvc-<run> PVC
       incremental qcow2 overlay output
```

The root, persistent-state, and backup PVCs are RWO and node-affine. The VM reports `LiveMigratable=False` with this local layout.

For the live large run, the root PVC requested approximately `45,526,653,338` bytes (40 GiB) and was marked CDI-preallocated. The VM's VMI reported `filesystemOverhead: 0.06`, `preallocated: true`, and `LiveMigratable=False` with reason `DisksNotLiveMigratable`. The VM manifest explicitly sets `evictionStrategy: None`; this avoids eviction/migration behavior in the demo, but it does not make the local RWO disk migratable.

The cluster-level KubeVirt configuration observed `evictionStrategy: LiveMigrate`, so distinguish the cluster default from the VM-level override when designing node-disruption tests.

## Active VM disk chain

```text
raw root PVC: disk.img
        ^
        | backing data
CBT overlay: rootdisk.qcow2
        ^
        | exposed through virtio
Debian guest: /dev/vda
```

The live virt-launcher pod mounts the persistent-state PVC at:

- `/run/kubevirt-private/backend-storage-meta` using `meta`;
- `/var/run/kubevirt-private/libvirt/qemu/cbt` using `cbt`.

The overlay is separate from both the root PVC and the backup destination PVCs.

## Default and large sizing

| Resource | Default request | Large request |
|---|---:|---:|
| VM root PVC | 5 GiB | 40 GiB |
| Full backup PVC | 5 GiB | 40 GiB |
| Incremental backup PVC | 3 GiB | 25 GiB |
| Golden image PVC | 3 GiB, one-time | reused |
| Persistent-state PVC | KubeVirt-generated | KubeVirt-generated |

The HPP PV may report the backing pool capacity rather than the request. Do not interpret a large PV `.status.capacity` as the amount of backup data written.

A large PVC does not automatically create a long copy window. The measured large run used 8192 MiB initial guest data and 12288 MiB incremental data, producing approximately 29 seconds full and 15 seconds incremental copy durations.

## Hotplug lifecycle

```text
backup PVC created
      |
      v
HPP provisions node-affine PV
      |
      v
KubeVirt creates hp-volume-* attachment pod
      |
      v
PVC mounted into virt-launcher
      |
      v
QEMU/libvirt writes qcow2 output
      |
      v
PVC unmounted; attachment pod deleted
```

Transient hotplug warnings can occur while the destination `disk.img` is being materialized or cleaned up. Confirm `VolumeMountedToPod`, final backup status, and restore data before classifying the backup as failed.

## Retention implication

An incremental overlay is not a standalone restore set. Retention must preserve the full base and every required parent checkpoint in the chain. Deleting demo PVCs under the HPP `Delete` reclaim policy deletes the corresponding local artifacts.
## Upstream source references

The destination hotplug contract is implemented in [`pkg/storage/cbt/push-target-pvc.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/storage/cbt/push-target-pvc.go#L60-L214). CBT overlay creation and the persistent-state path are in [`pkg/virt-launcher/virtwrap/storage/cbt.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/cbt.go#L243-L334), while the qcow2 front-file/raw-`DataStore` relationship is built in [`pkg/virt-launcher/virtwrap/converter/converter.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/converter/converter.go#L692-L783). The complete source map is [12. KubeVirt source reference](12-kubevirt-source-reference.md#node-local-runtime-and-qemulibvirt-path).
