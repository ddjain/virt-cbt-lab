# KubeVirt CBT VM backup demo

This repository demonstrates Changed Block Tracking (CBT) for KubeVirt virtual-machine backups. The default workflow uses the cluster-provided RHEL 9 DataSource and ODF large-ODF manifests, writes a deterministic baseline file set and manifest, takes one full backup followed by the configured sequential incremental backups, then verifies every checkpoint and restored workload prefix. Debian and Windows remain supported overrides with their own image/guest setup.

The workflow is a demonstration, not a production backup policy. Each run uses run-derived resource names in a shared namespace and local/RWO storage.

## Quick start

After meeting the prerequisites below and selecting a supported cluster with `oc`, run the one-shot E2E:

```sh
make e2e
```

`make e2e` runs read-only preflight, VM setup, one full backup, the configured incremental passes, and restore verification. Defaults: RHEL 9 on large-ODF, 8 baseline files, 4 new files and 1 modified baseline file per incremental pass, 1 pass, and 4–12 MiB per file. Without ODF, use `make e2e VM_OS=debian MANIFEST_VARIANT=default`. A `.env` file is optional; `make` loads it when present.

### Separate full and incremental commands

```sh
make e2e TYPE=full VM=vm-demo
make e2e-incremental VM=vm-demo
```

This runs the default single incremental pass after the full backup; the final pass also runs verification. For `N` passes, set `GUEST_INCREMENTAL_PASSES=N` on `TYPE=full`, then run `make e2e-incremental VM=vm-<run-id>` `N` times. `make e2e TYPE=incremental VM=...` remains an equivalent interface. Keep the same `VM`; later stages reuse settings saved by the full stage. When a staged command leaves planned incremental passes outstanding, it exits without waiting for future backup objects; automatic timing collection runs after the final pass.


### Supported E2E modes

| `TYPE` | Behavior |
|---|---|
| `all` (default) | Run setup, full backup, all planned incrementals, and verification in one command. |
| `full` | Start a lifecycle and take its full backup. Set `VM=vm-<run-id>` for a predictable name in later stages. |
| `incremental` | Add the next planned pass to `VM`; the final planned pass also verifies. Alias: `make e2e-incremental VM=vm-<run-id>`. |
| `verify` | Recheck checkpoints and restored data without adding a pass; e.g. `make e2e TYPE=verify VM=vm-demo`. |
| `extend` | Add one pass to a completed lifecycle; e.g. `make e2e TYPE=extend VM=vm-demo EXTEND_TO_PASS=4` after three passes. |

Use `VM=vm-<run-id>` for `incremental`, `verify`, and `extend`. `EXTEND_TO_PASS` must be exactly one above the completed total.

Key Make variables such as `VM_OS`, `MANIFEST_VARIANT`, `GUEST_*`, and `DEBUG` are documented in [Supported variables](#supported-variables). Run `make preflight` for a read-only readiness check and `make help` for the other public Make targets. `make clean-all` deletes every workflow-managed resource in the namespace; reports are retained.

## Architecture and workflow

```text
vm-setup -> vm-backup -> [vm-cbt-backup] x GUEST_INCREMENTAL_PASSES -> vm-cbt-verify
```
For the component, network, storage, checkpoint, source-code, sequence-diagram, and failure-boundary reference, start with [`docs/cbt/README.md`](docs/cbt/README.md). The stable architecture hub is [`docs/cbt-architecture.md`](docs/cbt-architecture.md).
- `common.sh` centralizes workflow names, environment handling, prerequisite checks, guest-key creation, port-forward cleanup, and backup queries.
- `scripts/dotenv.sh` safely reads supported `.env` values without executing the file; both `preflight` and `sync.sh` use it.
- `vm-setup.sh` imports the cached Debian image or clones the cluster-provided RHEL 9 DataSource, then creates a Linux VM with SSH; `windows-vm-setup.sh` reuses the Windows golden DataSource, attaches a run-scoped OOBE Secret, and initializes a run-scoped file workload through QEMU Guest Agent.
- `vm-backup.sh` creates the backup PVC, tracker, and full backup, then streams observed backup status while waiting for completion.
- `vm-cbt-backup.sh` adds new deterministic workload files and modifies one existing baseline file per pass, verifies the guest inventory against the saved manifest, creates its pass-specific incremental backup, then advances lifecycle state only after the backup and tracker checkpoint succeed.
- `vm-cbt-verify.sh` checks CBT, completion, every distinct checkpoint, and the final tracker checkpoint, then verifies the full restore and every cumulative incremental restore prefix before merging report fragments into `report.json`.
- `vm-cbt-restore-test.sh` reconstructs the guest disk from the full and every incremental backup PVC, then verifies the baseline and each cumulative restore prefix — see [`docs/restore-verification.md`](docs/restore-verification.md) for the full command-by-command reference and independent cross-checks.
- `clean-all.sh` removes workflow-managed resources, including per-run Windows OOBE Secrets, from the shared namespace and only the guest key marked as workflow-managed.

Each run also writes a structured JSON report to `runs/<run-id>/report.json` — see [Run report](#run-report) below.

The VM manifest supplies the `cbt-demo=enabled` label used by this demo. The cluster's selector representation varies by KubeVirt version, so preflight does not gate on that literal configuration; setup and verification require the resulting VM CBT state to be `Enabled`.

## Prerequisites

Local tools:
- Bash 3.2 or newer for the core workflow; `make monitor` requires Bash 4+ because it uses associative arrays. Also require Make, `oc`, `jq`, and a SHA-256 utility (`shasum` or `sha256sum`) for workload manifests; Debian and RHEL 9 setup require `ssh` and `ssh-keygen`. Windows setup requires `python3`, and first-time golden-image creation also requires `curl`.
- A readable kubeconfig and permission to create/delete the demo resources.

Cluster resources:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` APIs.
- The `IncrementalBackup` feature gate.
- The default RHEL 9 large-ODF profile requires a ready `rhel9` DataSource in `openshift-virtualization-os-images`, a `Bound` source PVC, and the `ocs-storagecluster-ceph-rbd` class. It requests an 80Gi root disk and full-backup PVC plus a 30Gi incremental PVC per pass; CDI may increase the actual root PVC request.
- Debian requires `cbt-demo-hpp` or the selected ODF StorageClass for its RWO VM and backup PVCs. Use `VM_OS=debian MANIFEST_VARIANT=default` for HPP or `MANIFEST_VARIANT=odf` for the small ODF profile.
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

### Supported variables

| Variable | Required | Default | Meaning |
|---|---:|---|---|
| `KUBECONFIG_PATH` | No | Unset | Kubeconfig path; when unset, use `$KUBECONFIG`, then the `oc` default. |
| `GUEST_KEY` | No | `keys/id_ed25519` | Repository-local private key path (gitignored). |
| `REMOTE_HOST` | For `make sync`/`make resync`/`make pull-reports` | Unset | SSH host or alias used for synchronization. |
| `REMOTE_DIR` | For `make sync`/`make resync`/`make pull-reports` | Unset | Destination directory on that host. |
| `NAMESPACE` | No | `vm-cbt-demo` | Kubernetes namespace for workflow resources. |
| `TYPE` | No | `all` | E2E mode: `all`, `full`, `incremental`, `verify`, or `extend`. |
| `VM` | For staged `incremental`/`verify`/`extend` | Unset | Managed VM name `vm-<run-id>`; optionally set on `full` for a predictable name. |
| `NAME` | No | Unset | Optional fixed run ID for `TYPE=all` or `TYPE=full`; when both `NAME` and `VM` are unset, a new run ID is generated. |
| `VM_OS` | No | `rhel9` | Guest profile for `make e2e`: `rhel9` (cluster-provided RHEL 9 DataSource), `debian`, or `windows`. |
| `RESTORE_HELPER_IMAGE` | For `vm-cbt-restore-test` | Unset | Image providing `qemu-img`, `util-linux`, and `ntfs-3g`, built from `images/restore-helper/Dockerfile` and pushed to a registry you control. |
| `DEBUG` | No | `false` | Normal output shows phase headers, numbered steps, concise results, warnings/failures, and a final PASS/FAIL/INCOMPLETE box with total elapsed time. Detailed commands and watcher diagnostics remain in `runs/<run-id>/logs/workflow.log`; `DEBUG=true` also prints timestamped command, status, progress, and backup-condition/VMI details. |
| `GUEST_BASE_FILE_COUNT` | No | `8` | Number of deterministic files created before the full backup. |
| `GUEST_INCREMENTAL_FILE_COUNT` | No | `4` | Number of new deterministic files added in each pass; every pass also modifies one deterministic baseline file. |
| `GUEST_INCREMENTAL_PASSES` | No | `1` | Number of incremental backups after the single full backup; maximum `99`. |
| `EXTEND_TO_PASS` | For `TYPE=extend` | Unset | Target total incremental count when adding exactly one pass; valid range `2`–`99`. For example, `4` extends a three-pass run. |
| `GUEST_FILE_SIZE_MIN_MIB` / `GUEST_FILE_SIZE_MAX_MIB` | No | `4` / `12` | Inclusive whole-MiB size range for each file. Selected sizes and SHA-256 hashes are recorded in the run manifest. |
| `MANIFEST_VARIANT` | No | `large-odf` | `large-odf` is the standard RHEL 9 ODF profile; Debian also supports `odf`, `default`, and `large`. RHEL 9 maps HPP variants to `large` and ODF variants to `large-odf`; Windows uses fixed ODF storage sizing. |
| `WINDOWS_ISO_PATH` | If the ISO is not already staged | Unset | Local Windows Server 2022 Evaluation ISO path used only when `vm-cbt-images/windows-iso` is not `Succeeded`; never copied into the repository. |
| `WINDOWS_ADMIN_PASSWORD_FILE` | For Windows setup | Unset | Local, gitignored file containing the Administrator password; never committed or logged. |

`Unset` means the variable has no fixed value; documented fallbacks or generated run IDs still apply. `.env.example` uses placeholders for `REMOTE_HOST`, `REMOTE_DIR`, and `RESTORE_HELPER_IMAGE`; replace them before use.

### Default RHEL 9 large-ODF profile

With no profile overrides, `make e2e` uses VM_OS=rhel9 and MANIFEST_VARIANT=large-odf. It clones the cluster-provided RHEL 9 DataSource using the ODF large manifests (80Gi root/full requests and 30Gi per incremental PVC). Check the available ODF capacity before multi-pass runs.

### Small Debian ODF variant

For Debian on ODF, set `VM_OS=debian MANIFEST_VARIANT=odf`. This selects `manifests/vm-odf.yaml`, `manifests/full-backup-odf.yaml`, and `manifests/incremental-backup-odf.yaml` with 6Gi/6Gi/4Gi PVC sizing. That margin accounts for CDI clone-time filesystem overhead and Ceph RBD's strict PVC capacity enforcement; a flat 5Gi backup target can fail with `No space left on device`.

### `default` variant (clusters without ODF)

Set `MANIFEST_VARIANT=default` to run against the plain `manifests/vm.yaml`, `manifests/full-backup.yaml`, and `manifests/incremental-backup.yaml` on `cbt-demo-hpp` (5Gi/5Gi/3Gi PVCs), for clusters that don't have ODF deployed.

## Windows VM setup

`make windows-vm-setup` is the single-VM setup step before running a Windows backup workflow. It runs the Windows preflight, builds the cached Windows Server 2022 golden image if missing, clones a run-scoped VM from `vm-cbt-images/windows-server-2022`, applies a run-scoped OOBE Secret, and waits for CBT and QEMU Guest Agent readiness. The reusable image contains Python 3.12.4 plus file-writer, SQLite-writer, and HTTP-server workloads, started by the `StartWorkloads` SYSTEM startup task. Image creation verifies the workloads, then removes generated log/database data before sysprep. Each runtime clone verifies the startup task, file/SQLite writes, HTTP on port 8080, and three Python processes before initializing its CBT workload under `C:\cbt-data\workload`.
The Windows VM template disables eviction-driven migration for the demo because a migration can interrupt the QEMU Guest Agent while a guest command is running. Runtime startup verification probes the agent socket and retries once if the guest agent drops during the initial Windows boot window.

`WINDOWS_ADMIN_PASSWORD_FILE` must name a readable, local, gitignored password file for the initial image build and every runtime clone; the file must contain exactly one non-empty UTF-8 password line, with no variable-name prefix, quotes, username, or additional lines. Each clone uses it to create a run-scoped OOBE Secret. Set `WINDOWS_ISO_PATH` only if DataVolume `vm-cbt-images/windows-iso` is not already `Succeeded`; the builder reuses a completed ISO upload. `make windows-vm-setup` builds the golden-image cache automatically when needed; `make windows-golden-image` runs that one-time step by itself. The ISO is staged on `cbt-demo-hpp` as a Filesystem PVC because KubeVirt's CD-ROM needs a file-backed volume; the Windows VM disk uses the ODF virtualization Block class. See [`docs/windows-server-2022-setup-runbook.md`](docs/windows-server-2022-setup-runbook.md) for the chronological procedure.
The installer guest also needs outbound HTTPS access to `www.python.org` to install Python 3.12.4.

### Large-disk variant (chaos testing)

Set `MANIFEST_VARIANT=large` to run against `manifests/vm-large.yaml` (40Gi root disk), `manifests/full-backup-large.yaml` (40Gi PVC), and `manifests/incremental-backup-large.yaml` (25Gi PVC) on `cbt-demo-hpp` instead of the default demo manifests; it exists to give chaos scenarios (see `cbt-chaos/chaos-plan.md`) a longer, disk-bound backup-copy window than the small demo sizing produces on fast local storage. Set `MANIFEST_VARIANT=large-odf` for the same sizing intent on ODF/Ceph instead — `manifests/vm-large-odf.yaml` (48Gi root disk), `manifests/full-backup-large-odf.yaml` (48Gi PVC), and `manifests/incremental-backup-large-odf.yaml` (30Gi PVC). These are the Debian large-profile requests; RHEL 9 resolves the selected backend's large root/full requests to 80Gi.

For a Debian chaos-test starting point, run `make e2e MANIFEST_VARIANT=large GUEST_BASE_FILE_COUNT=8 GUEST_INCREMENTAL_FILE_COUNT=11 GUEST_FILE_SIZE_MIN_MIB=512 GUEST_FILE_SIZE_MAX_MIB=1536`. The current deterministic file-name assignment totals 8511 MiB baseline and 12858 MiB incremental. These are payload totals, not timing measurements; confirm the actual window with `scripts/monitor.sh`. Do not assume this preset fits the Windows root disk without checking available capacity.

## Preflight

Run the read-only readiness check directly, or let `make e2e` run it automatically before any workflow step:

```sh
./preflight
```

`make e2e` stops before creating resources when preflight reports a failure. Use `make preflight` to invoke the same check explicitly.


`preflight` selects prerequisites from `VM_OS`. Debian and RHEL 9 check SSH tools and the guest key; RHEL 9 also checks that the cluster `rhel9` DataSource exists and its source PVC is `Bound`. Windows checks Python, the admin-password file, required ODF storage classes, and the local ISO path/upload route when the golden DataSource is missing. All profiles check kubeconfig, cluster reachability, CBT/CDI APIs, feature gates, permissions, and repository files. It never installs tools or changes cluster resources.

The default output includes any `WARN`/`FAIL` checks, aggregate counts, and `READY`/`NOT READY`; successful `PASS` details and section headers appear only with `--verbose`. A failure always returns exit code `1`. Verbose output includes this safe diagnostic note; command errors remain suppressed to avoid leaking credentials or kubeconfig data:

```text
[timestamp] [preflight 4/7] Cluster Access
PASS  an OpenShift context is selected
PASS  oc authentication succeeded
PASS  cluster API is reachable
Summary: 91 checks; 91 passed; 0 warnings; 0 failures
Diagnostics: detailed command errors were suppressed to avoid exposing credentials or kubeconfig data.
READY: environment is prepared for the repository workflow.
```

The script reads supported values from `.env` when corresponding environment variables are unset; it does not execute `.env`. `KUBECONFIG_PATH` and `GUEST_KEY` use the same defaults as the workflow scripts. A preflight pass confirms prerequisites and access, not that a later backup operation will succeed.

## Profile-specific run examples

The [Quick start](#quick-start) section covers one-shot and staged E2E commands. The examples here show profile-specific and larger-workload settings.

Run the default RHEL 9 CBT profile using the cluster-provided `rhel9` DataSource:

```sh
make e2e
```

This uses the ODF `large-odf` manifests. Use `make e2e VM_OS=debian` for the Debian override.

The earlier RHEL 9 `large-odf` measurement used a 48Gi DataVolume request:
CDI expanded its PVC request to 50.88Gi (51Gi reported capacity), with
48Gi full and 30Gi incremental backup PVCs. That one-pass run requested
about 129.42Gi including the ~0.54Gi KubeVirt persistent-state claim
(130Gi planning budget); this is historical, not the current 80Gi profile.
The current RHEL 9 large manifests request 80Gi for the root DataVolume and
full-backup PVC. Three ODF incremental passes add 3 × 30Gi; nominal claims
total 250Gi before CDI root-PVC overhead and persistent-state. Restore adds
no PVC; its `emptyDir` scratch uses node ephemeral storage. See
[RHEL 9 storage footprint](docs/vm-cbt-workflow.md#rhel-9-storage-footprint).

For Windows, first validate one VM and its backup test file:

```sh
make windows-vm-setup
```

Then run the Windows CBT E2E profile:

```sh
make e2e VM_OS=windows NAME=windows-cbt-1
```


### Larger deterministic file workload

Keep the small defaults in `.env.example`, or override them per invocation for a larger CBT payload:

```sh
make e2e VM_OS=windows NAME=windows-01 \
  GUEST_BASE_FILE_COUNT=100 GUEST_INCREMENTAL_FILE_COUNT=50 \
  GUEST_FILE_SIZE_MIN_MIB=5 GUEST_FILE_SIZE_MAX_MIB=10

make e2e VM_OS=rhel9 NAME=rhel9-01 \
  GUEST_BASE_FILE_COUNT=100 GUEST_INCREMENTAL_FILE_COUNT=50 \
  GUEST_FILE_SIZE_MIN_MIB=5 GUEST_FILE_SIZE_MAX_MIB=10
```

The deterministic plan totals 739 MiB baseline, 380 MiB incremental, and 1,119 MiB combined. Use a unique `NAME` per run and run sequentially from one checkout because workflow state is shared.

For the requested RHEL 9 80Gi workload with three incremental passes:

```sh
make e2e VM_OS=rhel9 MANIFEST_VARIANT=large-odf \
  GUEST_BASE_FILE_COUNT=1000 GUEST_INCREMENTAL_FILE_COUNT=500 \
  GUEST_INCREMENTAL_PASSES=3 \
  GUEST_FILE_SIZE_MIN_MIB=10 GUEST_FILE_SIZE_MAX_MIB=15
```

This creates 1,000 baseline files and adds 500 files per pass, ending with
2,500 files. Each file is deterministically sized from 10–15 MiB inclusive.
The combined payload ranges from 25,000 to 37,500 MiB (~24.4–36.6GiB),
excluding the RHEL OS and filesystem metadata. On ODF, root/full/three
incremental PVC requests total 250Gi nominally (80Gi + 80Gi + 3 × 30Gi),
before CDI root-PVC overhead and KubeVirt persistent-state storage. Use
`MANIFEST_VARIANT=large` on HPP (235Gi nominal requests) and confirm cluster
capacity before running.

`windows-vm-setup` builds the cached Windows image automatically when it is missing (requires `WINDOWS_ISO_PATH` and `WINDOWS_ADMIN_PASSWORD_FILE`). The Windows E2E target reuses the generic backup/tracker workflow and verifies restored NTFS file bytes.

Use a fixed, deterministic run name with the default RHEL 9 profile instead of the random one:

```sh
make e2e NAME=foo
```

Run individual stages for the default RHEL 9 profile:

```sh
make preflight
make vm-setup
# Replace vm-my-run with the VM name printed during setup.
make vm-backup VM=vm-my-run
make vm-cbt-backup VM=vm-my-run
make vm-cbt-verify VM=vm-my-run
```

### Timestamped E2E logs

`make e2e` logs UTC timestamps and `elapsed_seconds` for preflight and each top-level target. `vm-cbt-demo` separately times VM setup/baseline workload, the full backup, each incremental pass, and verification/restore. After all planned backups complete, the cluster-read-only monitor persists each backup's API creation time, `Done.lastTransitionTime`, duration in seconds, and reason under `backup_timings` in the run report and `runs/<run-id>/run.json`.

For a separate live monitor, run `make monitor VM=vm-<run-id>` after setup creates `runs/<run-id>/run.json`. It watches the full backup and every planned incremental name, including backup objects not yet created. On completion, it writes `fragments/backup-timings.json` and updates `report.json` if present.

The full-backup step logs baseline file count and payload bytes. Each incremental pass records added files and payload bytes, the modified baseline file's hash, and cumulative workload totals. The structured JSON report retains per-pass payload/checkpoint data and restore results for the baseline and every prefix.

Each `TYPE=all` or `TYPE=full` lifecycle uses a unique run ID by default (`<adjective>-<noun>-<hex tag>`), or a fixed ID from `NAME`/`VM`; fixed IDs must be unused and cannot be reused because each run directory is immutable. Resource names derive from the ID, so separate lifecycles coexist in `NAMESPACE` without cleanup. `TYPE=incremental` and `TYPE=verify` use the existing `VM` and its saved lifecycle state. Run `make clean-all` to remove all workflow-managed runs:

```sh
make clean-all
```

Cleanup deletes only resources labeled `app.kubernetes.io/managed-by=virt-cbt-lab` (every run this workflow created) and waits for their dynamically provisioned PVs to be reclaimed; it does not delete the namespace itself or any unrelated resources in it. It does not uninstall KubeVirt or delete the shared storage class. See `docs/vm-cbt-workflow.md` for the full resource-naming scheme.

## Synchronization helper

`make sync` (also `make resync`) pushes the working tree. `make pull-reports` copies all of `REMOTE_DIR/runs/` into local `runs/` and does not modify the remote. All three targets use `REMOTE_HOST` and `REMOTE_DIR` from Make variables or `.env`; neither has a built-in default. The push excludes `.env` files, `.git`, local credentials, generated data, and tooling state.

With `.env` configured, use:

```sh
make sync
make pull-reports
```

For a one-off remote host and path:

```sh
make REMOTE_HOST=example-host REMOTE_DIR=/path/to/cbt-setup sync
make REMOTE_HOST=example-host REMOTE_DIR=/path/to/cbt-setup pull-reports
```

The helper requires local `ssh` and `rsync` and never transfers credentials. `pull-reports` retrieves the local report artifacts; guest workload files remain inside the VM.

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
├── manifests/            # Debian and RHEL 9 VM sources, backups, and restore verification resources
├── scripts/              # Workflow implementation and shared helpers
│   ├── dotenv.sh         # Safe parser for supported .env values
│   ├── run-id.sh          # Shared immutable run ID generation
│   ├── restore-lib.sh    # Restore-verification pod orchestration
│   └── workload-manifest.sh # Deterministic file plans and run manifests
├── runs/                 # Per-run metadata, workload manifests, reports, logs, and evidence (gitignored; survives clean-all)
```

## Run report

Each lifecycle has one immutable `runs/<run-id>/` directory. `run.json` stores the VM UID, saved workload/profile configuration, backup checkpoints, and lifecycle state. The workload manifest, report, report fragments, logs, evidence, and restore artifacts live beside it; staged commands select the lifecycle by `VM=vm-<run-id>`.

`report.json` contains, per run:
- `os_profile`: `debian`, `rhel9`, or `windows`.
- `guest.workload`: directory, file-size range, baseline and per-pass file counts, added and modified file counts/hashes, added/cumulative payload byte totals, manifest hashes, and `workload-manifest.json` path.
- `backups.full` and `backups.incrementals[]`: names, types, checkpoints, per-pass file/payload totals, and backup PVC names/requested sizes/capacities.
- `backup_timings.full` and `backup_timings.incrementals[]`: API creation and Done timestamps, `duration_seconds`, and terminal reason for each backup.
- `tracker`: the `VirtualMachineBackupTracker` name and latest checkpoint.
- `verification.checks`: CBT/checkpoint/PVC checks plus full-only and every cumulative restore prefix's file counts, byte totals, and manifest-hash comparisons.
- `evidence.vm_backup_status`: optional relative paths to matching KubeVirt VM status snapshots under `evidence/`; values are `null` when no matching snapshot is available. Raw status is never mixed into test-level backup records.
- `logs`: relative paths to `workflow.log` plus the collected `virt-launcher` and restore-pod logs.

`run.json` is the separate lifecycle index; it stores the saved configuration, VM UID, pass counters, backup/checkpoint records, and lifecycle status. Updates are atomic; `make clean-all` marks it cleaned but retains it with the run report.

Unlike transient `state/` (the checkout operation lock), `runs/` is not deleted by `make clean-all` — it preserves each run's metadata, report, and debugging evidence. Normal output shows top-level Make stages and key progress/status; routine substeps/actions/successes are in `logs/workflow.log`, and `DEBUG=true` prints them plus detailed status snapshots. Inspect a run with `jq . runs/<run-id>/report.json` or compare two reports. Log collection is best-effort and does not collect cluster component logs.

## Known limitations

- All runs share the namespace and local/RWO storage. The checkout E2E lock prevents concurrent `make e2e` operations in one checkout; use separate repository copies for parallel operations. Staged `TYPE=incremental` commands use the per-VM lifecycle record. `make clean-all` removes every workflow-managed run in the namespace, not only the most recent one.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- Debian uses small local/RWO disks, RHEL 9 uses an 80Gi root/full-backup request with 25Gi/30Gi incremental PVCs on HPP/ODF, and Windows uses a 40Gi Block-mode root plus 48Gi/30Gi ODF Filesystem backup PVCs. These are demo configurations, not production storage or disaster-recovery guidance.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `make vm-cbt-restore-test` uses a privileged pod to reconstruct backups and read guest files from ext4 (Debian), XFS (RHEL 9), or NTFS (Windows). Build and push `images/restore-helper/Dockerfile` with `qemu-img`, `util-linux`, and `ntfs-3g`, set `RESTORE_HELPER_IMAGE`, and allow the privileged pod.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
