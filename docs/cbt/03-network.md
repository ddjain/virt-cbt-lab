# 03. Network topology

## Three separate network paths

Do not treat guest SSH, guest-agent traffic, and backup data as one path.

```text
A. Operator / control path

cloud05 shell --oc--> OpenShift API server
                         |
                         +--> VM, VMI, Backup, Tracker, PVC, Pod objects
                         +--> events, conditions, logs, watches

B. Guest mutation path

cloud05 shell
   -> oc port-forward (random local port)
   -> Service vm-ssh-<run>:22
   -> virt-launcher pod
   -> KubeVirt masquerade interface
   -> Debian guest sshd:22

C. Backup data path

QEMU/libvirt in virt-launcher
   -> active CBT disk chain
   -> hotplugged destination PVC
   -> HPP node-local storage
```

## VM network configuration

The VM manifest declares:

- pod networking (`networks[].pod`);
- a virtio interface with `masquerade`;
- guest port 22;
- a Service selecting `vm.kubevirt.io/name=<vm>`.

Cloud05 used OVN-Kubernetes with MTU 1400. Pod IPs, Service ClusterIPs, MAC addresses, and node names are dynamic and must not be hard-coded.

## What uses the network

| Operation | Network dependency |
|---|---|
| `oc` resource creation/status | Execution host to OpenShift API |
| Golden-image import | CDI importer to `cloud.debian.org` over HTTPS |
| Guest setup/mutation | API port-forward, Service, VM network, SSH |
| Guest-agent freeze/thaw | Not IP networking; QEMU virtio-serial channel |
| Backup block-copy | Primarily local file/block I/O between virt-launcher and PVC |
| Restore helper image | Registry access for image pull; disk work is local to mounted PVCs |

A VMI network disruption should primarily affect SSH and guest-agent communication. It is not automatically a backup-storage disruption because the backup copy uses local QEMU/libvirt storage paths rather than the guest Service.

## Guest-agent channel

The VM includes a `qemu-guest-agent` package and a QEMU `org.qemu.guest_agent.0` virtio-serial channel. KubeVirt attempts guest filesystem freeze/thaw around backup start. In one successful default run, the full backup started before the agent was connected; the copy completed with a quiescing warning. Inspect the backup Done reason and launcher logs when consistency matters.

## SSH security boundary

The repository disables host-key checking only for the randomized localhost port-forward. It does not expose the Service externally and does not use that SSH exception for general remote administration.
