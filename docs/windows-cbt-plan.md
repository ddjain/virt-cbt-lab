# Windows VM CBT E2E Plan

## Decision

Add a Windows profile without changing the existing Debian default:

```text
make e2e                               # existing Debian workflow
make windows-vm-setup                 # validate one Windows VM + backup test file first
make e2e VM_OS=windows NAME=win-cbt-1 # Windows CBT workflow after setup validation
make windows-golden-image             # optional one-time image preparation by itself
```

The Windows workflow reuses the existing backup, tracker, checkpoint, reporting, and API verification logic. Windows-specific code is limited to golden-image preparation, guest mutation, and restore-filesystem inspection.

Use the QEMU Guest Agent for Windows guest operations instead of SSH. This matches the historical Windows setup approach and works in the target environment without `virtctl`.

## Current findings

- Existing Linux flow:

  ```text
  vm-setup
    -> write/hash hello.txt
  vm-backup
    -> full backup + tracker checkpoint
  vm-cbt-backup
    -> append data and marker
    -> incremental backup
  vm-cbt-verify
    -> API checks
    -> qemu-img restore and guest-file hash checks
  ```

- Historical reference:
  [setup-windows-golden-image.sh](https://github.com/redhat-chaos/vmshift-validator/blob/main/scripts/setup-windows-golden-image.sh)
- The historical reference assumes a different cluster, `hostpath-csi`, `localblock-sc`, and a hardcoded password; it must not be copied unchanged.
- Background references:
  - [KubeVirt Windows 11 ISO installation](https://kubevirt.io/2022/KubeVirt-installing_Microsoft_Windows_11_from_an_iso.html) — ISO/CD-ROM and VirtIO-device patterns; Windows 11-specific TPM/Secure Boot requirements are not copied into this Server 2022 profile.
  - [Create a Windows VM in Kubernetes using KubeVirt](https://medium.com/adessoturkey/create-a-windows-vm-in-kubernetes-using-kubevirt-b5f54fb10ffd) — generic KubeVirt/CDI ISO-install workflow on KinD.
  - [KubeVirt up and running with Windows Server 2022](https://blog.krum.io/kubevirt-up-and-running-and-a-windows-vm-sorrynotsorry/) — Windows Server 2022 installation and VirtIO context.
  - [Historical golden-image setup commit](https://github.com/redhat-chaos/vmshift-validator/commit/9eb78c2b74326e3e722ee0d8f87262e9037d735f) — source-cluster setup example.
- The target environment provides:
  - `cbt-demo-hpp` Filesystem PVCs with `WaitForFirstConsumer` binding;
  - ODF classes `ocs-storagecluster-ceph-rbd-virtualization` (Block) and `ocs-storagecluster-ceph-rbd` (Filesystem);
  - KubeVirt `v1.8.4` with the `IncrementalBackup` feature gate;
  - the CDI upload proxy and a readable kubeconfig through the active cluster context.
- The Windows installer guest needs outbound HTTPS access to `www.python.org` to install Python 3.12.4 during golden-image preparation.
- The Windows Server 2022 Evaluation ISO is approximately 5.04 GB. Keep it on the workstation or target admin host, outside the repository.

## Phase 1: Transfer and cache the ISO

Run from the workstation:

1. Calculate the ISO SHA-256.
2. Copy it to a local admin host outside the repository, using a path such as `/path/to/SERVER_EVAL_x64FRE_en-us.iso`.

3. Calculate the remote SHA-256 and compare it with the local value.
4. Set `WINDOWS_ISO_PATH` to that local path in the environment used for `make windows-golden-image` or `make windows-vm-setup`.

Keeping the ISO outside the repository avoids synchronizing a 5 GB binary with `sync.sh` or including it in Git state.

## Phase 2: Build the Windows golden image

Use the existing `vm-cbt-images` cache namespace so the Windows image survives `make clean-all` like the Debian image.

### ISO staging (implemented; Filesystem PVC supersedes the original Block-PVC plan)

The target environment has ODF Block storage, but KubeVirt's CD-ROM conversion requires a regular file-backed volume. A Block-mode ISO PVC produced `"No disk capacity"` and UEFI reported the DVD as `Not Found`, despite a verified upload. The tested fix is a **Filesystem-mode** DataVolume on `cbt-demo-hpp`, which provides the regular `disk.img` file expected by the CD-ROM. See [`windows-golden-image-progress.md`](windows-golden-image-progress.md).

Implemented as `manifests/windows-image.yaml` + `scripts/windows-golden-image-setup.sh`:

On reruns, if DataVolume `windows-iso` is already `Succeeded`, setup reuses it and does not require `WINDOWS_ISO_PATH` or upload it again.

1. Create DataVolume `windows-iso` (`spec.source.upload: {}`, 6Gi, `cbt-demo-hpp`, `VolumeMode: Filesystem`) and wait for `UploadReady`.
2. Request a short-lived token via `UploadTokenRequest`.
3. `curl --upload-file` the local ISO to the cluster's `cdi-uploadproxy` route (no `virtctl` required; the upload proxy accepts the bearer token over HTTPS).
4. Wait for the DataVolume to report `Succeeded`.
5. Attach `windows-iso` as a SATA CD-ROM to the installer VM.

The original Block-mode PVC approach is retained here only as history: it was the cause of the firmware boot failure, not a working current configuration.

### Installer VM

Create a temporary installer VM in `vm-cbt-images` with:

- Windows Server 2022 Evaluation ISO;
- 40 GiB root disk;
- 8 GiB memory;
- 4 vCPUs;
- UEFI/Q35 without Secure Boot;
- SATA root disk and ISO CD-ROM, with installer ISO first in firmware boot order;
- VirtIO container disk;
- QEMU Guest Agent channel;
- `cbt-demo-hpp` Filesystem storage for the ISO and ODF virtualization Block storage for the root disk;
- runtime-generated `autounattend.xml`.

The installer starts unattended from the SATA CD-ROM. The UEFI firmware may display
“Press any key to boot from CD or DVD”; the setup script sends a key after the
virt-launcher pod is ready. The answer file:

- accepts the Windows evaluation license;
- creates EFI, MSR, and Windows partitions;
- installs VirtIO guest tools and QEMU Guest Agent at first logon;
- configures UTC and disables hibernation;
- leaves a usable OOBE state for sysprep.

### Sysprep answer file and guest commands (implemented)

Implemented as `scripts/windows-autounattend.xml.tmpl` (tracked, no secret — only a `__ADMIN_PASSWORD__` placeholder) plus runtime substitution in `scripts/windows-golden-image-setup.sh`. KubeVirt v1.8.4 has a native `volumes[].sysprep.secret` volume source (`autounattend.xml` mounted as a generated CD-ROM), so no manual answer-file ISO needs to be built. The rendered answer file is written to a `mktemp` file, loaded into a Secret with `oc create secret generic --from-file`, and the temp file and Secret are both deleted after sysprep runs.

`Microsoft-Windows-PnpCustomizationsWinPE/DriverPaths` is valid only in the
`windowsPE` pass; keep it out of `offlineServicing` and `specialize`. See
[Microsoft's DriverPaths pass requirements](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-pnpcustomizationswinpe-driverpaths).

The answer file's `InstallTo` specifies both `DiskID` and `PartitionID`, as
[Microsoft requires](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-imageinstall-osimage-installto).

Guest commands (guest-exec, sysprep invocation) are implemented in `scripts/windows-guest-agent.sh`. KubeVirt v1.8.4 does not expose QEMU Guest Agent `guest-exec` as an API subresource, so commands run through `oc exec` into the VMI's `virt-launcher` pod and `virsh qemu-agent-command` against the domain's agent socket.

### Runtime secret handling

Do not copy the reference password into the repository. Use a local ignored file, for example:

```text
WINDOWS_ADMIN_PASSWORD_FILE=/path/to/.windows-admin-password
```

The golden-image script must:

- read the password without logging it;
- generate Kubernetes Secrets from stdin;
- never place the password in tracked manifests, command output, or documentation;
- delete installer-only secrets after the golden image is created.

### Golden image preparation

After Windows boots and the QEMU Guest Agent responds:

1. Use QEMU Guest Agent `guest-exec` to run PowerShell.
2. Confirm the QEMU Guest Agent service is running.
3. Create `C:\cbt-data` and disable hibernation.
4. Install Python 3.12.4 and create `C:\workloads\file-writer.py`,
   `sqlite-writer.py`, `http-server.py`, and `start-workloads.ps1`.
5. Register `StartWorkloads` as a highest-privilege SYSTEM task triggered at
   startup. Start it once and require file writes, SQLite rows, an HTTP 200
   from `localhost:8080`, and three Python processes.
6. Stop the workload processes and remove generated `log.txt` and `test.db`
   files so the golden image starts without workload data.
7. Remove the Microsoft Edge AppX package if present; it can block sysprep.
8. Set the installer VM to `Manual`.
9. Run:

   ```text
   sysprep.exe /generalize /oobe /shutdown
   ```

10. Clone the 40 GiB root disk into `vm-cbt-images/windows-golden`.
11. Create the `windows-server-2022` DataSource.
12. Grant the workflow namespace default service account CDI clone-source permission.
13. Delete the installer VM, ISO PVC, helper pod, and temporary secrets.

The golden image and DataSource remain outside the run namespace.

## Phase 3: Windows runtime VM

Add a Windows VM manifest based on `manifests/vm.yaml`:

- run-derived VM/DataVolume names;
- `cbt-demo=enabled`;
- workflow ownership labels;
- 40 GiB Block-mode root disk on `ocs-storagecluster-ceph-rbd-virtualization`;
- source DataSource `vm-cbt-images/windows-server-2022`;
- SATA root disk for conservative Windows boot compatibility;
- QEMU Guest Agent channel;
- pod-network masquerade;
- per-run OOBE Secret.

A Windows SSH Service is unnecessary when all guest operations use QEMU Guest Agent.

The Windows setup script should:

1. Generate the run ID and report ID.
2. Create a run-labeled OOBE Secret from `WINDOWS_ADMIN_PASSWORD_FILE`.
3. Apply the Windows VM and DataVolume.
4. Wait for the VM to become ready.
5. Require `.status.changedBlockTracking.state == Enabled`.
6. Wait for QEMU Guest Agent connectivity.
7. Verify Python 3.12.4, the `StartWorkloads` SYSTEM task, file writes, SQLite
   rows, HTTP 200 on `localhost:8080`, and three Python processes.
8. Use PowerShell through QEMU Guest Agent to create `C:\cbt-data\hello.txt`.
9. Record its SHA-256 and size in the existing state/report format.

## Phase 4: Full and incremental backup flow

Reuse the existing backup and tracker sequence.

### Full backup

Use a Windows-specific full-backup manifest with:

- 48 GiB Filesystem full-backup PVC on `ocs-storagecluster-ceph-rbd` (capacity margin for the Block-mode source);
- run-derived tracker;
- run-derived full backup.

Require `Done=True`, inspect the terminal reason, require `.status.type == Full`, and save the full checkpoint.

### Guest mutation

Add a Windows guest-agent helper. Do not duplicate generic backup orchestration.

The PowerShell mutation should:

1. Check whether the marker already exists.
2. Append a payload to `C:\cbt-data\hello.txt`.
3. Append the exact marker:

   ```text
   This line was added after the full backup.
   ```

4. Flush the Windows volume.
5. Calculate the post-mutation SHA-256.
6. Record the hash and file size.
7. Remain idempotent if retried.

Generate payload data in bounded PowerShell chunks rather than relying on Linux tools such as `/dev/urandom`, `base64`, `sync`, or `sha256sum`.

### Incremental backup

Use a Windows-specific incremental manifest with a 30 GiB Filesystem PVC on `ocs-storagecluster-ceph-rbd`.

The workflow must:

1. Wait for the full checkpoint to appear in the tracker.
2. Submit the incremental backup.
3. Require `Done=True`.
4. Inspect the terminal reason.
5. Require `.status.type == Incremental`.
6. Require a distinct checkpoint.
7. Record the incremental checkpoint and guest hash.

## Phase 5: Windows restore verification

`scripts/vm-cbt-restore-test.sh` now selects the NTFS-aware helper for `VM_OS=windows` and preserves the existing Debian ext4 restore path.

The restore flow remains:

```text
full qcow2
  -> raw full disk
incremental qcow2 rebased onto full qcow2
  -> raw combined disk
```

The Windows restore helper must:

1. Attach each raw image with `losetup -P`.
2. Select the largest NTFS partition.
3. Mount it read-only using `ntfs3` or `ntfs-3g`.
4. Read `cbt-data/hello.txt`.
5. Calculate hashes for the full-only and full-plus-incremental restores.
6. Confirm the marker is absent from the full-only restore.
7. Confirm the marker is present in the combined restore.
8. Unmount and detach loop devices using cleanup traps.

The NTFS helper parses only non-empty `lsblk` columns (`NAME,SIZE,TYPE`) and
queries filesystem type separately with `lsblk`/`blkid`; reading an empty
`FSTYPE` column in a shell `read` tuple can shift `TYPE` and hide NTFS.

The helper image includes `ntfs-3g` for Windows restore mounts; keep the ext4 path intact for Debian.

PowerShell-created files may contain CRLF line endings. Normalize line endings only for marker detection; hash comparisons must use the original bytes.

## Planned repository changes

### New files

```text
scripts/windows-golden-image-setup.sh
scripts/windows-vm-setup.sh
scripts/windows-guest-agent.sh
scripts/windows-autounattend.xml.tmpl
scripts/windows-oobe.xml.tmpl
manifests/windows-image.yaml
manifests/windows-installer.yaml
manifests/windows-vm.yaml
manifests/windows-full-backup.yaml
manifests/windows-incremental-backup.yaml
manifests/windows-restore-verify-pod.yaml
```

### Modified files

```text
Makefile
.env.example
scripts/common.sh
scripts/vm-cbt-backup.sh
scripts/vm-cbt-restore-test.sh
scripts/restore-lib.sh
scripts/clean-all.sh
preflight
images/restore-helper/Dockerfile
README.md
docs/vm-cbt-workflow.md
```

Reuse the generic full-backup and checkpoint verification code. Avoid creating a second copy of `vm-backup.sh` or `vm-cbt-verify.sh`.

Add profile selection in `common.sh`, for example:

```text
VM_OS=debian       # existing default
VM_OS=windows      # Windows guest behavior
```

The Windows Make target selects this profile only for its recursive workflow. Existing Debian commands retain their current behavior.

## Configuration additions

Document placeholders in `.env.example`:

```text
VM_OS=debian
WINDOWS_ISO_PATH=
WINDOWS_ADMIN_PASSWORD_FILE=
```

Do not put a password, ISO contents, kubeconfig, or environment-specific credentials into tracked files.

`RESTORE_HELPER_IMAGE` remains required. Rebuild and push the helper image after adding NTFS support.

## Validation plan

### Offline validation

```sh
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
make help
```

Validate all generated manifests with client-side dry runs where possible.

### Golden-image validation

Run from the workstation or admin host configured with the target kubeconfig:

1. Transfer and hash the ISO if the `windows-server-2022` DataSource is absent.
2. Stage the ISO as a Filesystem PVC and confirm `disk.img` is present.
3. Run `make windows-vm-setup`; it builds the cache if needed, installs and syspreps Windows, then creates one runtime VM and initializes `C:\cbt-data\hello.txt`.
4. Confirm CBT is `Enabled`, the QEMU Guest Agent is connected, and the guest file hash is recorded.

### E2E validation

Run from the repository checkout:

```sh
make e2e VM_OS=windows NAME=windows-cbt-1
```

Run the monitor concurrently:

```sh
make monitor VM=vm-windows-cbt-1
```

Acceptance criteria:

- Windows VM reports CBT `Enabled`;
- full backup reports `type=Full`, `Done=True`;
- incremental backup reports `type=Incremental`, `Done=True`;
- checkpoints are present and distinct;
- tracker equals the incremental checkpoint;
- full-only restore hash equals the pre-mutation hash;
- full-only restore lacks the marker;
- combined restore hash equals the post-mutation hash;
- combined restore contains the marker;
- `report.json` records the Windows profile, hashes, checkpoints, and restore checks.

### Cleanup validation

```sh
make clean-all
```

`make clean-all` must remove run-scoped Windows resources, including VM, DataVolume, backup PVCs, tracker, restore pod, and OOBE Secret, while preserving:

- `vm-cbt-images/windows-golden`;
- the Windows DataSource;
- the cached Debian image;
- unrelated namespace resources.

## Main risks

1. **UEFI CD boot prompt**: the firmware pauses before booting the ISO; the installer script selects the ISO first and sends a key after the launcher pod is ready.
2. **Windows VirtIO guest tools**: verify first-logon installation on the live VirtIO image before relying on QEMU Guest Agent readiness.
3. **QEMU Guest Agent readiness**: the helper must poll `guest-exec-status`, check exit codes, and treat agent loss during sysprep as expected only after the VM reaches `Stopped`.
4. **NTFS restore support**: the privileged restore pod needs working `ntfs3` or `ntfs-3g` support on the target node.
5. **ODF capacity**: each run requests a 40Gi Block-mode Windows root disk, 48Gi full-backup PVC, and 30Gi incremental-backup PVC. Serialize runs and confirm available capacity.
6. **Secret cleanup**: runtime OOBE Secrets need run labels and explicit cleanup. The historical hardcoded password must not be retained.
7. **Shared local state**: the existing `state/` directory is single-run state. Do not run Debian and Windows workflows concurrently from the same checkout.
