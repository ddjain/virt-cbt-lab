# KubeVirt CBT VM backup demo

This repository demonstrates Changed Block Tracking (CBT) for KubeVirt virtual-machine backups. The default workflow creates a Debian VM, changes a guest file, takes full and incremental backups, then verifies the API state and restored data. A Windows Server 2022 profile uses QEMU Guest Agent and a cached sysprepped image; `make windows-vm-setup` provisions one Windows VM and creates the backup test file before the Windows E2E profile is run.

The workflow is a demonstration, not a production backup policy. Each run uses run-derived resource names in a shared namespace and local/RWO storage.

## Architecture and workflow

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```
For the component, network, storage, checkpoint, source-code, sequence-diagram, and failure-boundary reference, start with [`docs/cbt/README.md`](docs/cbt/README.md). The stable architecture hub is [`docs/cbt-architecture.md`](docs/cbt-architecture.md).
- `common.sh` centralizes workflow names, environment handling, prerequisite checks, guest-key creation, port-forward cleanup, and backup queries.
- `scripts/dotenv.sh` safely reads supported `.env` values without executing the file; both `preflight` and `sync.sh` use it.
- `vm-setup.sh` imports the cached Debian image and creates a Debian VM with SSH; `windows-vm-setup.sh` reuses the Windows golden DataSource, attaches a run-scoped OOBE Secret, and initializes `C:\cbt-data\hello.txt` through QEMU Guest Agent.
- `vm-backup.sh` creates the backup PVC, tracker, and full backup, then waits for completion.
- `vm-cbt-backup.sh` waits for the tracker checkpoint, changes `hello.txt`, creates the incremental backup, and checks its type.
- `vm-cbt-verify.sh` checks CBT, completion conditions, distinct checkpoints, and the tracker's latest checkpoint, then runs `vm-cbt-restore-test.sh`, then merges every stage's fragment into the run's `report.json`.
- `vm-cbt-restore-test.sh` reconstructs the guest disk from the full and incremental backup PVCs and verifies its actual data — see [`docs/restore-verification.md`](docs/restore-verification.md) for the full command-by-command reference and how to independently cross-check it.
- `clean-all.sh` removes workflow-managed resources, including per-run Windows OOBE Secrets, from the shared namespace and only the guest key marked as workflow-managed.

Each run also writes a structured JSON report to `report/run_<UTC timestamp>/` — see [Run report](#run-report) below.

The VM manifest supplies the `cbt-demo=enabled` label used by this demo. The cluster's selector representation varies by KubeVirt version, so preflight does not gate on that literal configuration; setup and verification require the resulting VM CBT state to be `Enabled`.

## Prerequisites

Local tools:
- Bash 3.2 or newer for the core workflow; `make monitor` requires Bash 4+ because it uses associative arrays. Also require Make, `oc`, and `jq`; Debian setup additionally requires `ssh` and `ssh-keygen`. Windows setup requires `python3`, and first-time golden-image creation also requires `curl`.
- A readable kubeconfig and permission to create/delete the demo resources.

Cluster resources:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` APIs.
- The `IncrementalBackup` feature gate.
- Debian requires `cbt-demo-hpp` or the selected ODF StorageClass for the RWO VM and backup PVCs. The root disk and full-backup PVC must exceed the cached Debian image size.
- Windows requires `cbt-demo-hpp` for ISO staging, `ocs-storagecluster-ceph-rbd-virtualization` for the 40Gi Block-mode VM disk, and `ocs-storagecluster-ceph-rbd` for filesystem backup PVCs. These ODF classes are used by the Windows manifests.

The CBT backup API is preview/alpha. Confirm compatibility with the OpenShift Virtualization version before use.

## Setup and configuration

1. Copy the sanitized template:

   ```sh
   cp .env.example .env
   ```

2. Edit `.env` with your local kubeconfig and generated-key paths. Do not put credentials, private keys, or tokens in `.env.example` or any tracked file. `.env` is ignored.
3. Load it for direct script execution:

   ```sh
   set -a
   . ./.env
   set +a
   ```

   `make` also includes `.env` automatically and exports the supported variables to workflow scripts.

Supported variables:

| Variable | Required | Meaning |
|---|---:|---|
| `KUBECONFIG_PATH` | No | Kubeconfig path; otherwise `KUBECONFIG` or the `oc` default is used. |
| `GUEST_KEY` | No | Private key path. Default: repository-local `keys/id_ed25519` (gitignored). |
| `REMOTE_HOST` | For `sync.sh` | SSH host or alias used for synchronization. |
| `REMOTE_DIR` | For `sync.sh` | Destination directory on that host. |
| `VM_OS` | No | Guest profile for `make e2e`: `debian` (default) or `windows`. |
| `RESTORE_HELPER_IMAGE` | For `vm-cbt-restore-test` | Image providing `qemu-img`, `util-linux`, and `ntfs-3g`, built from `images/restore-helper/Dockerfile` and pushed to a registry you control. |
| `GUEST_DATA_SIZE_MB` | No | Size (MiB) of the random payload written to the guest test file at setup. Default: `64`. |
| `GUEST_INCREMENTAL_DATA_SIZE_MB` | No | Size (MiB) of the random payload appended before the incremental backup. Default: `32`. |
| `MANIFEST_VARIANT` | No | Debian manifest set: `odf`, `default`, `large`, or `large-odf`; Windows uses fixed ODF storage sizing. Default: `odf`. |
| `WINDOWS_ISO_PATH` | If the ISO is not already staged | Local Windows Server 2022 Evaluation ISO path used only when `vm-cbt-images/windows-iso` is not `Succeeded`; never copied into the repository. |
| `WINDOWS_ADMIN_PASSWORD_FILE` | For Windows setup | Local, gitignored file containing the Administrator password; never committed or logged. |

### ODF-backed variant (default)

`make e2e` defaults to `MANIFEST_VARIANT=odf`, running against `manifests/vm-odf.yaml`, `manifests/full-backup-odf.yaml`, and `manifests/incremental-backup-odf.yaml` — same shape as the plain demo manifests, but the root disk and both backup PVCs use the `ocs-storagecluster-ceph-rbd` StorageClass instead of `cbt-demo-hpp`, sized 6Gi/6Gi/4Gi instead of 5Gi/5Gi/3Gi. The larger sizing is required, not cosmetic: CDI's clone-time filesystem-overhead reservation inflates the actual root disk past 5Gi, and Ceph RBD enforces PVC capacity strictly, so a flat 5Gi backup-target PVC fails the full backup with `No space left on device` (HPP doesn't enforce capacity as strictly, so the same undersizing is latent there instead of failing). This requires ODF/Ceph already deployed on the cluster (see `docs/odf-setup-plan.md`); `./preflight` checks for `ocs-storagecluster-ceph-rbd` instead of `cbt-demo-hpp` for this variant. The golden Debian image cache (`manifests/debian-image.yaml`) still lives on `cbt-demo-hpp` regardless of variant, and CDI clones from it into whichever StorageClass the variant selects. The single-node HPP pool is left untouched either way.

### `default` variant (clusters without ODF)

Set `MANIFEST_VARIANT=default` to run against the plain `manifests/vm.yaml`, `manifests/full-backup.yaml`, and `manifests/incremental-backup.yaml` on `cbt-demo-hpp` (5Gi/5Gi/3Gi PVCs), for clusters that don't have ODF deployed.

## Windows VM setup

`make windows-vm-setup` is the single-VM setup step before running a Windows backup workflow. It runs the Windows preflight, builds the cached Windows Server 2022 golden image if missing, clones a run-scoped VM from `vm-cbt-images/windows-server-2022`, applies a run-scoped OOBE Secret, and waits for CBT and QEMU Guest Agent readiness. The reusable image contains Python 3.12.4 plus file-writer, SQLite-writer, and HTTP-server workloads, started by the `StartWorkloads` SYSTEM startup task. Image creation verifies the workloads, then removes generated log/database data before sysprep. Each runtime clone verifies the startup task, file/SQLite writes, HTTP on port 8080, and three Python processes before initializing `C:\cbt-data\hello.txt`.
The Windows VM template disables eviction-driven migration for the demo because a migration can interrupt the QEMU Guest Agent while a guest command is running. Runtime startup verification probes the agent socket and retries once if the guest agent drops during the initial Windows boot window.

`WINDOWS_ADMIN_PASSWORD_FILE` must name a readable, local, gitignored password file for the initial image build and every runtime clone; the file must contain exactly one non-empty UTF-8 password line, with no variable-name prefix, quotes, username, or additional lines. Each clone uses it to create a run-scoped OOBE Secret. Set `WINDOWS_ISO_PATH` only if DataVolume `vm-cbt-images/windows-iso` is not already `Succeeded`; the builder reuses a completed ISO upload. `make windows-vm-setup` builds the golden-image cache automatically when needed; `make windows-golden-image` runs that one-time step by itself. The ISO is staged on `cbt-demo-hpp` as a Filesystem PVC because KubeVirt's CD-ROM needs a file-backed volume; the Windows VM disk uses the ODF virtualization Block class. See [`docs/windows-server-2022-setup-runbook.md`](docs/windows-server-2022-setup-runbook.md) for the chronological procedure.
The installer guest also needs outbound HTTPS access to `www.python.org` to install Python 3.12.4.

### Large-disk variant (chaos testing)

Set `MANIFEST_VARIANT=large` to run against `manifests/vm-large.yaml` (40Gi root disk), `manifests/full-backup-large.yaml` (40Gi PVC), and `manifests/incremental-backup-large.yaml` (25Gi PVC) on `cbt-demo-hpp` instead of the default demo manifests; it exists to give chaos scenarios (see `cbt-chaos/chaos-plan.md`) a longer, disk-bound backup-copy window than the small demo sizing produces on fast local storage. Set `MANIFEST_VARIANT=large-odf` for the same sizing intent on ODF/Ceph instead — `manifests/vm-large-odf.yaml` (48Gi root disk), `manifests/full-backup-large-odf.yaml` (48Gi PVC), and `manifests/incremental-backup-large-odf.yaml` (30Gi PVC), scaled up with the same capacity margin as the `odf` variant.

Also set `GUEST_DATA_SIZE_MB=8192` and `GUEST_INCREMENTAL_DATA_SIZE_MB=12288` — measured on cbt-demo-hpp, this combination produced a ~28s full backup and a ~16s incremental backup (both `Done` conditions timed via `scripts/monitor.sh`). At the default 64/32 MiB payloads, the large manifests still finish in a few seconds, since the copy is fully page-cache-absorbed at that scale; the backing node needs several hundred GB of real disk I/O before it stops being cache-absorbed, so pushing the payload size is what actually produces the delay, not the PVC size alone.


## Preflight

Run the read-only readiness check directly, or let `make e2e` run it automatically before any workflow step:

```sh
./preflight
```

`make e2e` stops before creating resources when preflight reports a failure. Use `make preflight` to invoke the same check explicitly.


`preflight` selects prerequisites from `VM_OS`. Debian checks SSH tools and the guest key; Windows checks Python, the admin-password file, required ODF storage classes, and the local ISO path/upload route when the golden DataSource is missing. Both profiles check kubeconfig, cluster reachability, CBT/CDI APIs, feature gates, permissions, and repository files. It never installs tools or changes cluster resources.

Each result is marked `PASS`, `WARN`, or `FAIL`. Warnings do not fail the check; any failure produces exit code `1` and `NOT READY`. Exit code `0` produces `READY`. Use `./preflight --verbose` for the same safe summary with an explicit note that command diagnostics are suppressed to avoid leaking credentials or kubeconfig data. Example:

```text
== Cluster Access ==
PASS  an OpenShift context is selected
PASS  oc authentication succeeded
PASS  cluster API is reachable

Summary: 58 checks; 58 passed; 0 warnings; 0 failures
READY: environment is prepared for the repository workflow.
```

The script reads supported values from `.env` when corresponding environment variables are unset; it does not execute `.env`. `KUBECONFIG_PATH` and `GUEST_KEY` use the same defaults as the workflow scripts. A preflight pass confirms prerequisites and access, not that a later backup operation will succeed.

## Run the demo


Run the complete default Debian workflow:

```sh
make e2e
```

For Windows, first validate one VM and its backup test file:

```sh
make windows-vm-setup
```

Then run the Windows CBT E2E profile:

```sh
make e2e VM_OS=windows NAME=windows-cbt-1
```

`windows-vm-setup` builds the cached Windows image automatically when it is missing (requires `WINDOWS_ISO_PATH` and `WINDOWS_ADMIN_PASSWORD_FILE`). The Windows E2E target reuses the generic backup/tracker workflow and verifies restored NTFS file bytes.

Use a fixed, deterministic run name for Debian instead of the default random one:

```sh
make e2e NAME=foo
```

Run Debian individual stages:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
```

To track when the full and incremental backups actually start/finish (and their duration) while `make e2e NAME=foo` is running, run this in another terminal for the same run:

```sh
make monitor VM=vm-foo
```

It only reads `vmbackup` status (no cluster changes), prints the API-recorded creation-to-`Done` duration and terminal reason, and exits non-zero if either backup has a terminal failure reason.

The scripts write concise structured progress messages to stderr. Each workflow uses numbered steps with `→` action lines and `✓` success lines; failures identify the active step while preserving the underlying command diagnostics. `make vm-cbt-demo` and `make e2e` add stage-level headers without printing every shell command. Guest `sha256sum` output and backup checkpoint summaries remain visible in the normal command output.

Each `make e2e` run generates a unique run ID (`<adjective>-<noun>-<hex tag>`, e.g. `dark-forest-80d7`) and names every resource it creates from it, so repeat runs coexist in the same `NAMESPACE` without collisions; no cleanup is required between runs. To remove all runs' resources from the namespace:

```sh
make clean-all
```

Cleanup deletes only resources labeled `app.kubernetes.io/managed-by=virt-cbt-lab` (every run this workflow created) and waits for their dynamically provisioned PVs to be reclaimed; it does not delete the namespace itself or any unrelated resources in it. It does not uninstall KubeVirt or delete the shared storage class. See `docs/vm-cbt-workflow.md` for the full resource-naming scheme.

## Synchronization helper

`sync.sh` copies the repository and its `.git` metadata to a configured remote host. It reads `REMOTE_HOST` and `REMOTE_DIR` from the current environment first, then from the local `.env` without executing that file. It requires `ssh` and `rsync` locally. It excludes `.env`, dotenv variants, and log files, but includes `.git` so the destination remains a Git working copy:

```sh
REMOTE_HOST=example-host REMOTE_DIR=/path/to/cbt-setup ./sync.sh
```

If you run the workflow on the remote host (e.g. because that's where cluster access is configured), pull its generated reports back with `./sync.sh --pull-reports`, which copies `REMOTE_DIR/report/` into the local `report/` directory and never modifies the remote.

Use a host alias and destination appropriate for your environment. The helper does not transfer credentials.

## Validation and testing

Run shell syntax checks for every shell script:

```sh
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Check the Make targets without contacting a cluster:

```sh
make help
```

For an environment with the prerequisites and cluster resources, run `make e2e`, then `make clean-all`. No offline simulation can prove Kubernetes backup status; the E2E workflow is the functional validation.

## Troubleshooting

- **Kubeconfig is not readable:** set `KUBECONFIG_PATH` to a readable file or unset it and configure `KUBECONFIG`/the standard `oc` context.
- **Debian golden image import stuck or failing:** check `oc get dv debian-golden -n vm-cbt-images` and its importer pod logs; confirm cluster CDI importers can reach `cloud.debian.org`. Force a re-import with `oc delete namespace vm-cbt-images`.
- **CBT is not enabled:** verify the `IncrementalBackup` feature gate, the VM's `cbt-demo=enabled` label, and the cluster's CBT selector configuration for the installed KubeVirt version.
- **PVC remains pending:** verify that `cbt-demo-hpp` exists and can provision local demo volumes.
- **Guest SSH retries or times out:** inspect VM readiness, the service, and the port-forward messages. Ensure the generated private key is readable only by its owner.
- **An incremental backup already exists:** run `make clean-all` before repeating the fixed-name workflow.
- **Incremental type is wrong:** wait for the full checkpoint to appear in the run's `VirtualMachineBackupTracker` (`vm-tracker-<run-id>`) and inspect backup conditions and tracker status.

## Repository structure

```text
.
├── .env.example          # Sanitized local configuration template
├── .gitignore            # Secret and generated-artifact exclusions
├── AGENTS.md             # Repository-specific contributor/agent guidance
├── docs/                 # Detailed workflow and restore-verification documentation
├── images/
│   └── restore-helper/   # Dockerfile for the restore-verification pod image
├── manifests/            # Debian golden image, VM, full-backup, incremental-backup, and restore-verify pod resources
├── scripts/              # Workflow implementation and shared helpers
│   ├── dotenv.sh         # Safe parser for supported .env values
│   └── restore-lib.sh    # Restore-verification pod orchestration
├── state/                # Guest hashes recorded at backup time (gitignored, created at runtime)
├── report/               # Per-run JSON reports and run-owned pod logs (gitignored, created at runtime, survives clean-all)
└── sync.sh               # Optional remote synchronization helper
```

## Run report

Each VM setup generates a `REPORT_ID` (`run_<UTC timestamp>`; a `<run-id>` suffix is added only if another report starts in the same second) and later stages append JSON fragments under `report/<REPORT_ID>/fragments/`. `vm-cbt-verify.sh` merges them into `report/<REPORT_ID>/report.json` and collects logs from the run's own VM and restore pod.

`report.json` contains, per run:
- `os_profile`: `debian` or `windows`.
- `guest.full_backup` / `guest.incremental_backup`: guest file path, size, SHA-256, and capture time for both backup points.
- `backups.full` / `backups.incremental`: backup name, type, checkpoint name, backup PVC name/requested size/actual capacity, and (when available) the VM's recorded backup start/end timestamps and completion status.
- `tracker`: the `VirtualMachineBackupTracker` name and latest checkpoint.
- `verification.checks`: CBT/checkpoint/PVC checks plus full-only and full+incremental restore hash and marker checks.
- `logs`: relative paths to the collected `virt-launcher` and restore-pod logs.

Unlike `state/`, `report/` is not deleted by `make clean-all` — it is meant to remain as a debugging record across runs. Inspect it with `jq . report/run_*/report.json` or diff two runs' `report.json` files to compare outcomes. Log collection is best-effort and only covers pods the run itself creates (the VM's `virt-launcher` pod and the short-lived restore-verify pod); it does not collect cluster component logs (KubeVirt/CDI operators, node agents, etc.).

## Known limitations

- Resource names are derived from a per-run ID, but all runs share the configured namespace and local/RWO storage; `make clean-all` removes every workflow-managed run in that namespace. One checkout's `state/` and report/hash files are shared, so serialize workflows per checkout or use separate repository copies for concurrent runs.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- Debian uses small local/RWO disks and Windows uses a 40Gi Block-mode root plus 48Gi/30Gi ODF Filesystem backup PVCs. Both are demo configurations, not production storage or disaster-recovery guidance.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `make vm-cbt-restore-test` uses a privileged pod to reconstruct backups and read guest files from ext4 (Debian) or NTFS (Windows). Build and push `images/restore-helper/Dockerfile` with `qemu-img`, `util-linux`, and `ntfs-3g`, set `RESTORE_HELPER_IMAGE`, and allow the privileged pod.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
