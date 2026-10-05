# Windows Server 2022 VM and Golden Image Setup Runbook

This runbook records the implemented setup from the Windows Evaluation ISO through a reusable golden image, a runtime clone, and a full CBT E2E run. It describes the current repository workflow and the target OpenShift cluster—not a copy/paste of the older `hostpath-csi`/`localblock-sc` setup.

## 1. Result and resource layout

The workflow installs Windows Server 2022 Standard Evaluation, configures Python 3.12.4 and three startup workloads, syspreps the installer disk, and publishes a reusable CDI DataSource.

| Purpose | Resource | Namespace | Storage / lifetime |
|---|---|---|---|
| Windows installer ISO | DataVolume `windows-iso` | `vm-cbt-images` | 6Gi Filesystem PVC on `cbt-demo-hpp`; temporary after image creation |
| Installer VM disk | DataVolume `windows-installer-disk` | `vm-cbt-images` | 40Gi Block PVC on `ocs-storagecluster-ceph-rbd-virtualization`; temporary source disk |
| Installer VM and answer Secret | `windows-installer`, `windows-installer-answer` | `vm-cbt-images` | Temporary; removed after the golden clone succeeds |
| Reusable image | DataVolume/PVC `windows-golden` | `vm-cbt-images` | 40Gi Block PVC on `ocs-storagecluster-ceph-rbd-virtualization`; survives run cleanup |
| Reusable image reference | DataSource `windows-server-2022` | `vm-cbt-images` | Points to `windows-golden`; CDI clone-source permission is granted to the workflow namespace |
| Runtime VM and disk | `vm-${RUN_ID}`, `vm-disk-${RUN_ID}` | `vm-cbt-demo` | Run-scoped 40Gi Block clone from the DataSource |
| Runtime OOBE answer | Secret `windows-oobe-${RUN_ID}` | `vm-cbt-demo` | Run-scoped; generated from the password file and removed by `make clean-all` |
| Full/incremental backups | `vm-backup-*`, `vm-incremental-*` and PVCs | `vm-cbt-demo` | Run-scoped; 48Gi and 30Gi Filesystem PVCs on `ocs-storagecluster-ceph-rbd` |

The golden image contains `C:\Program Files\Python312\python.exe`, workload scripts under `C:\workloads\`, and a SYSTEM startup task named `StartWorkloads`.

## 2. Prerequisites and protected inputs

Run Make targets on a host with the target kubeconfig and the repository checkout. The workflow requires OpenShift Virtualization/KubeVirt, CDI, the `IncrementalBackup` feature gate, the backup APIs, and these storage classes:

- `cbt-demo-hpp` Filesystem PVCs for the installer ISO;
- `ocs-storagecluster-ceph-rbd-virtualization` Block PVCs for Windows disks;
- `ocs-storagecluster-ceph-rbd` Filesystem PVCs for backup data.

Copy `.env.example` to `.env`, then configure:

- `WINDOWS_ADMIN_PASSWORD_FILE`: readable, gitignored file containing one non-empty password line. Required for the first image build **and every runtime clone**, because each clone needs an unattended OOBE Secret. Keep the file mode restricted; never put the password in `.env`, manifests, command-line arguments, or logs.

- `WINDOWS_ISO_PATH`: local path to a Windows Server 2022 Evaluation ISO, required only if `vm-cbt-images/windows-iso` is not already `Succeeded`. The ISO is about 5.04 GB; keep it outside Git and the repository sync payload.
- `RESTORE_HELPER_IMAGE`: for full E2E restore verification, a pushed image built from `images/restore-helper/Dockerfile`. It must provide `qemu-img`, `util-linux`, and `ntfs-3g`; the restore pod requires privileged access and a host `/dev` mount for loop devices.

The password file is plain UTF-8 text with exactly one password and one
trailing newline. Do not include `WINDOWS_ADMIN_PASSWORD=`, quotes, a username,
or any additional lines. Create it without placing the password in shell
history:

```sh
umask 077
read -r -s -p "Windows Administrator password: " WINDOWS_ADMIN_PASSWORD
printf '\n'
printf '%s\n' "$WINDOWS_ADMIN_PASSWORD" > .windows-admin-password
unset WINDOWS_ADMIN_PASSWORD
```

Set the matching path in `.env`:

```text
WINDOWS_ADMIN_PASSWORD_FILE=.windows-admin-password
```

The setup scripts reject an empty file or embedded newline characters and read
the password without printing it.

Do not reuse the historical setup's passwords, `hostpath-csi`, or `localblock-sc` assumptions. The password is rendered at runtime into a Kubernetes Secret; tracked answer-file templates contain placeholders only.

Before the first individual workflow target, run the read-only preflight:

```sh
make preflight VM_OS=windows
```

`make windows-vm-setup` and `make e2e` also invoke preflight automatically. Preflight verifies inputs and cluster access; it does not create resources.

## 3. First-time golden-image build

### 3.1 Stage and upload the ISO

1. Transfer the Evaluation ISO to the execution host and compare its SHA-256 with the workstation copy. Do not place the ISO in the repository.
2. Set `WINDOWS_ISO_PATH` in the execution environment.
3. Run `make windows-golden-image`.
4. The builder applies `manifests/windows-image.yaml`: it creates `vm-cbt-images` if needed and a 6Gi `windows-iso` DataVolume using `cbt-demo-hpp` in **Filesystem** mode.
5. After CDI reports `UploadReady`, the builder creates an `UploadTokenRequest`, reads the short-lived token from that create response, and streams the ISO to the CDI upload-proxy route. It waits for the DataVolume phase to become `Succeeded`; the CDI phase is the success signal, not the upload HTTP connection closing cleanly.

The Filesystem ISO PVC is intentional. In this cluster, a Block-mode ISO PVC could not be presented to KubeVirt's SATA CD-ROM as a regular file, and firmware reported the CD-ROM as missing. The earlier cluster used a different ISO storage path; follow the current manifest and plan instead.

On later runs, a completed `windows-iso` is reused. If `windows-server-2022` already exists, the golden-image target exits without reinstalling Windows.

### 3.2 Prepare the unattended installer VM

1. The script reads the password file without printing the password, validates and renders `scripts/windows-autounattend.xml.tmpl` into a mode-600 temporary file, then creates the temporary `windows-installer-answer` Secret. It deletes the temporary file after the Secret is created.
2. The VirtIO guest-tools image is resolved from the installed OpenShift Virtualization CSV; a pinned fallback is used only if the CSV has no matching related image.
3. The installer VM manifest uses a 40Gi Block root disk, 8Gi memory, 4 vCPUs, an EFI bootloader without Secure Boot, SATA disks/CD-ROMs, a VirtIO driver CD, a QEMU Guest Agent channel, and the ISO as the first boot device. The generated Secret is mounted as a Sysprep volume for the initial unattended install.
4. The UEFI firmware can pause at the “Press any key to boot from CD or DVD” prompt. The builder waits for the VMI, virt-launcher pod, and libvirt domain, then sends one Space key with `virsh send-key`.
5. Windows Setup consumes the answer file for partitioning and installation. Allow the unattended install and first boot to finish; the script waits for `AgentConnected` before sending guest commands.

The answer file accepts the evaluation license, creates EFI/MSR/Windows
partitions, selects the `Windows Server 2022 SERVERSTANDARD` image, and puts
VirtIO `DriverPaths` in the `windowsPE` pass so setup can see the VirtIO
devices. First-logon commands disable hibernation, create `C:\cbt-data`, and
install the VirtIO guest tools package from its CD-ROM; the template sets UTC
and leaves Windows in OOBE state.

The initial-install file is `autounattend.xml`. Runtime clones need the distinct OOBE file name `unattend.xml`; Windows reads these files in different setup passes.

### 3.3 Install and verify guest software/workloads

After the guest agent connects, the workflow probes the QEMU agent socket
before starting guest operations. `AgentConnected=True` is a VMI condition,
while the agent socket can still be settling during Windows boot; the probe
closes that readiness gap. During `guest-exec-status` polling, transient agent
command failures are retried within the existing command timeout.

`scripts/windows-golden-image-setup.sh`
sources the helper and performs PowerShell guest operations:
`scripts/windows-guest-agent.sh` locates the VMI's virt-launcher pod, invokes
`virsh qemu-agent-command` in its `compute` container, transfers temporary
PowerShell scripts with `guest-file-open/write/close`, launches them with
`guest-exec`, polls `guest-exec-status`, decodes output, and removes the
temporary script. This is the command path used instead of SSH, RDP, or VNC.

1. Create `C:\cbt-data` and disable hibernation.
2. Install Python 3.12.4 from `www.python.org` if it is not already at `C:\Program Files\Python312\python.exe`.
3. Create three workloads under `C:\workloads\`:
   - `file-writer.py`: appends a UTC timestamp about once per second to `C:\data\test\log.txt`;
   - `sqlite-writer.py`: inserts a UTC row about every two seconds into `C:\data\test\test.db`;
   - `http-server.py`: serves `C:\data` on port 8080.
4. Create `start-workloads.ps1` and register `StartWorkloads` as a startup Scheduled Task running as SYSTEM with highest privileges. The script launches the three Python processes hidden and avoids duplicate launches.
5. Stop any test processes, remove generated workload data, start the scheduled task, and verify file lines, SQLite rows, HTTP 200, three Python processes, Python 3.12.4, and SYSTEM task ownership. Stop the test processes and clear generated files again so the golden image starts clean.
6. Remove the Microsoft Edge AppX package if present; it blocked Sysprep on the first attempt.

The installer and QEMU Guest Agent output is decoded before validation, including CRLF and wrapped base64 output. A successful check prints the Python version, workload counts, HTTP status, process count, and task principal; it does not print credentials.

### 3.4 Sysprep, publish, and clean temporary installer resources

1. Patch `windows-installer` to `runStrategy: Manual` before Sysprep. This prevents a shutdown from restarting the VM.
2. Run `sysprep.exe /generalize /oobe /shutdown` through QEMU Guest Agent and wait for the VMI to stop/delete.
3. Apply `manifests/windows-golden-datasource.yaml`. CDI clones the stopped installer disk to `vm-cbt-images/windows-golden` using the immediate-bind annotation and the ODF virtualization Block class.
4. Wait for `windows-golden` to reach `Succeeded`. The same manifest creates DataSource `windows-server-2022` and a clone-source RoleBinding for the workflow namespace's default service account.
5. The builder deletes the temporary installer VM, installer disk DataVolume, ISO DataVolume, and initial answer Secret. It retains the golden PVC and DataSource in `vm-cbt-images`.

Check the published cache with:

```sh
oc get dv windows-golden -n vm-cbt-images
oc get pvc windows-golden -n vm-cbt-images
oc get datasource windows-server-2022 -n vm-cbt-images
```

Expected: DataVolume `Succeeded`, PVC `Bound`, and the DataSource's PVC source is `windows-golden`. Do not delete these shared image resources during routine run cleanup.

## 4. Clone the golden image for one Windows VM

Use `make windows-vm-setup` when you want a single verified VM before taking backups:

```sh
make windows-vm-setup
```

The target runs Windows preflight, builds the cache only if absent, generates a run ID/report ID, and creates a run-scoped OOBE Secret from `WINDOWS_ADMIN_PASSWORD_FILE`. It applies `manifests/windows-vm.yaml`, which clones DataSource `vm-cbt-images/windows-server-2022` into a 40Gi Block DataVolume in `vm-cbt-demo`. The VM uses 4 vCPUs, 8Gi memory, Q35, EFI without Secure Boot, SATA for the root disk and Sysprep CD, QEMU Guest Agent, and masquerade pod networking.

The clone is sysprepped in OOBE state. Its run-scoped Secret supplies `unattend.xml` so OOBE completes unattended and does not stop at the interactive “Hi there” screen. The script waits for:

1. VM Ready after OOBE;
2. `.status.changedBlockTracking.state == Enabled`;
3. VMI condition `AgentConnected`;
4. workload verification: Python 3.12.4, file writes, SQLite rows, HTTP 200, three Python processes, and `StartWorkloads` owned by SYSTEM.

The runtime OOBE template also applies `en-US` locale/UTC, hides interactive
OOBE pages, and sets the built-in Administrator password from the Secret.

After startup verification, PowerShell through QEMU Guest Agent creates `GUEST_BASE_FILE_COUNT` deterministic files under `C:\cbt-data\workload`. Each size is selected from the configured inclusive whole-MiB range. Setup records the file paths, byte sizes, and SHA-256 values in `report/<REPORT_ID>/workload-manifest.json`.

## 5. Run the Windows CBT E2E flow

Set a unique, lowercase DNS-safe run name and invoke:

```sh
make e2e VM_OS=windows NAME=windows-cbt-1
```

The flow runs setup, full backup, incremental backup, and verification in order. Do not run two profiles concurrently from the same checkout; `state/` is single-run state.

### 5.1 Full backup

The full stage creates the run-labeled full-backup PVC, tracker, and backup object. For the Windows profile the full PVC is 48Gi on `ocs-storagecluster-ceph-rbd`. It waits for `Done=True`, requires `.status.type == Full`, and records the checkpoint. The baseline manifest remains the expected full-restore file set.

### 5.2 Mutate the guest and create the incremental backup

After the full checkpoint, the guest-agent helper adds `GUEST_INCREMENTAL_FILE_COUNT` new deterministic files under `C:\cbt-data\workload`, using the same inclusive per-file size range. It flushes the writes, records each addition in the run manifest, and verifies the resulting file set. The incremental stage creates a 30Gi PVC and backup object on `ocs-storagecluster-ceph-rbd`, waits for `Done=True`, requires type `Incremental`, checks for a distinct checkpoint, and confirms the tracker has advanced to that checkpoint.

### 5.3 Verify API state and restored guest bytes

`vm-cbt-verify` checks CBT is `Enabled`, both backups completed with correct types, the checkpoints are distinct, and the tracker matches the incremental checkpoint. It then runs `scripts/vm-cbt-restore-test.sh` with `manifests/windows-restore-verify-pod.yaml`:

1. Rebase the incremental qcow2 onto the full qcow2 with `qemu-img`, then convert the full-only and combined images to raw.
2. Attach each raw image with partition scanning and select the largest NTFS partition, querying `blkid` when `lsblk` reports an empty filesystem type.
3. Mount the selected partition read-only with `ntfs3` when available or the helper image's `ntfs-3g` command.
4. Inventory `C:\cbt-data\workload` in both restored images and compare file count, total payload bytes, and canonical manifest hash.
5. Require the full-only restore to match the N-file baseline and the combined restore to match the N+M file set. The manifest hash covers each relative path, size, and per-file SHA-256.

The Windows helper image must be pushed to a registry reachable by the cluster and selected with `RESTORE_HELPER_IMAGE`. Build/push from the repository root, replacing the example reference with a registry you control:

```sh
export RESTORE_HELPER_IMAGE=registry.example/project/cbt-restore-helper:latest
podman build -t "$RESTORE_HELPER_IMAGE" images/restore-helper
podman push "$RESTORE_HELPER_IMAGE"
```

The target cluster's kernel did not provide the `ntfs3` mount driver, so successful restore verification used the `ntfs-3g` executable installed by the helper Dockerfile. The restore pod is privileged and uses host `/dev` for loop devices; a PodSecurity warning is expected unless the namespace policy explicitly permits it.

## 6. Executed verification record

The completed setup published the 40Gi golden image and DataSource. Four managed Windows VMs were observed Ready, CBT-enabled, and QEMU Guest Agent-connected while referencing that DataSource. A live guest query reported Microsoft Windows Server 2022 Standard Evaluation, build 20348.

The repeat run `windows-golden-repeat-20261001` passed the full flow after one transient QEMU Guest Agent disconnect during workload verification. The agent recovered; a direct workload check passed, and rerunning the same named E2E completed. The successful clone reported Python 3.12.4, 352 file-writer lines, 176 SQLite rows, HTTP 200, three Python processes, and the SYSTEM startup task. Its full and incremental checkpoints were distinct and the tracker pointed to the incremental checkpoint. Restore hashes matched the guest-recorded values; the marker was absent from the full-only restore and present in the combined restore. The report is `report/run_20261001T012036Z/report.json` on the execution host.

Installation screenshots are kept in the local, Git-ignored `screenshot/` directory.

## 7. Troubleshooting notes from this setup

| Symptom | Cause | Response used |
|---|---|---|
| Firmware reports the ISO CD-ROM as missing or has no disk capacity | A Block PVC is not presented as a regular file-backed SATA CD-ROM on this target | Use the current 6Gi Filesystem DataVolume on `cbt-demo-hpp`; do not copy the older `localblock-sc` ISO setup |
| Firmware pauses before Windows Setup | OVMF waits at the CD-boot prompt | The builder waits for the launcher/domain and sends one Space key |
| CDI clone remains pending with WaitForFirstConsumer storage | Consumer binding prevents clone population from starting | Keep `cdi.kubevirt.io/storage.bind.immediate.requested: "true"` on the upload and clone DataVolumes |
| OOBE waits interactively | Sysprepped image requires a correctly named `unattend.xml` OOBE file | Supply the run-scoped Sysprep Secret; initial installation uses `autounattend.xml` |
| Sysprep fails with AppX error `0x80073cf2` | Microsoft Edge AppX package is installed per-user | Remove the package with the builder's all-users check, then run Sysprep |
| VM restarts after Sysprep shutdown | `RerunOnFailure` treats shutdown as failure | Set installer `runStrategy` to `Manual` before Sysprep |
| Golden clone sits in `PendingPopulation` | Storage binding delays clone pod scheduling | Apply the immediate-bind CDI annotation and verify the ODF Block class |
| Restore pod cannot find an NTFS partition | `lsblk`'s empty `FSTYPE` field shifts shell columns | Parse `NAME,SIZE,TYPE` only and query `blkid`/`lsblk` for the filesystem type separately |
| `mount -t ntfs3` fails | Target node kernel lacks `ntfs3` | Use the helper image's `ntfs-3g` binary; rebuild and push the helper after adding NTFS support |
| Guest-agent command times out after `AgentConnected` | One run experienced a temporary QEMU Guest Agent disconnect during workload verification | Check the live `AgentConnected` condition and launcher/guest-agent state. In the recorded run, the agent recovered and the same named E2E completed on retry; do not force-delete the VMI as a first response |

## 8. Cleanup and rebuild boundaries

`make clean-all` is destructive to all `virt-cbt-lab` run-labeled resources in `vm-cbt-demo`: it removes run VMs/DataVolumes, backup objects and PVCs, tracker, services, restore pods, and run-scoped OOBE Secrets, and clears local run state. It does **not** delete the namespace, reports, or the shared golden DataVolume/DataSource in `vm-cbt-images`.

The golden-image builder intentionally exits without changes when DataSource `windows-server-2022` already exists. Rebuilding is a separate, coordinated action: stop dependent work, remove/replace the shared image resources deliberately, provide the password file and ISO as needed, then run the builder again. Do not use `make clean-all` to rebuild or remove the shared golden image.

## 9. References

- [KubeVirt: installing Windows 11 from an ISO](https://kubevirt.io/2022/KubeVirt-installing_Microsoft_Windows_11_from_an_iso.html) — general ISO/CD-ROM and VirtIO patterns; Windows 11-specific TPM/Secure Boot requirements were not copied to this Server 2022 profile.
- [Create a Windows VM in Kubernetes using KubeVirt](https://medium.com/adessoturkey/create-a-windows-vm-in-kubernetes-using-kubevirt-b5f54fb10ffd) — generic KubeVirt/CDI workflow on KinD.
- [KubeVirt up and running with a Windows VM](https://blog.krum.io/kubevirt-up-and-running-and-a-windows-vm-sorrynotsorry/) — Windows Server 2022 installation context.
- [Historical golden-image setup commit](https://github.com/redhat-chaos/vmshift-validator/commit/9eb78c2b74326e3e722ee0d8f87262e9037d735f) — source-cluster experience used as background; its storage classes and credentials are not target-cluster defaults.
- [`windows-cbt-plan.md`](windows-cbt-plan.md) and [`vm-cbt-workflow.md`](vm-cbt-workflow.md) — design and exact repository workflow references.
