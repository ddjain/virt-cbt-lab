# KubeVirt CBT VM backup workflow

This guide explains the repository's `make e2e` demonstration: create a Fedora VM with one 32 GiB persistent root disk and one cloud-init disk, write `/home/cbt-demo/hello.txt`, take a full backup, append a line after the full checkpoint, take an incremental backup, verify the CBT API state, and recover the post-incremental root image into a second VM.

## What the demo proves

Changed Block Tracking (CBT) records changed virtual-disk blocks. The workload file causes changes on the persistent root disk; CBT operates on the VM disk, not on a filename.

The demo proves:

1. CBT is enabled on the source VM.
2. `hello-full` completes as `Full` and records a tracker checkpoint.
3. The guest root-disk file changes after that checkpoint.
4. `hello-incremental` completes as `Incremental`, with a different checkpoint.
5. The tracker advances to the incremental checkpoint.
6. The push-mode full and incremental `rootdisk` QCOW2 artifacts can be validated, rebased, flattened, and booted independently.
7. The recovered VM contains exactly the expected two-line file.

The incremental-backup feature is preview/alpha, not a GA feature. The cluster must enable the `IncrementalBackup` feature gate. The VM manifest supplies the custom `cbt-demo=enabled` label; selector configuration is KubeVirt-version-dependent and is not treated as a preflight gate. `vm-setup.sh` and `vm-cbt-verify.sh` stop unless the resulting source VM CBT status is `Enabled`.

## Prerequisites

The target server needs:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` backup APIs.
- The `IncrementalBackup` feature gate.
- The `cbt-demo-hpp` virtualization storage class, able to provision 32 GiB source-root, 40 GiB full-output, 2 GiB incremental-output, and 40 GiB restored-root PVCs.
- The CDI `fedora` `DataSource` in `openshift-virtualization-os-images`.
- Bash, Make, `oc`, `ssh`, `ssh-keygen`, and access to the local kubeconfig.

Run the scripts where the kubeconfig is available. Set `KUBECONFIG_PATH` or `KUBECONFIG`, or let `oc` use its standard default:

```sh
make e2e KUBECONFIG_PATH=/path/to/kubeconfig
```

The configured HPP class is local/RWO demo storage. This VM is not live-migratable; the setup is for a CBT and in-cluster recovery demonstration, not production storage guidance.

## Run the full workflow

```sh
make e2e
```

`e2e` runs read-only `preflight` first. It stops before resource creation if a mandatory prerequisite fails. The sequence is:

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify -> vm-cbt-restore
```

Each stage can also be run separately:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
make vm-cbt-restore
```

The scripts emit numbered workflow steps, `→` action descriptions, `✓` success messages, and active-step failure messages. Make-level headers show five demo stages.

## Step-by-step behavior

### 1. `make vm-setup`

`scripts/vm-setup.sh`:

1. Checks that the Fedora `DataSource` is available.
2. Ensures a dedicated guest SSH key exists locally. The public key is inserted into cloud-init; the private key stays at `GUEST_KEY` with mode `0600`.
3. Applies `manifests/vm.yaml`, creating namespace `vm-cbt-demo`, source VM `vm-cbt-demo`, its `vm-cbt-root` 32 GiB DataVolume, and `vm-cbt-ssh`.
4. Configures one vCPU, 2 GiB memory, pod networking, one VirtIO root disk, and one cloud-init disk.
5. Labels the source VM `cbt-demo=enabled`, waits for `Ready`, and checks `.status.changedBlockTracking.state == Enabled`.
6. Connects through a local `oc port-forward` and writes exactly `Hello from the VM CBT demo.` to `/home/cbt-demo/hello.txt`, then prints its SHA-256.

`guest_ssh` uses the shared temporary randomized localhost port-forward, retries guest startup, treats authentication failure as terminal, and cleans up the forward. `guest_ssh_to SERVICE COMMAND` supplies the same lifecycle for the restored service.

### 2. `make vm-backup`

`scripts/vm-backup.sh` applies `manifests/full-backup.yaml`, creating:

- `hello-full-output`, a 40 GiB full-backup PVC.
- `hello-tracker`, sourced from VM `vm-cbt-demo`.
- `hello-full`, sourced from the tracker and writing to `hello-full-output`.

The script waits for `Done=True`, requires `.status.type == Full`, and prints the checkpoint. The completed full backup also updates `hello-tracker.status.latestCheckpoint`.

### 3. `make vm-cbt-backup`

`scripts/vm-cbt-backup.sh`:

1. Confirms the full backup completed as `Full`.
2. Waits for the tracker checkpoint to match the full backup checkpoint.
3. Appends `This line was added after the full backup.` to `/home/cbt-demo/hello.txt` only when that exact line is absent, then prints the new SHA-256.
4. Applies `manifests/incremental-backup.yaml`, creating `hello-incremental-output`, a 2 GiB incremental-output PVC, and the `hello-incremental` backup.
5. Waits for `Done=True`, requires `.status.type == Incremental`, and prints the new checkpoint.

### 4. `make vm-cbt-verify`

`scripts/vm-cbt-verify.sh` requires:

- Source VM CBT state `Enabled`.
- `hello-full` type `Full` and `Done=True`.
- `hello-incremental` type `Incremental` and `Done=True`.
- Non-empty, different checkpoint names.
- `hello-tracker.status.latestCheckpoint.name` equal to the incremental checkpoint.

### 5. `make vm-cbt-restore`

`scripts/vm-cbt-restore.sh` performs a five-step in-cluster recovery:

1. Reads both completed backup APIs and requires the full backup to be `Full/Done=True`, the incremental backup to be `Incremental/Done=True`, and each `.status.includedVolumes[*].volumeName` set to exactly `rootdisk`.
2. Enforces one run per namespace by refusing existing `vm-cbt-restored`, `vm-cbt-restored-root`, or `vm-cbt-restore` resources. It resolves exactly one running source `virt-launcher` pod and uses that pod's `compute` container image for the conversion Job.
3. Applies `restore-storage.yaml`. The Job requires exactly one artifact at each push-mode path:

   ```text
   <backup-pvc>/vm-cbt-demo/<backup-name>-<timestamp>/<backup-name>-rootdisk.qcow2
   ```

   It mounts both backup PVCs read-only, copies the incremental artifact to `/work/incremental.qcow2`, checks the full artifact, rebases the copy to the full artifact, checks the rebased incremental copy, flattens the chain with `qemu-img convert` to a raw `disk.img`, resizes the result with `--shrink` to the Fedora image geometry of 34,236,006,400 bytes, validates the raw image with `qemu-img info`, and sets mode `0666`. Raw images do not support `qemu-img check`; `qemu-img info` verifies that the final image opens with the expected format. The incremental artifact's embedded backing filename points to the source VM's private path, so the copy is rebased before validation; neither backup PVC is modified. KubeVirt requires the filesystem-PVC image to be named `disk.img` at the PVC root.
4. Applies `restored-vm.yaml` only after the Job completes. It boots `vm-cbt-restored` with one vCPU, 2 GiB memory, root PVC `vm-cbt-restored-root`, and service `vm-cbt-restored-ssh`. The restored VM has a unique `vm-cbt-restore=enabled` label and does not carry the CBT label.
5. Uses the shared SSH helper to assert that `/home/cbt-demo/hello.txt` equals exactly:

   ```text
   Hello from the VM CBT demo.
   This line was added after the full backup.
   ```

   It prints the restored file's SHA-256.

A missing or duplicate artifact, invalid QCOW2, failed rebase/conversion, failed Job, or failed guest assertion stops the stage and preserves the Job and logs for diagnosis. This path intentionally does not use `VirtualMachineRestore`: that API consumes `VirtualMachineSnapshot` objects, not these `VirtualMachineBackup` push artifacts.

## Resources and names

All workflow objects remain in namespace `vm-cbt-demo`:

| Resource | Name | Purpose |
|---|---|---|
| VirtualMachine | `vm-cbt-demo` | Fedora source guest with CBT label |
| DataVolume/PVC | `vm-cbt-root` | 32 GiB persistent source root disk |
| Service | `vm-cbt-ssh` | Source guest SSH access |
| VirtualMachineBackupTracker | `hello-tracker` | Base/latest checkpoint |
| VirtualMachineBackup | `hello-full` | Initial full backup |
| PVC | `hello-full-output` | 40 GiB full backup output |
| VirtualMachineBackup | `hello-incremental` | Tracker-based incremental backup |
| PVC | `hello-incremental-output` | 2 GiB incremental backup output |
| PVC | `vm-cbt-restored-root` | 40 GiB flattened restored root image |
| Job | `vm-cbt-restore` | QCOW2 validation and flattening |
| VirtualMachine | `vm-cbt-restored` | Recovered guest |
| Service | `vm-cbt-restored-ssh` | Recovered guest SSH access |

Names are fixed, so the workflow is intentionally one run per namespace. Run `make clean-all` before starting over. All source, backup, restore, and recovered-VM resources are removed together by namespace cleanup.

## Cleanup

```sh
make clean-all
```

Cleanup deletes namespace `vm-cbt-demo` and waits for dynamically provisioned PVs with claims in that namespace to be reclaimed. It does not uninstall KubeVirt/OpenShift Virtualization or delete the shared storage class. The demonstration is in-cluster recovery, not an offsite backup product.

## Troubleshooting signals

- Guest SSH retries indicate that the service or SSH daemon is not ready; inspect port-forward output and VM readiness.
- `CBT is not enabled`: verify the feature gate and source VM label `cbt-demo=enabled`.
- PVC remains pending: verify `cbt-demo-hpp` can provision local demo volumes.
- `hello-incremental already exists`: run `make clean-all` before another fixed-name workflow.
- Restore Job artifact errors: inspect `oc logs job/vm-cbt-restore -n vm-cbt-demo`; do not overwrite backup PVCs or substitute snapshot restore.
