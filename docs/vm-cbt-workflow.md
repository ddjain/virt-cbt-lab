# KubeVirt CBT VM backup workflow

This guide explains the repository's `make e2e` demonstration: create a VM, write and hash `hello.txt`, take a full backup, append data, take an incremental backup, and verify the CBT result.

## What the demo proves

Changed Block Tracking (CBT) records changed virtual-disk blocks. The guest file is the workload used to cause a disk change; CBT operates on the VM disk, not on `hello.txt` by name.

The demo proves the flow end to end by checking that:

1. CBT is enabled on the VM.
2. The first `VirtualMachineBackup` completes as `Full` and records a checkpoint in a `VirtualMachineBackupTracker`.
3. The guest disk changes after that checkpoint.
4. A second backup completes as `Incremental`, with a different checkpoint.
5. The tracker advances to the incremental checkpoint.

The incremental-backup feature is preview/alpha, not a GA feature. The cluster's OpenShift Virtualization `HyperConverged` resource must enable the `incrementalBackup` feature gate and select VMs with the `cbt-demo=enabled` label. The VM manifest supplies that label. `vm-setup.sh` stops with an error if the resulting VM CBT status is not `Enabled`.

Upstream background: [CBT label selectors, PR #14772](https://github.com/kubevirt/kubevirt/pull/14772), [incremental VM backups, PR #16285](https://github.com/kubevirt/kubevirt/pull/16285), and the [KubeVirt v1.8.0 release](https://github.com/kubevirt/kubevirt/releases/tag/v1.8.0).

## Prerequisites

The target server needs:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` backup APIs.
- The `IncrementalBackup` feature gate enabled and a CBT selector matching `cbt-demo=enabled`.
- The `cbt-demo-hpp` virtualization storage class.
- The CDI `fedora` `DataSource` in `openshift-virtualization-os-images`.
- Bash, Make, `oc`, `ssh`, `ssh-keygen`, and access to the local kubeconfig.

Run the scripts on a server where the kubeconfig is available. Set
`KUBECONFIG_PATH` or `KUBECONFIG` to select a kubeconfig; otherwise `oc` uses
its standard default:

```sh
make e2e KUBECONFIG_PATH=/path/to/kubeconfig
```

The configured HPP class is local/RWO demo storage. This VM is not live-migratable; the setup is for a CBT demonstration, not production storage guidance.

## Run the full workflow

```sh
make e2e
```

`e2e` runs the read-only `preflight` target first. It stops before `vm-cbt-demo` if any mandatory prerequisite fails. Run `make preflight` separately to inspect readiness.

`e2e` delegates to the same sequence as `vm-cbt-demo`:
```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```

Each step can also be run separately:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
```

The scripts print stage logs to stderr; guest `sha256sum` output and backup checkpoint summaries remain visible in the normal command output.

## Step-by-step behavior

### 1. `make vm-setup`

`scripts/vm-setup.sh`:

1. Checks that the Fedora `DataSource` is available.
2. Ensures a dedicated guest SSH key exists locally on the target server. The public key is inserted into the cloud-init user data; the private key stays at `GUEST_KEY` with mode `0600` (by default, `$HOME/.local/share/vm-cbt-demo/id_ed25519`).
3. Applies `manifests/vm.yaml`, which creates namespace `vm-cbt-demo`, VM `vm-cbt-demo`, and the `vm-cbt-ssh` service.
4. Creates a 30 GiB root `DataVolume` from the Fedora `DataSource`, using `cbt-demo-hpp`. The VM has one vCPU, 2 GiB memory, pod networking, and cloud-init SSH access for `cbt-demo`.
5. Labels the VM `cbt-demo=enabled`, waits for the VM `Ready` condition, and checks `.status.changedBlockTracking.state == Enabled`.
6. Connects through a local `oc port-forward`, writes `Hello from the VM CBT demo.` to `/home/cbt-demo/hello.txt`, and prints its SHA-256 hash.

`guest_ssh` uses a temporary randomized local port-forward, retries VM startup,
and cleans up the port-forward when the command finishes.
### 2. `make vm-backup`

`scripts/vm-backup.sh` applies `manifests/full-backup.yaml`, which creates:

- `hello-full-output`, a 30 GiB backup PVC.
- `hello-tracker`, whose source is VM `vm-cbt-demo`.
- `hello-full`, whose source is the tracker and whose output PVC is `hello-full-output`.

The script waits for the `Done=True` condition and requires `.status.type == Full`. On success, it prints `.status.checkpointName`. The completed full backup also sets `hello-tracker.status.latestCheckpoint`.

### 3. `make vm-cbt-backup`

`scripts/vm-cbt-backup.sh`:

1. Confirms the full backup completed as `Full`.
2. Waits for the tracker checkpoint to match the full backup checkpoint. This avoids starting the next backup before the base checkpoint is recorded.
3. Appends `This line was added after the full backup.` to `hello.txt` if that exact line is not already present, then prints the new SHA-256 hash.
4. Applies `manifests/incremental-backup.yaml`, creating the `hello-incremental-output` PVC and `hello-incremental` backup. Its source is the same tracker, so KubeVirt can use the tracker's checkpoint as the incremental base.
5. Waits for `Done=True`, requires `.status.type == Incremental`, and prints the new checkpoint.

The append is idempotent for retries: the same line is not appended twice.

### 4. `make vm-cbt-verify`

`scripts/vm-cbt-verify.sh` checks the API state rather than inferring success from command exit codes. It requires:

- VM CBT state `Enabled`.
- `hello-full` type `Full` and `Done=True`.
- `hello-incremental` type `Incremental` and `Done=True`.
- Non-empty, different checkpoint names.
- `hello-tracker.status.latestCheckpoint.name` equal to the incremental backup checkpoint.

It prints `CBT verification passed` only when every condition holds. The hashes printed by setup and incremental backup separately show that the guest file content changed.

## Resources and names

All workflow objects live in namespace `vm-cbt-demo`:

| Resource | Name | Purpose |
|---|---|---|
| VirtualMachine | `vm-cbt-demo` | Fedora guest with CBT label |
| DataVolume/PVC | `vm-cbt-root` | Persistent VM root disk |
| Service | `vm-cbt-ssh` | Guest SSH access for the scripts |
| VirtualMachineBackupTracker | `hello-tracker` | Stores the base/latest checkpoint |
| VirtualMachineBackup | `hello-full` | Initial full backup |
| PVC | `hello-full-output` | Full backup output |
| VirtualMachineBackup | `hello-incremental` | Backup based on the tracker checkpoint |
| PVC | `hello-incremental-output` | Incremental backup output |

Names are fixed, so the workflow is intentionally one run per namespace. To start over, use `make clean-all` first.

## Cleanup

```sh
make clean-all
```

`scripts/clean-all.sh` deletes namespace `vm-cbt-demo`, which removes the VM, DataVolume, service, backup PVCs, tracker, and backup resources. It waits for dynamically provisioned PVs with claims in that namespace to be reclaimed. It removes the guest SSH key only when the workflow's ownership marker exists. It does **not** uninstall KubeVirt/OpenShift Virtualization or delete the shared `cbt-demo-hpp` storage class and its backing storage.

## Troubleshooting signals

- Guest SSH retries indicate that the VM service or guest SSH daemon is not ready; inspect the local `oc port-forward` log and VM readiness.

- `CBT is not enabled ...`: verify the cluster feature gate and that the VM has label `cbt-demo=enabled`.
- Fedora `DataSource` not found: verify CDI's `fedora` source in `openshift-virtualization-os-images`.
- PVC remains pending: verify `cbt-demo-hpp` is available and can provision local demo volumes.
- `hello-incremental already exists`: the fixed-name workflow has already run; run `make clean-all` before another full E2E run.
- Incremental type is not `Incremental`: check that the full checkpoint reached the tracker and inspect the `VirtualMachineBackup` conditions and tracker status.
