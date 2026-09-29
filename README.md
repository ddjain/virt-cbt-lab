# KubeVirt CBT VM backup demo

This repository demonstrates Changed Block Tracking (CBT) for KubeVirt virtual-machine backups. It creates a Debian VM, changes a guest file, takes a full backup, changes the file again, takes an incremental backup, and verifies the API state.

The workflow is a demonstration, not a production backup policy. It uses fixed resource names and a local/RWO storage class.

## Architecture and workflow

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```
- `common.sh` centralizes workflow names, environment handling, prerequisite checks, guest-key creation, port-forward cleanup, and backup queries.
- `scripts/dotenv.sh` safely reads supported `.env` values without executing the file; both `preflight` and `sync.sh` use it.
- `vm-setup.sh` imports the cached Debian golden image (once), then creates the namespace, VM, DataVolume, and SSH service; it writes `hello.txt` and checks that CBT is enabled.
- `vm-backup.sh` creates the backup PVC, tracker, and full backup, then waits for completion.
- `vm-cbt-backup.sh` waits for the tracker checkpoint, changes `hello.txt`, creates the incremental backup, and checks its type.
- `vm-cbt-verify.sh` checks CBT, completion conditions, distinct checkpoints, and the tracker's latest checkpoint, then runs `vm-cbt-restore-test.sh`, then merges every stage's fragment into the run's `report.json`.
- `vm-cbt-restore-test.sh` reconstructs the guest disk from the full and incremental backup PVCs and verifies its actual data — see [`docs/restore-verification.md`](docs/restore-verification.md) for the full command-by-command reference and how to independently cross-check it.
- `clean-all.sh` removes the demo namespace and only the guest key marked as workflow-managed.

Each run also writes a structured JSON report to `report/run_<UTC timestamp>/` — see [Run report](#run-report) below.

The VM manifest supplies the `cbt-demo=enabled` label used by this demo. The cluster's selector representation varies by KubeVirt version, so preflight does not gate on that literal configuration; setup and verification require the resulting VM CBT state to be `Enabled`.

## Prerequisites

Local tools:
- Bash 3.2 or newer, Make, `oc`, `ssh`, `ssh-keygen`, `jq` (builds and merges the per-run JSON report), and `rsync` for `sync.sh`.
- A readable kubeconfig and permission to create/delete the demo resources.

Cluster resources:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` APIs.
- The `IncrementalBackup` feature gate.
- A `cbt-demo-hpp` storage class that can provision the demo's RWO volumes: a 5 GiB root disk, a 5 GiB full-backup PVC, and a 3 GiB incremental-backup PVC (13 GiB total per run, plus a one-time 3 GiB cached image). The root disk and full-backup PVC must stay larger than the Debian golden image's size, since CDI rejects a clone target smaller than the source.
- Outbound HTTPS access from the cluster's CDI importer to `cloud.debian.org`, used once to populate the `vm-cbt-images` namespace's `debian` golden `DataSource` (see [`manifests/debian-image.yaml`](manifests/debian-image.yaml)); `vm-setup.sh` creates and waits for it automatically, and later runs reuse it without re-downloading.

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
| `RESTORE_HELPER_IMAGE` | For `vm-cbt-restore-test` | Image providing `qemu-img` and `util-linux`, built from `images/restore-helper/Dockerfile` and pushed to a registry you control. |
| `GUEST_DATA_SIZE_MB` | No | Size (MiB) of the random payload written to `hello.txt` at setup. Default: `64`. |
| `GUEST_INCREMENTAL_DATA_SIZE_MB` | No | Size (MiB) of the random payload appended to `hello.txt` before the incremental backup. Default: `32`. |


## Preflight

Run the read-only readiness check directly, or let `make e2e` run it automatically before any workflow step:

```sh
./preflight
```

`make e2e` stops before creating resources when preflight reports a failure. Use `make preflight` to invoke the same check explicitly.


`preflight` checks repository files and executable bits, the required local tools (`bash`, `make`, `oc`, `ssh`, `ssh-keygen`, `jq`, and standard shell utilities), `.env`/kubeconfig configuration, OpenShift authentication and API reachability, KubeVirt CBT backup and CDI CRDs, `cbt-demo-hpp`, the `IncrementalBackup` gate, required create/delete permissions, the guest SSH key when present, and temporary-directory access. It does not pre-check the Debian golden image itself, since `vm-setup.sh` creates and imports it on demand. A missing guest key is a warning because `vm-setup.sh` generates it. The literal CBT selector is not a preflight gate because KubeVirt versions expose that configuration differently; setup and verification validate actual CBT state. `rsync` is reported as a warning because it is needed only by optional `sync.sh`. It does not install tools or change cluster resources.

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


Run the complete workflow:

```sh
make e2e
```

Run individual stages:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
```

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
├── report/               # Per-run JSON reports and restore logs (gitignored, created at runtime, survives clean-all)
└── sync.sh               # Optional remote synchronization helper
```

## Run report

Each `vm-setup.sh` run generates a `REPORT_ID` (`run_<UTC timestamp>`, independent of the resource-naming `RUN_ID`) and every later stage in the same run appends a JSON fragment under `report/<REPORT_ID>/fragments/`. `vm-cbt-verify.sh` merges all fragments into `report/<REPORT_ID>/report.json` once the restore test finishes, alongside the restore-verify pod's raw log at `report/<REPORT_ID>/restore-test.log`.

`report.json` contains, per run:
- `guest.full_backup` / `guest.incremental_backup`: the guest file's path, size in bytes, SHA-256, and capture time, for both backups.
- `backups.full` / `backups.incremental`: backup name, type, checkpoint name, backup PVC name/requested size/actual capacity, and (when available) the VM's recorded backup start/end timestamps and completion status.
- `tracker`: the `VirtualMachineBackupTracker` name and latest checkpoint.
- `verification.checks`: every individual check from `vm-cbt-verify.sh` and `vm-cbt-restore-test.sh` (CBT state, checkpoint distinctness, PVC binding, restore hash/marker matches) with a `passed` boolean each, plus `overall_passed` and `restore_log_path`.

Unlike `state/`, `report/` is not deleted by `make clean-all` — it is meant to remain as a debugging record across runs. Inspect it with `jq . report/run_*/report.json` or diff two runs' `report.json` files to compare outcomes.

## Known limitations

- Resource names and namespace are fixed; concurrent runs require separate copies with deliberate manifest/script changes.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- The demo uses local/RWO disks (5 GiB root, 5 GiB full-backup PVC, 3 GiB incremental-backup PVC) and is not production storage or disaster-recovery guidance. The root/full-backup sizes must track the Debian golden image's size, cached once in `vm-cbt-images` and outside `clean-all`'s scope.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `make vm-cbt-restore-test` runs a privileged pod to reconstruct the guest disk (`qemu-img`) and read its files by loop-mounting the demo's ext4 root filesystem directly. Build `images/restore-helper/Dockerfile`, push it, and set `RESTORE_HELPER_IMAGE`; the cluster must permit pulling that image and running the privileged pod.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
