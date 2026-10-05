# 02. Components and dependencies

## Component stack

| Layer | Component | Why it matters |
|---|---|---|
| Operator | `make`, Bash, `oc`, `ssh`, `ssh-keygen`, `jq` | Drives the workflow, guest mutation, polling, and reports |
| API | OpenShift API server | Stores objects and serves watches/status updates |
| KubeVirt API | VM/VMI CRDs | Defines and runs the guest |
| CBT API | `VirtualMachineBackup`, `VirtualMachineBackupTracker` | Requests backups and names the checkpoint chain |
| KubeVirt control | `virt-api`, `virt-controller`, `virt-operator` | Serves APIs and reconciles VM/backup resources |
| KubeVirt node | `virt-handler` | Node-local VMI/libvirt lifecycle and checkpoint-redefinition path |
| KubeVirt runtime | `virt-launcher` `compute` container | Runs libvirt/QEMU and the in-process backup code |
| Hypervisor | QEMU/KVM + libvirt | Maintains disk chain, checkpoints, and live block-copy |
| Image management | CDI operator/controllers/importer/cloner | Imports Debian and clones run disks; RHEL 9 uses the cluster DataSource |
| Storage | HPP CSI/provisioner and `cbt-demo-hpp` | Creates node-local RWO PVCs |
| Networking | OVN-Kubernetes, Service, port-forward | Provides pod/VM network and guest SSH access |
| Guest | Debian/RHEL 9 Linux, SSH, qemu-guest-agent | Provides test workload, SSH mutation, and optional freeze/thaw |
| Verification | restore-helper image and privileged pod | Reconstructs qcow2 chain and reads ext4, XFS, or NTFS guest data |

## Live cloud05 reference snapshot

The audit observed this stack on cloud05. Treat versions, pod counts, IPs, and node names as a point-in-time reference, not a contract:

| Item | Observed value |
|---|---|
| OpenShift | 4.22.15 |
| OpenShift Virtualization/KubeVirt | HCO 4.22.9; KubeVirt operator version `v1.8.4` |
| CBT feature gate | `IncrementalBackup` |
| CBT selector | VM label `cbt-demo=enabled` |
| Backup CRD owner | `virt-operator`; CRD version `v1alpha1` |
| `virt-controller` | 2 running replicas in `openshift-cnv` |
| `virt-handler` | DaemonSet, one pod per node |
| HPP pool | `cbt-demo-pool`, host-path-backed, selected worker is dynamic and should be read from the HPP node selector |

The live audit found six running CBT-enabled VMs across `cbt-demo` and `vm-cbt-demo`, with multiple full/incremental backup pairs coexisting. Resource-name isolation works at the Kubernetes level; local repository state still makes concurrent workflows unsafe. See [09. Limitations](09-limitations.md).

The live `openshift-cnv` namespace also contained CDI operator/apiserver/deployment/upload-proxy components, the HPP operator/CSI/provisioner components, and KubeVirt control-plane pods. The network control plane was OVN-Kubernetes. These are dependencies of setup and storage/network plumbing; none is a separate CBT backup controller.

The golden-image manifest also creates a `RoleBinding` in `vm-cbt-images` for the workflow namespace's `default` ServiceAccount to CDI's `cdi.kubevirt.io:clone-sourcer` ClusterRole. Without this cross-namespace permission, DataVolume cloning fails before CBT is reached.

## Backup API contract

The installed CRD describes two source modes:

- `source.kind: VirtualMachine`: back up that VM directly; useful for a full backup.
- `source.kind: VirtualMachineBackupTracker`: resolve the VM and use the tracker's latest checkpoint as the incremental base; update the tracker with the new checkpoint after completion.

`VirtualMachineBackup` also exposes:

- `mode: Push|Pull`; this repository leaves it unset and uses the observed/default Push behavior;
- `forceFullBackup`; request a full backup instead of the normal type selection;
- `skipQuiesce`; skip guest filesystem quiescing;
- `ttlDuration`; resource retention/expiry control;
- `tokenSecretRef` and status `endpointCert`; Pull-mode endpoint authentication/certificate fields.

The status is more than `Done=True`: `type`, `checkpointName`, `includedVolumes`, and conditions identify the result. `includedVolumes` records each volume's guest disk target and VMI volume name; the live single-root run reported `diskTarget: vda` and `volumeName: rootdisk`. Pull mode may additionally populate `dataEndpoint` and `mapEndpoint`.

`VirtualMachineBackupTracker.status` contains `latestCheckpoint` (name, creation time, and included volumes) plus `checkpointRedefinitionRequired`. KubeVirt documents that `virt-handler` sets the flag after a VM restart, `virt-controller` attempts checkpoint redefinition, and the flag is cleared. This recovery path is a primary chaos-test target; the repository has not yet proven it under disruption.

## Where backup code runs

There is no separate backup/export pod. The short-lived `hp-volume-*` pod only stages a destination PVC for hotplug. The actual backup API call, guest freeze/thaw, checkpoint handling, and QEMU block-copy execute in the `compute` container of the `virt-launcher` pod. `virt-controller` coordinates and records the operation; it does not copy the disk bytes itself.

## Kubernetes objects created by one run

Names use `<run-id>`; the namespace is normally `vm-cbt-demo`.

| Object | Purpose |
|---|---|
| `VirtualMachine/vm-<run-id>` | Desired VM with `cbt-demo=enabled` |
| `VirtualMachineInstance/vm-<run-id>` | Running instance created by KubeVirt |
| `DataVolume/vm-disk-<run-id>` and PVC | Root disk cloned from the Debian DataSource |
| `Service/vm-ssh-<run-id>` | Guest TCP/22 selector |
| `VirtualMachineBackupTracker/vm-tracker-<run-id>` | Source VM and latest checkpoint |
| `VirtualMachineBackup/vm-backup-<run-id>` | Full backup request/result |
| `PVC/vm-backup-pvc-<run-id>` | Full qcow2 destination |
| `VirtualMachineBackup/vm-incremental-<run-id>` | Incremental backup request/result |
| `PVC/vm-incremental-pvc-<run-id>` | Incremental qcow2 destination |
| `Pod/vm-restore-verify-<run-id>` | Short-lived repository restore verifier |
| `persistent-state-for-vm-<run-id>-<suffix>` PVC | KubeVirt backend metadata and CBT state; generated automatically |

## Backup API options

The installed `VirtualMachineBackup` schema exposes `mode` (`Push`/`Pull`), `forceFullBackup`, `skipQuiesce`, `ttlDuration`, and `tokenSecretRef`. This repository leaves them unset and exercises the default Push path. Pull mode, token behavior, and retention behavior are not established by this demo.

## Component boundaries

- **CDI ends before live CBT:** CDI imports/clones images; it does not perform the full or incremental copy.
- **virt-controller coordinates:** it does not copy disk bytes itself; it coordinates hotplug, calls the VM-side backup operation, and updates API status.
- **virt-launcher performs the copy:** live logs show `backup.go` messages in the `compute` container.
- **virt-handler is node-local:** it participates in VM lifecycle and has the documented checkpoint-redefinition responsibility after a VMI restart.
- **The restore pod is repository-owned:** it is not a KubeVirt-native restore controller.

## Required cluster capabilities

- OpenShift Virtualization/KubeVirt with the backup CRDs
- `IncrementalBackup` feature gate
- CDI DataVolume/DataSource CRDs
- `cbt-demo-hpp` storage class with suitable RWO capacity
- Permissions to create/delete the workflow resources
- Cluster egress to import `cloud.debian.org` on the first image import
- Permission to run the privileged restore-verification pod, if restore verification is enabled
## Upstream source references

The component ownership above is grounded in the v1.8.4 source map: [CR/API types](12-kubevirt-source-reference.md#crd-and-api-contract), [controller reconciliation](12-kubevirt-source-reference.md#control-plane-reconciliation), [node/runtime path](12-kubevirt-source-reference.md#node-local-runtime-and-qemulibvirt-path), and [Pull-mode export path](12-kubevirt-source-reference.md#pull-mode-export-path). The default repository workflow uses Push mode; Pull mode adds `VirtualMachineExport`, an export Service, TLS, token validation, and endpoint readiness.
