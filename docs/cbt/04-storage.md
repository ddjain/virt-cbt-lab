# 04. Storage topology

## HPP storage class

The `cbt-demo-hpp` profile uses local, node-affine `ReadWriteOnce` storage. It is demonstration storage, not replicated storage, off-cluster backup, or disaster recovery. Confirm the target class's provisioner, binding mode, and reclaim policy before use.

## Capacity and placement

HPP may report backing-pool/PV capacity rather than the PVC request. Do not interpret a large `.status.capacity` as the amount of backup data written.

`WaitForFirstConsumer` can leave a claim `Pending` until a consumer provides scheduling information. The Debian golden image is the exception: its manifest requests immediate binding because it has no VM consumer of its own. CDI clones also create temporary source/clone pods and PVCs; those belong to image preparation, not CBT backup data.

HPP-backed PVCs are node-affine. Inspect the selected node and current pool capacity rather than assuming all claims share a single failure domain.

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
+-- vm-cbt-demo/vm-incremental-pvc-<run>-pNN PVC
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

## RHEL 9 ODF storage sizing

The current large ODF manifests request 80Gi for the RHEL 9 root DataVolume
and full-backup PVC, plus 30Gi for each incremental PVC. Three incrementals
therefore request 250Gi nominally (80Gi + 80Gi + 3 × 30Gi), before CDI
root-PVC overhead and KubeVirt persistent-state storage. The actual root PVC
request can exceed the DataVolume request because CDI reserves filesystem
overhead.

**Historical 48Gi, one-increment measurement.** A successful RHEL 9
`large-odf` run measured a 48Gi DataVolume request expanded to a
54,631,984,006-byte root PVC request (~50.88Gi) with 51Gi reported capacity.
The full-backup PVC was 48Gi and the incremental PVC was 30Gi: the three
workflow claims requested 128.88Gi and reported 129Gi combined capacity.
KubeVirt added a persistent-state claim requesting 580,198,073 bytes
(~0.54Gi); its 1489Gi HPP status capacity is backing-PV capacity, not
per-run usage. Total measured per-run PVC requests were ~129.42Gi (round to
130Gi).

The shared `rhel9` source PVC requested ~31.8Gi and reported 1489Gi capacity
on HPP; it predates the run and is excluded from the per-run total. Restore
verification adds no PVC; it reuses both backup claims and uses `emptyDir`
scratch plus host `/dev`. See the
[RHEL 9 workflow storage details](../vm-cbt-workflow.md#rhel-9-storage-footprint).

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
