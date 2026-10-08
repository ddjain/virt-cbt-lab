# 01. CBT overview

## Learning goal

After reading this page, you should know the difference between a VM, a backup request, a checkpoint, a full image, and an incremental overlay.

## What CBT means here

Changed Block Tracking records which virtual-disk blocks changed after a checkpoint. The deterministic guest file workload causes disk changes; CBT tracks the virtual disk, not any individual filename.

The feature is implemented by KubeVirt's alpha `backup.kubevirt.io/v1alpha1` APIs. The repository provides orchestration and verification around KubeVirt; it is not the backup engine.

- A **full** backup writes a standalone qcow2 image.
- An **incremental** backup writes a qcow2 overlay relative to a prior checkpoint.
- A **tracker** stores the VM relationship and latest checkpoint name.
- A restore requires the full base plus the required incremental chain.
- KubeVirt does not provide a native restore API for this feature; this repository supplies a verification restore path.

## What is actually tracked

CBT is not a file-level backup and does not watch the workload directory. QEMU/libvirt tracks checkpoint and dirty-block state for the entire virtual disk. In the live cloud05 VMI, the active chain was:

```text
root PVC file:
  /var/run/kubevirt-private/vmi-disks/rootdisk/disk.img
      |
      v
CBT qcow2 layer on persistent-state PVC:
  /var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2
      |
      v
guest virtio disk:
  /dev/vda
```

The persistent-state PVC is therefore part of the CBT control/data state. Losing or corrupting it is different from losing only a backup destination PVC: the destination may be intact while the checkpoint chain needed for the next incremental backup is unusable.

## Checkpoint identity

Every successful backup reports a checkpoint name. The tracker stores the latest checkpoint, and the next tracker-backed backup names that checkpoint as its parent. A valid incremental result has three independent relationships:

1. the incremental CR reports `status.type: Incremental`;
2. the virt-launcher log names the full checkpoint as the incremental source;
3. the live libvirt checkpoint tree shows a full parent and incremental child.

The CR fields and the libvirt tree can diverge after failures; chaos verification must inspect both rather than trusting one API object.

## The simplest mental model

```text
RUNNING VM DISK
      |
      |  first backup creates a baseline checkpoint
      v
  FULL IMAGE  ------------------------------+
      |                                      |
      | guest changes                        | restore base
      v                                      v
INCREMENTAL OVERLAY  --rebase onto full-->  RESTORED DISK
      |
      +-- tracker now points at the incremental checkpoint
```

## System architecture: ASCII view

```text
                         control plane
+----------------+       +-------------------+
| operator host  |------>| OpenShift API     |
| make / oc / jq |       | CRDs, PVCs, pods  |
+--------+-------+       +----+----+----+----+
         |                    |    |    |
         | port-forward       |    |    +--> CDI import/clone
         v                    |    +-------> HPP/CSI storage
+----------------+            +-----------> virt-controller
| VM Service     |                         |
| TCP/22         |                         v
+--------+-------+                 +-------------------+
         |                         | virt-launcher    |
         v                         | compute container |
+----------------+                 | libvirt + QEMU    |
| Linux guest    |<--virtio--------+---------+---------+
| SSH + agent    |                           |
+----------------+                           |
                                             |
                   +-------------------------+------------------+
                   |                                            |
             root disk PVC                         persistent-state PVC
             raw backing disk                       CBT qcow2 overlay
                   |                                            |
                   +----------------------+---------------------+
                                          |
                           hotplug destination PVC
                           full image or incremental overlay
```

## Repository workflow: ASCII view

```text
make e2e
   |
   +--> preflight (read-only checks)
   |
   +--> vm-setup
   |      +--> prepare Debian cache or use cluster RHEL 9 DataSource
   |      +--> create VM, root DataVolume, SSH Service
   |      +--> wait Ready and CBT=Enabled
   |      +--> create baseline file set + manifest; sync guest writes
   |
   +--> vm-backup
   |      +--> create full destination PVC
   |      +--> create tracker
   |      +--> create Full VirtualMachineBackup
   |      +--> wait Done; tracker gets full checkpoint
   |
   +--> vm-cbt-backup
   |      +--> wait tracker == full checkpoint
   |      +--> add files, modify one baseline file; verify and extend manifest
   |      +--> create incremental destination PVC and backup
   |      +--> wait Done; tracker gets incremental checkpoint
   |
   +--> vm-cbt-verify
          +--> verify CBT, types, Done, checkpoints, tracker
          +--> rebase/convert backup images and hash restored files
          +--> write runs/<run-id>/report.json
```

## Control plane versus data plane

**Control plane:** API objects, controller reconciliation, PVC binding, hotplug lifecycle, status conditions, tracker updates, and events.

**Data plane:** QEMU/libvirt reads the active VM disk chain and writes qcow2 data to the hotplugged destination PVC. The guest keeps running during the live block-copy window.

The full and incremental sequence details are in [05. Full backup](05-full-backup.md) and [06. Incremental backup](06-incremental-backup.md).
## Source-of-truth pointer

The normal-path model is implemented across the [KubeVirt API types](12-kubevirt-source-reference.md#crd-and-api-contract), [controller reconciliation](12-kubevirt-source-reference.md#control-plane-reconciliation), and [launcher/QEMU path](12-kubevirt-source-reference.md#node-local-runtime-and-qemulibvirt-path). The repository's diagrams intentionally separate API/control traffic from local QEMU/PVC data movement because they are different failure domains.
