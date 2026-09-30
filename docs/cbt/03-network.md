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

## Cloud05 network values

The audit observed:

- OVN-Kubernetes as the default network;
- cluster pod CIDR `10.128.0.0/14`, host prefix `/23`;
- Service CIDR `172.30.0.0/16`;
- cluster network MTU `1400`;
- Geneve port `6081` and IPsec disabled.

The example VMI had a private pod/guest address from the cluster pod CIDR; the VM Service had a dynamically assigned Service-CIDR ClusterIP. These values identify only the audit shape. Always query the current VMI and Service.

The guest-agent path is local to the VMI, not a Service connection. The live domain XML contained a virtio-serial channel named `org.qemu.guest_agent.0` with state `connected`, and the compute log showed polling of `guest-fsfreeze-status`. The VM manifest installs/enables `qemu-guest-agent`; KubeVirt materializes the runtime channel in the domain.

The backup data path is also not the guest network. The live QEMU command line used the local `file` driver for both `disk.img` and `rootdisk.qcow2`; it did not use NBD or the guest Service. A VMI network filter can break SSH or guest-agent operations while leaving local backup I/O unaffected. Conversely, node-local storage pressure can break a backup while SSH remains healthy.

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
## Upstream source references

The network/data-plane boundary is confirmed by [`pkg/virt-launcher/virtwrap/storage/backup.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go#L126-L205) and [`pkg/virt-launcher/virtwrap/converter/converter.go`](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/converter/converter.go#L692-L783): backup XML and CBT disks use local libvirt file/block paths. The guest-agent freeze/thaw channel is handled by the launcher and is not an SSH/Service data path. For the full source/error map, see [12. KubeVirt source reference](12-kubevirt-source-reference.md#node-local-runtime-and-qemulibvirt-path).
