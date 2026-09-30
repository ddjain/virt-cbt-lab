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
| Image management | CDI operator/controllers/importer/cloner | Imports Debian and clones each run's root disk |
| Storage | HPP CSI/provisioner and `cbt-demo-hpp` | Creates node-local RWO PVCs |
| Networking | OVN-Kubernetes, Service, port-forward | Provides pod/VM network and guest SSH access |
| Guest | Debian, SSH, qemu-guest-agent | Provides test workload, SSH mutation, and optional freeze/thaw |
| Verification | restore-helper image and privileged pod | Reconstructs qcow2 chain and reads ext4 guest data |

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
