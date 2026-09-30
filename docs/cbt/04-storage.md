# 04. Storage topology

## Cloud05 storage class

The observed `cbt-demo-hpp` class used:

- provisioner: `kubevirt.io.hostpath-provisioner`;
- `WaitForFirstConsumer` binding;
- `ReadWriteOnce` access;
- `Delete` reclaim policy;
- HPP pool `cbt-demo-pool` on node-local host-path storage.

This is demonstration storage. It is not replicated storage, off-cluster backup, or disaster recovery.

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
