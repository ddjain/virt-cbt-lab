# KubeVirt CBT VM backup demo

This repository demonstrates Changed Block Tracking (CBT) for KubeVirt virtual-machine backups. It creates a Fedora VM with one 32 GiB persistent root disk and one cloud-init disk, changes `/home/cbt-demo/hello.txt`, takes a full backup, changes the file again, takes an incremental backup, and restores the post-incremental root image into a second VM.

The workflow is a demonstration, not a production backup policy. It uses fixed resource names and a local/RWO storage class.

## Architecture and workflow

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify -> vm-cbt-restore
```
- `common.sh` centralizes workflow names, environment handling, prerequisite checks, guest-key creation, reusable port-forward cleanup, and backup queries.
- `scripts/dotenv.sh` safely reads supported `.env` values without executing the file; both `preflight` and `sync.sh` use it.
- `vm-setup.sh` creates the namespace, one root DataVolume, VM, and SSH service; it writes the workload file at `/home/cbt-demo/hello.txt` and checks that CBT is enabled.
- `vm-backup.sh` creates the 40 GiB full-backup PVC, tracker, and full backup, then waits for completion.
- `vm-cbt-backup.sh` waits for the tracker checkpoint, changes `/home/cbt-demo/hello.txt`, creates the 2 GiB incremental backup, and checks its type.
- `vm-cbt-verify.sh` checks CBT, completion conditions, distinct checkpoints, and the tracker's latest checkpoint.
- `vm-cbt-restore.sh` validates the chain, rebases and flattens the push-mode QCOW2 artifacts in-cluster, boots `vm-cbt-restored`, and verifies the restored file.
- `clean-all.sh` removes the demo namespace and only the guest key marked as workflow-managed.

The VM manifest supplies the `cbt-demo=enabled` label used by this demo. The cluster's selector representation varies by KubeVirt version, so preflight does not gate on that literal configuration; setup and verification require the resulting VM CBT state to be `Enabled`.

## Prerequisites

Local tools:
- Bash 3.2 or newer, Make, `oc`, `ssh`, `ssh-keygen`, and `rsync` for `sync.sh`.
- A readable kubeconfig and permission to create/delete the demo resources.

Cluster resources:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` APIs.
- The `IncrementalBackup` feature gate.
- A `cbt-demo-hpp` storage class that can provision the 32 GiB RWO VM root disk, 40 GiB full-backup volume, 2 GiB incremental-backup volume, and 40 GiB restored-root PVC.
- The CDI `fedora` `DataSource` in `openshift-virtualization-os-images`.

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


## Preflight

Run the read-only readiness check directly, or let `make e2e` run it automatically before any workflow step:

```sh
./preflight
```

`make e2e` stops before creating resources when preflight reports a failure. Use `make preflight` to invoke the same check explicitly.


`preflight` checks repository files and executable bits, the required local tools (`bash`, `make`, `oc`, `ssh`, `ssh-keygen`, and standard shell utilities), `.env`/kubeconfig configuration, OpenShift authentication and API reachability, KubeVirt CBT backup CRDs, the Fedora DataSource, `cbt-demo-hpp`, the `IncrementalBackup` gate, required create/delete permissions, the guest SSH key when present, and temporary-directory access. A missing guest key is a warning because `vm-setup.sh` generates it. The literal CBT selector is not a preflight gate because KubeVirt versions expose that configuration differently; setup and verification validate actual CBT state. `rsync` is reported as a warning because it is needed only by optional `sync.sh`. It does not install tools or change cluster resources.

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
make vm-cbt-restore
```

The workflow uses one 32 GiB persistent root disk, one cloud-init disk, a 40 GiB full output PVC, a 2 GiB incremental output PVC, and a 40 GiB restored-root PVC. The workload file is `/home/cbt-demo/hello.txt`; setup writes `Hello from the VM CBT demo.`, and mutation appends `This line was added after the full backup.`.

The push artifacts are expected at `<backup-pvc>/vm-cbt-demo/<backup-name>-<timestamp>/<backup-name>-rootdisk.qcow2`. Restore copies the incremental artifact, validates both QCOW2 files, rebases the copy to the full artifact, flattens it to `/restore/disk.img`, and boots `vm-cbt-restored` from `vm-cbt-restored-root`. It then asserts that the restored file contains exactly those two lines and prints its SHA-256.

The scripts write concise structured progress messages to stderr. Each workflow uses numbered steps with `→` action lines and `✓` success lines. `make vm-cbt-demo` and `make e2e` include restore verification.

The fixed names allow one run per namespace. Start over with:

```sh
make clean-all
```

Cleanup deletes source, backup, restore, and restored-VM resources in `vm-cbt-demo` and waits for their dynamically provisioned PVs to be reclaimed. This is an in-cluster recovery demonstration, not an offsite backup product.

## Synchronization helper

`sync.sh` copies the repository to a configured remote host. It reads `REMOTE_HOST` and `REMOTE_DIR` from the current environment first, then from the local `.env` without executing that file. It requires `ssh` and `rsync` locally. It excludes `.git`, `.env`, dotenv variants, and log files:

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
Validation artifacts are stored locally under `validation/`. The directory is
git-ignored and is intended for dated validation summaries, command logs, and
machine-readable JSON reports produced by cluster runs. Do not store
kubeconfigs, credentials, private keys, or unredacted sensitive command output
there.

## Troubleshooting

- **Kubeconfig is not readable:** set `KUBECONFIG_PATH` to a readable file or unset it and configure `KUBECONFIG`/the standard `oc` context.
- **Fedora `DataSource` not found:** verify CDI's `fedora` source in `openshift-virtualization-os-images`.
- **CBT is not enabled:** verify the `IncrementalBackup` feature gate, the VM's `cbt-demo=enabled` label, and the cluster's CBT selector configuration for the installed KubeVirt version.
- **PVC remains pending:** verify that `cbt-demo-hpp` exists and can provision local demo volumes.
- **Guest SSH retries or times out:** inspect VM readiness, the service, and the port-forward messages. Ensure the generated private key is readable only by its owner.
- **An incremental backup already exists:** run `make clean-all` before repeating the fixed-name workflow.
- **Incremental type is wrong:** wait for the full checkpoint to appear in `hello-tracker` and inspect backup conditions and tracker status.

## Repository structure

```text
.
├── .env.example          # Sanitized local configuration template
├── .gitignore            # Secret and generated-artifact exclusions
├── AGENTS.md             # Repository-specific contributor/agent guidance
├── docs/                 # Detailed workflow documentation
├── manifests/            # VM, backup, restore, and recovered-VM resources
├── scripts/              # Workflow implementation and shared helpers
│   └── dotenv.sh         # Safe parser for supported .env values
└── sync.sh               # Optional remote synchronization helper
```

## Known limitations

- Resource names and namespace are fixed; concurrent runs require separate copies with deliberate manifest/script changes.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- The demo uses local/RWO storage and is an in-cluster recovery demonstration, not an offsite backup product.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
