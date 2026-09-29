# KubeVirt CBT VM backup demo

This repository demonstrates Changed Block Tracking (CBT) for KubeVirt virtual-machine backups. It creates a Fedora VM, changes a guest file, takes a full backup, changes the file again, takes an incremental backup, and verifies the API state.

The workflow is a demonstration, not a production backup policy. It uses fixed resource names and a local/RWO storage class.

## Architecture and workflow

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```
- `common.sh` centralizes names, environment handling, prerequisite checks, guest-key creation, and port-forward cleanup.
- `vm-setup.sh` creates the namespace, VM, DataVolume, and SSH service; it writes `hello.txt` and checks that CBT is enabled.
- `vm-backup.sh` creates the backup PVC, tracker, and full backup, then waits for completion.
- `vm-cbt-backup.sh` waits for the tracker checkpoint, changes `hello.txt`, creates the incremental backup, and checks its type.
- `vm-cbt-verify.sh` checks CBT, completion conditions, distinct checkpoints, and the tracker's latest checkpoint.
- `clean-all.sh` removes the demo namespace and only the guest key marked as workflow-managed.

The VM manifest selects the Fedora `DataSource`, the `cbt-demo-hpp` storage class, and the `cbt-demo=enabled` label. The target cluster must be configured to select that label for CBT.

## Prerequisites

Local tools:
- Bash 3.2 or newer, Make, `oc`, `ssh`, `ssh-keygen`, and `rsync` for `sync.sh`.
- A readable kubeconfig and permission to create/delete the demo resources.

Cluster resources:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` APIs.
- The `IncrementalBackup` feature gate and a CBT selector matching `cbt-demo=enabled`.
- A `cbt-demo-hpp` storage class that can provision the 30 GiB RWO demo volumes.
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
| `GUEST_KEY` | No | Private key path. Default: `$HOME/.local/share/vm-cbt-demo/id_ed25519`. |
| `REMOTE_HOST` | For `sync.sh` | SSH host or alias used for synchronization. |
| `REMOTE_DIR` | For `sync.sh` | Destination directory on that host. |

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

The scripts write progress messages to stderr. Setup and incremental stages print guest `sha256sum` output. Successful verification prints `CBT verification passed` and the two checkpoint names.

The fixed names allow one run per namespace. Start over with:

```sh
make clean-all
```

Cleanup deletes only `vm-cbt-demo` resources and waits for its dynamically provisioned PVs to be reclaimed. It does not uninstall KubeVirt or delete the shared storage class.

## Synchronization helper

`sync.sh` copies the repository to a configured remote host. It requires both `REMOTE_HOST` and `REMOTE_DIR`, and requires `ssh` and `rsync` locally. It excludes `.git`, `.env`, dotenv variants, and log files:

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
- **Fedora `DataSource` not found:** verify CDI's `fedora` source in `openshift-virtualization-os-images`.
- **CBT is not enabled:** verify the `IncrementalBackup` feature gate and the selector for `cbt-demo=enabled`.
- **PVC remains pending:** verify that `cbt-demo-hpp` exists and can provision local demo volumes.
- **Guest SSH retries or times out:** inspect VM readiness, the service, and the port-forward messages. Ensure the generated private key is readable only by its owner.
- **An incremental backup already exists:** run `make clean-all` before repeating the fixed-name workflow.
- **Incremental type is wrong:** wait for the full checkpoint to appear in `hello-tracker` and inspect backup conditions and tracker status.

## Repository structure

```text
.
├── .env.example          # Sanitized local configuration template
├── .gitignore            # Secret and generated-artifact exclusions
├── Makefile              # Workflow entry points
├── AGENTS.md             # Repository-specific contributor/agent guidance
├── docs/                 # Detailed workflow documentation
├── manifests/            # VM, full-backup, and incremental-backup resources
├── scripts/              # Workflow implementation and shared helpers
└── sync.sh               # Optional remote synchronization helper
```

## Known limitations

- Resource names and namespace are fixed; concurrent runs require separate copies with deliberate manifest/script changes.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- The demo uses a 30 GiB local/RWO disk and is not production storage or disaster-recovery guidance.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
