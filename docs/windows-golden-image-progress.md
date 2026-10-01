# Windows Golden Image — Progress Summary (2026-10-01)

## Status: Golden image and repeat Windows E2E verified from the cached DataSource.
Remote Windows preflight passed all 96 checks with the cached ISO PVC and
existing gitignored password file configured.

The remote `make windows-golden-image` result reported `windows-golden`
`Succeeded` and published `windows-server-2022`; the installer VM, root
DataVolume, ISO DataVolume, and answer Secret were removed. Inventory confirmed
the DataSource points to the golden PVC.

The first installer attempt exposed two answer-file issues: an unsupported
`offlineServicing` placement for `DriverPaths`, and an `InstallTo` target
missing `DiskID`. Both are corrected, with render-time checks. The installer
also needed the CNV VirtIO tools image for QEMU Guest Agent; the builder now
selects it from the cluster CSV. Guest output decoding was fixed for CRLF and
wrapped base64.

`make windows-vm-setup` completed on a runtime clone: CBT is `Enabled`, QEMU
Guest Agent connected, Python 3.12.4 reported, the file and SQLite writers
produced data, HTTP returned 200, all three Python processes were present, and
`StartWorkloads` ran as SYSTEM. It recorded the CBT guest-file hash.

The first Windows E2E clone passed workload checks after the guest-agent fix.
Its full backup completed as `Full`/`Done=True`; the retry of the incremental
step completed as `Incremental`/`Done=True` with a distinct tracker checkpoint.

The NTFS partition scan now finds the Windows data partition. The original
helper image lacked NTFS support, so a fresh image was built from
`images/restore-helper/Dockerfile`, pushed under a new tag, and selected in the
remote `.env`. Its `/usr/bin/ntfs-3g` binary was verified. After this refresh,
`make vm-cbt-verify` passed: CBT is enabled, checkpoint types and IDs are
correct, and the tracker points to the incremental checkpoint. The full-only
restore hash `25352dac0179490050b344a3c78910f3e3ec3c2da431b3d9e1aa32d8d2fa1700`
and combined restore hash
`c5dd977fbb57e2448e1e2f7db97f8e66f371af66be8de348fd253d6963227eab` matched
the guest-recorded hashes; only the combined restore contains the incremental
marker. The initial E2E command stopped at this restore step before the helper
refresh; its verification target passed on retry.

## Current live audit

The Windows preflight now passes all 96 checks with the remote gitignored
password file configured. `windows-golden` is `Succeeded`; its 40Gi Block PVC
is `Bound` on `ocs-storagecluster-ceph-rbd-virtualization`, and
`windows-server-2022` points to that PVC. All four Ready VMs reference this
DataSource; all report CBT `Enabled` and QEMU Guest Agent `AgentConnected`.

QEMU Guest Agent on a live clone reported Microsoft Windows Server 2022
Standard Evaluation, build `20348`; the retry below independently verified
the cloned guest's workload startup.

The first attempt with this run ID lost QEMU Guest Agent access during workload
verification; after the agent recovered, a direct workload check passed. The
retry of `make e2e VM_OS=windows NAME=windows-golden-repeat-20261001` passed all
stages. The clone was Ready with CBT enabled and QEMU Guest Agent connected;
Python `3.12.4`, 352 file lines, 176 SQLite rows, HTTP `200`, three Python
processes, and the `StartWorkloads` SYSTEM task were verified. The full backup
was `Full`/`Done=True` at checkpoint
`vm-backup-windows-golden-repeat-20261001-2026-10-01_01-20-48`; the incremental
was `Incremental`/`Done=True` at checkpoint
`vm-incremental-windows-golden-repeat-20261001-2026-10-01_01-21-44`, matching
the tracker's latest checkpoint. Restores matched guest hashes:
full-only `b74a57182830bafe65b074d25e15d0fd7d21c9b12e596748f5ba72cc56249e12`,
full-plus-incremental
`19cb5c9d3b32d38fc787c0d27906fe43214bef3e63ecd8e1f1e318bd62a1fad7`.
The marker was absent from the full-only restore and present in the combined
restore. Report: `run_20261001T012036Z`.

## What we're building

Build a reusable Windows Server 2022 golden image and publish the
`windows-server-2022` DataSource in `vm-cbt-images`.

The builder target is `make windows-golden-image`; `make windows-vm-setup`
builds the image when absent, then clones it and validates startup workloads.
`make e2e VM_OS=windows` runs the Windows backup flow after setup is verified.

## Historical findings from an earlier cluster run

- **ISO staged on the target cluster's admin host** from `WINDOWS_ISO_PATH`
  (5,044,094,976 bytes), sha256
  `3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325`,
  verified byte-for-byte against the workstation copy and CDI-managed PVC.
- **Admin password file** is at the local path configured by
  `WINDOWS_ADMIN_PASSWORD_FILE` (gitignored, never logged or tracked).
- **Windows golden-image sources** are in the workstation checkout and were
  synchronized to the cluster's working copy for live validation:
  - `scripts/windows-golden-image-setup.sh` — orchestration script
  - `scripts/windows-guest-agent.sh` — guest-exec via `virsh
    qemu-agent-command` run inside the VMI's own virt-launcher pod (this
    cluster has no `virtctl` and KubeVirt v1.8.4 has no guest-exec API
    subresource, so this was the working substitute)
  - `scripts/windows-autounattend.xml.tmpl` — Windows answer-file template,
    password substituted at runtime, never committed with a real secret
  - `manifests/windows-image.yaml` — ISO imported as a Filesystem-mode PVC
    via CDI upload (see "Root-caused and fixed" below for why Filesystem, not
    Block)
  - `manifests/windows-installer.yaml` — temporary installer VM, all disks
    (root, installer ISO, virtio-win driver CD, sysprep CD) on **SATA** bus,
    UEFI/no-SecureBoot
  - `manifests/windows-golden-datasource.yaml` — clone-target DataVolume,
    `windows-server-2022` DataSource, clone-source RoleBinding
  - `Makefile` target `windows-golden-image`, `.env.example` entries
    (`WINDOWS_ISO_PATH`, `WINDOWS_ADMIN_PASSWORD_FILE`), `.gitignore` entry
    for the password file, README.md / docs/vm-cbt-workflow.md notes
- **Offline validation passed**: `find . -type f -name '*.sh' -print0 | xargs
  -0 -n1 bash -n`, `make help`, and a manual secret scan of the diff.
- **Root-caused and fixed a real boot failure** (this session): the
  installer VM's UEFI firmware reported the Windows ISO CD-ROM as
  `Not Found` on every boot attempt (`BdsDxe: failed to load Boot0001 "UEFI
  QEMU DVD-ROM ..." ... Not Found`), even though the ISO content on the PVC
  was verified byte-identical to the source file. Root cause: the ISO was
  staged as a **Block**-mode PVC on
  `ocs-storagecluster-ceph-rbd-virtualization`; KubeVirt's CD-ROM disk
  conversion always builds a qemu disk with the `file` driver (expecting a
  real file with a working `stat()` size) regardless of the underlying PVC's
  `volumeMode`, and a Block-mode PVC has no such file — `virt-launcher` logs
  showed recurring `"No disk capacity"` errors for exactly this volume, and
  OVMF's SATA/AHCI boot probe read that as an empty/absent drive. Fix:
  switched `windows-iso` to a **Filesystem**-mode PVC on `cbt-demo-hpp`
  (with the `cdi.kubevirt.io/storage.bind.immediate.requested: "true"`
  annotation, since `cbt-demo-hpp` is `WaitForFirstConsumer`). Confirmed
  fixed: the installer VM now reliably boots from the CD-ROM into Windows
  Setup (`Microsoft Server Operating System Setup` GUI reached repeatedly
  across multiple resets). This also reverted an intermediate, now-obsolete
  workaround of moving CD-ROMs to `scsi` bus — that masked the same
  Block-mode bug for firmware boot but would have broken WinPE's ability to
  read the virtio-driver/sysprep CDs later (stock Windows Server 2022 WinPE
  has no inbox virtio-scsi driver, only inbox AHCI/SATA), so everything was
  moved back to `sata` to match the reference architecture ("SATA bus for
  all disks (Windows compatibility)").
- Along the way, validated (and then cleaned up) a temporary debug pod
  (`iso-check`) that block-device-mounted the ISO PVC directly to compare
  full-file SHA-256 against the source ISO — confirms the upload path itself
  is trustworthy; the bug was in CD-ROM device presentation, not the data.

## Remaining

1. Verify `make vm-cbt-verify` finishes CBT/checkpoint assertions, restore
   reconstruction, and all guest-file hash checks.

## How to resume

- The remote `make vm-cbt-verify` command is running; do not launch a duplicate.
- All console captures are saved under the ignored local `screenshot/` directory.
- The golden image remains cached in `vm-cbt-images`; `make clean-all` only removes run-labeled resources from the workflow namespace.
