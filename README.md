# KubeVirt CBT VM backup demo

This repository demonstrates Changed Block Tracking (CBT) for KubeVirt virtual-machine backups. It creates a Fedora VM, changes a guest file, takes a full backup, changes the file again, takes an incremental backup, and verifies the API state.

The workflow is a demonstration, not a production backup policy. It uses fixed resource names and a local/RWO storage class.

## Architecture and workflow

```text
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```
- `common.sh` centralizes workflow names, environment handling, prerequisite checks, guest-key creation, port-forward cleanup, and backup queries.
- `scripts/dotenv.sh` safely reads supported `.env` values without executing the file; both `preflight` and `sync.sh` use it.
- `vm-setup.sh` creates the namespace, VM, DataVolume, and SSH service; it writes `hello.txt` and checks that CBT is enabled.
- `vm-backup.sh` creates the backup PVC, tracker, and full backup, then waits for completion.
- `vm-cbt-backup.sh` waits for the tracker checkpoint, changes `hello.txt`, creates the incremental backup, and checks its type.
- `vm-cbt-verify.sh` checks CBT, completion conditions, distinct checkpoints, and the tracker's latest checkpoint.
- `clean-all.sh` removes the demo namespace and only the guest key marked as workflow-managed.

The VM manifest supplies the `cbt-demo=enabled` label used by this demo. The cluster's selector representation varies by KubeVirt version, so preflight does not gate on that literal configuration; setup and verification require the resulting VM CBT state to be `Enabled`.

## AI-assisted diagnosis

The repository includes a bounded, read-only context workflow for AI calls and human triage. It avoids loading every metric or log before the failing workflow invariant is known:

```text
map -> index -> select -> query -> escalate
```

- `AGENTS.md` contains the short, always-loaded repository contract.
- `.agents/skills/cbt-diagnostics/SKILL.md` contains the reusable CBT diagnosis procedure for Agent Skills-compatible clients.
- `scripts/ai-context.sh` inventories `logs/` and `validation/` without scanning or emitting their contents, then returns bounded, redacted snippets only for explicitly selected files.
- `docs/ai-agent-workflow.md` documents evidence selection, Kubernetes queries, redaction, and no-data-loss rules.

Start with an offline inventory:

```sh
make ai-context
```

Then select only the relevant artifact and signal:

```sh
scripts/ai-context.sh \
  --file logs/e2e-2026-09-29-success.log \
  --snippets \
  --focus 'error|fail|warn|checkpoint|backup'
```

Use `--raw-range PATH:S-E` only for exact local evidence. It is intentionally unredacted and should not be sent to an AI service without review. The tool never modifies source artifacts and reports a SHA-256 plus line references so bounded output remains auditable.

For cluster diagnosis, query the named backup/VM fields with `oc get -o jsonpath`, then resource-scoped Warning events. Escalate to bounded controller or pod logs only when object status and events leave a causal gap. Metrics and traces remain appropriate for performance and cross-component timing questions; they are not substitutes for backup object status.


## Prerequisites

Local tools:
- Bash 3.2 or newer, Make, `oc`, `ssh`, `ssh-keygen`, and `rsync` for `sync.sh`.
- A readable kubeconfig and permission to create/delete the demo resources.

Cluster resources:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` APIs.
- The `IncrementalBackup` feature gate.
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
```

The scripts write concise structured progress messages to stderr. Each workflow uses numbered steps with `→` action lines and `✓` success lines; failures identify the active step while preserving the underlying command diagnostics. `make vm-cbt-demo` and `make e2e` add stage-level headers without printing every shell command. Guest `sha256sum` output and backup checkpoint summaries remain visible in the normal command output.

The fixed names allow one run per namespace. Start over with:

```sh
make clean-all
```

Cleanup deletes only `vm-cbt-demo` resources and waits for its dynamically provisioned PVs to be reclaimed. It does not uninstall KubeVirt or delete the shared storage class.

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

Inventory generated evidence without scanning or emitting its contents:

```sh
make ai-context
```


For an environment with the prerequisites and cluster resources, run `make e2e`, then `make clean-all`. No offline simulation can prove Kubernetes backup status; the E2E workflow is the functional validation.

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
├── .agents/               # Reusable Agent Skills-compatible procedures
│   └── skills/cbt-diagnostics/SKILL.md
├── .env.example          # Sanitized local configuration template
├── .gitignore            # Secret and generated-artifact exclusions
├── AGENTS.md             # Repository-specific contributor/agent guidance
├── docs/                 # Detailed workflow and AI evidence documentation
├── manifests/            # VM, full-backup, and incremental-backup resources
├── scripts/              # Workflow, context triage, and shared helpers
│   └── dotenv.sh         # Safe parser for supported .env values
└── sync.sh               # Optional remote synchronization helper
```

## Known limitations

- Resource names and namespace are fixed; concurrent runs require separate copies with deliberate manifest/script changes.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- The demo uses a 30 GiB local/RWO disk and is not production storage or disaster-recovery guidance.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
