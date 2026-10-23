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

This runs the default single incremental pass after the full backup; the final pass also runs verification. For `N` passes, set `GUEST_INCREMENTAL_PASSES=N` on `TYPE=full`, then run `make e2e-incremental VM=vm-<run-id>` `N` times. `make e2e TYPE=incremental VM=...` remains an equivalent interface. Keep the same `VM`; later stages reuse settings saved by the full stage. When a staged command leaves planned incremental passes outstanding, it prints the exact next `make e2e TYPE=incremental VM=...` command and exits without waiting for future backup objects; the final pass verifies automatically.


### Supported E2E modes

| `TYPE` | Behavior |
|---|---|
| `all` (default) | Run setup, full backup, all planned incrementals, and verification in one command. |
| `full` | Start a lifecycle and take its full backup. Set `VM=vm-<run-id>` for a predictable name in later stages. |
| `incremental` | Add the next planned pass to `VM`; the final planned pass also verifies. Alias: `make e2e-incremental VM=vm-<run-id>`. |
| `verify` | Recheck checkpoints and restored data without adding a pass; e.g. `make e2e TYPE=verify VM=vm-demo`. |
| `extend` | Add one pass to a completed lifecycle; e.g. `make e2e TYPE=extend VM=vm-demo EXTEND_TO_PASS=4` after three passes. |
| `reconcile` | Reset a failed incremental pass back to `incremental_ready` after its failed backup/PVC are deleted (evidence preserved out-of-band) and the tracker is verified at the prior checkpoint; then retry with `TYPE=incremental`. |
| `recover` | On an existing managed VM with a terminally failed full, create a distinct full-backup attempt using the existing tracker and restore-verify its baseline; never initializes a new VM. |
Use `VM=vm-<run-id>` for `incremental`, `recover`, `verify`, and `extend`. `EXTEND_TO_PASS` must be exactly one above the completed total.
`make e2e TYPE=recover VM=vm-<run-id>` acquires the checkout lifecycle lock, validates the failed full/PVC and VM/VMI/CBT state, then creates a new PVC and `VirtualMachineBackup` with `forceFullBackup:true` against the saved tracker. It preserves the failed artifacts and records every attempt separately. Recovery passes only when the new request is a successful `Full`, the tracker records its checkpoint, the output PVC is Bound, and a read-only restore matches the saved baseline file set, bytes, and hashes.

`make e2e TYPE=reconcile VM=vm-<run-id>` is the supported retry path for a failed incremental pass (`incremental_failed`). It refuses to act unless the failed pass's backup object and PVC are already deleted (preserve their evidence out-of-band first) and the live tracker still sits at the prior checkpoint with the base backup still `Done=True`. On success it resets the lifecycle to `incremental_ready`, removes the failed pass pointer, and records a `reconcile_events` audit entry in the run metadata; it never deletes or mutates cluster resources itself.

Key Make variables such as `VM_OS`, `MANIFEST_VARIANT`, `GUEST_*`, and `DEBUG` are documented in [Supported variables](#supported-variables). Run `make preflight` for a read-only readiness check and `make help` for the other public Make targets. `make clean-all` deletes every workflow-managed resource in the namespace; reports are retained.

## Staged CBT lifecycle commands

Each lifecycle stage is one Make target backed by the shared dispatcher (`scripts/stage.sh <stage>`, also `scripts/stage.sh list` and `scripts/stage.sh --dry-run <stage>`). `make e2e` runs preflight once up front and then drives those same stage entry points in order with `E2E_STAGE_WRAPPED=true`, so the one-shot and staged commands execute identical code. `make help` lists the stages; `make stage-list` prints the same mapping as a machine-readable table.

| Target | Required args | Purpose | Produces / verifies |
|---|---|---|---|
| `make vm-setup` | `NAME=<id>` optional | Create the CBT-enabled VM and the deterministic baseline workload (`VM_OS=windows` runs the Windows setup script instead). | `runs/<run-id>/run.json`, `workload-manifest.json`, and the VM/root disk/SSH service. |
| `make vm-backup` | `RUN_ID=<id>` or `VM=vm-<id>` | Take the lifecycle's single full backup. | Full `VirtualMachineBackup` checkpoint, tracker checkpoint, and backup PVC recorded in `run.json`. |
| `make vm-cbt-backup` | `RUN_ID=<id>` or `VM=vm-<id>` | Mutate the guest workload and take the next planned incremental pass. | One incremental checkpoint and its pass record in `run.json`; verification is a separate step, so run `make vm-cbt-verify RUN_ID=<id>` after the last planned pass. |
| `make vm-cbt-extend` | `RUN_ID`/`VM` plus `EXTEND_TO_PASS=N` | Prepare exactly one extra pass on a completed lifecycle; `N` is the new total (completed total + 1, `2`–`99`). | The extension plan and an `extension-pass-NN` fragment; run `make vm-cbt-backup RUN_ID=<id>` to create the pass, then `make vm-cbt-verify RUN_ID=<id>` to verify the chain and the restores. |
| `make vm-cbt-recover` | `RUN_ID=<id>` or `VM=vm-<id>` | After a terminally failed full backup, take a new full backup on the existing VM through the saved tracker (`forceFullBackup:true`). | A recorded recovery attempt and baseline restore verification; never creates a new VM. |
| `make vm-cbt-reconcile` | `RUN_ID=<id>` or `VM=vm-<id>` | Reset a failed incremental pass (`incremental_failed`) to `incremental_ready` after its failed backup/PVC are deleted. | A `reconcile_events` audit entry in `run.json`; refuses unless the tracker still holds the prior checkpoint. |
| `make vm-cbt-verify` | `RUN_ID=<id>` or `VM=vm-<id>` | Recheck VM CBT state, backup types, completion, every checkpoint, and the restored baseline and prefixes without adding a pass. | Merged `runs/<run-id>/report.json` verification results. |
| `make vm-cbt-restore-test` | `RUN_ID=<id>` or `VM=vm-<id>` | Rebuild the guest disk from the full backup and every incremental PVC and verify each cumulative file set. | Restore checks in `report.json`; see [`docs/restore-verification.md`](docs/restore-verification.md). |
| `make monitor` | `RUN_ID=<id>` or `VM=vm-<id>` | Watch the full and every planned incremental backup and record API creation-to-`Done` timings. | `runs/<run-id>/fragments/backup-timings.json`, plus `report.json`/`run.json` `backup_timings` when present. |
| `make run-summary` | `RUN_ID=<id>` or `VM=vm-<id>`; optional stage and result (`PASS`, `FAIL`, or `INCOMPLETE`) | Regenerate the compact lifecycle summary. | `runs/<run-id>/summary.json`. |

Run identity: `make vm-setup` starts the run — pass `NAME=<id>` (a fixed `RUN_ID=<id>` works the same way), or let it generate an ID and print it — and every later stage selects that same lifecycle with `RUN_ID=<id>` or `VM=vm-<id>`. Existing-lifecycle commands never create a run: if the selected run has no `runs/<run-id>/run.json`, the stage stops and tells you to run `make vm-setup RUN_ID=<id>` first.

Mutating stages (`setup`, `full`, `incremental`, `extend`, `recover`, `reconcile`) run `./preflight` before they start; `verify`, `restore-test`, `monitor`, and `summary` never do, because `make e2e` already ran it once up front. Two knobs apply to every staged command: `STAGE_SKIP_PREFLIGHT=true` skips the per-invocation readiness check, and `STAGE_DRY_RUN=true` prints the resolved identity and the exact command that would run, changing nothing and not contacting the cluster.

Run one lifecycle stage by stage:

```sh
# The first stage starts the run and prints its ID (here: foo, VM vm-foo).
make vm-setup NAME=foo

# Every later stage selects the same lifecycle; it is never re-created.
make vm-backup RUN_ID=foo        # or VM=vm-foo
make vm-cbt-backup RUN_ID=foo    # repeat for each planned pass
make vm-cbt-verify RUN_ID=foo
```

With `GUEST_INCREMENTAL_PASSES` greater than 1, repeat `make vm-cbt-backup RUN_ID=<run-id>` for each planned pass and run `make vm-cbt-verify RUN_ID=<run-id>` afterwards; individual stages record their checkpoint but never verify the chain themselves. `make e2e` performs exactly this sequence in one invocation, including verification once the last planned pass completes, then records the backup timings and the run summary.

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
  Linux verification selects exactly one `*-rootdisk.qcow2` in each backup PVC, rejecting missing or ambiguous root images. Other disks may coexist, but their content is not verified by the root workload check.
- `vm-cbt-recover.sh` takes a new full backup on the selected existing VM using the run's tracker and `forceFullBackup:true`, then selects that attempt for read-only baseline restore verification. It never deletes/reuses the original failed backup/PVC.
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
| `GUEST_KEY` | No | `keys/id_ed25519` | Configured private-key path (gitignored); setup preserves an existing key, derives a missing public half, or generates a missing private key. |
| `REMOTE_HOST` | For `make sync`/`make resync`/`make pull-reports` | Unset | SSH host or alias used for synchronization. |
| `REMOTE_DIR` | For `make sync`/`make resync`/`make pull-reports` | Unset | Destination directory on that host. |
| `SCENARIO` | No | Unset | `pull-reports` filter: one v2 scenario plus its referenced lifecycle/proposal evidence. Unset includes all root runs and v2 report outputs. |
| `NAMESPACE` | No | `vm-cbt-demo` | Kubernetes namespace for workflow resources. |
| `TYPE` | No | `all` | E2E mode: `all`, `full`, `incremental`, `recover`, `verify`, or `extend`. |
| `VM` | For staged `incremental`/`recover`/`verify`/`extend` | Unset | Managed VM name `vm-<run-id>`; optionally set on `full` for a predictable name. |
| `NAME` | No | Unset | Optional fixed run ID for `TYPE=all` or `TYPE=full`; when neither `NAME` nor `VM` supplies it, a new UTC timestamp-prefixed run ID is generated. |
| `VM_OS` | No | `rhel9` | Guest profile for `make e2e`: `rhel9` (cluster-provided RHEL 9 DataSource), `debian`, or `windows`. |
| `RESTORE_HELPER_IMAGE` | For `vm-cbt-restore-test` and successful `TYPE=recover` | Unset | Image providing `qemu-img`, `qemu-nbd`, `kmod`, `util-linux`, and `ntfs-3g`, built from `images/restore-helper/Dockerfile` and pushed to a registry you control. |
| `DEBUG` | No | `false` | Normal output shows effective non-secret pipeline settings, target VM/resource names, concise phase/step results, warnings/failures, and the final PASS/FAIL/INCOMPLETE box. `DEBUG=true` adds timestamped command, status, progress, and backup-condition/VMI diagnostics. |
| `GUEST_BASE_FILE_COUNT` | No | `8` | Number of deterministic files created before the full backup. |
| `GUEST_INCREMENTAL_FILE_COUNT` | No | `4` | Number of new deterministic files added in each pass; every pass also modifies one deterministic baseline file. |
| `GUEST_INCREMENTAL_PASSES` | No | `1` | Number of incremental backups after the single full backup; maximum `99`. |
| `EXTEND_TO_PASS` | For `TYPE=extend` | Unset | Target total incremental count when adding exactly one pass; valid range `2`–`99`. For example, `4` extends a three-pass run. |
| `GUEST_FILE_SIZE_MIN_MIB` / `GUEST_FILE_SIZE_MAX_MIB` | No | `4` / `12` | Inclusive whole-MiB size range for each file. Selected sizes and SHA-256 hashes are recorded in the run manifest. |
| `GUEST_INVENTORY_VERIFY` | No | `full` | Strength of the guest inventory check before each incremental mutation: `full` re-hashes every workload file, `sample` verifies names and sizes for every file and hashes every `GUEST_INVENTORY_SAMPLE_STRIDE`-th file plus the file that pass modifies, and `skip` verifies names and sizes only. The post-mutation inventory and the restore verification always hash every file. Linux guests only; Windows runs use `full`. |
| `GUEST_INVENTORY_SAMPLE_STRIDE` | No | `16` | Stride used by `GUEST_INVENTORY_VERIFY=sample`. |
| `MANIFEST_VARIANT` | No | `large-odf` | `large-odf` is the standard RHEL 9 ODF profile; Debian also supports `odf`, `default`, and `large`. RHEL 9 maps HPP variants to `large` and ODF variants to `large-odf`; Windows uses fixed ODF storage sizing. |
| `WINDOWS_ISO_PATH` | If the ISO is not already staged | Unset | Local Windows Server 2022 Evaluation ISO path used only when `vm-cbt-images/windows-iso` is not `Succeeded`; never copied into the repository. |
| `WINDOWS_ADMIN_PASSWORD_FILE` | For Windows setup | Unset | Local, gitignored file containing the Administrator password; never committed or logged. |
| `EXISTING_VM` | For pool adoption | Unset | `vm-<pool>-NNNN` density-pool VM to adopt with `make e2e` (`TYPE=all|full` only; cannot combine with `VM`/`NAME`). Pool annotations override the profile variables. |
| `POOL` | For density targets | Generated | Density pool ID for `make density-setup`/`make density-status`; defaults to `d<UTC MMDDhhmmss>` for setup. For status, `POOL` selects one pool's funnel; without it a namespace-wide overview of all managed VMs is printed. |
| `DENSITY_VM_COUNT` | For `make density-setup` | Unset | Number of VMs in the pool (1–9999); no default to avoid accidental large creates. |
| `DENSITY_INCREMENTAL_PASSES` | No | `4` | Incremental passes recorded on pool VMs; adopted runs override `GUEST_INCREMENTAL_PASSES`. |
| `DENSITY_QPS` | No | `10` | kube-burner client rate limit (qps=burst). |
| `DENSITY_WAIT_MINUTES` | No | `240` | Bound on density-setup's VM readiness poll. |

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

## Density VM pools (kube-burner)

Create a pool of bare, backup-eligible VMs in bulk, then drive individual VMs through the normal E2E pipeline without re-creating them:

```sh
make density-setup VM_OS=rhel9 DENSITY_VM_COUNT=10
make e2e EXISTING_VM=vm-<pool>-0001
make density-status                # fleet view: all pools + un-pooled VMs
make density-status POOL=<pool>    # one pool's funnel
```

- `make density-setup` runs preflight, then uses kube-burner to create `DENSITY_VM_COUNT` VMs named `vm-<pool>-NNNN` (one OS per pool: `VM_OS=rhel9|windows`; Debian is not supported for density). `POOL` defaults to an OS-prefixed timestamp (`rhel-<MMDDhhmmss>` / `win-<MMDDhhmmss>`), so VM names read `vm-rhel-<ts>-NNNN` and stay unique across runs. RHEL VMs get a root DataVolume and SSH Service; Windows VMs share one pool-scoped OOBE Secret (`windows-oobe-<pool>`, requires `WINDOWS_ADMIN_PASSWORD_FILE`). Pool VMs carry `virt-cbt-lab/pool`, `virt-cbt-lab/run-id`, and `app.kubernetes.io/managed-by` labels plus os-profile/manifest-variant/incremental-passes annotations; no local pool metadata is kept — pool state lives entirely in those labels/annotations. The script refuses a `POOL` name that already has VMs in the namespace and polls until every VM reports `.status.ready==true` (up to `DENSITY_WAIT_MINUTES`, default 240), independent of kube-burner's own waiters.
- `make e2e EXISTING_VM=vm-<pool>-NNNN` (only with `TYPE=all` or `TYPE=full`) adopts that pool VM: creation steps are skipped, the pool's annotations override `VM_OS`/`MANIFEST_VARIANT`/`GUEST_INCREMENTAL_PASSES` from the environment, and the existing baseline-workload → full-backup → incremental → verify pipeline runs unchanged. `runs/<pool>-NNNN/` is created only at adoption. Re-adoption of a run that already has artifacts fails; use `TYPE=incremental VM=...` to continue it.
- `make density-status` prints one fleet view of every managed VM in the namespace, grouped by pool (batch): each group gets a `TOTAL/CREATING/CREATED/FULL/INCn` summary and per-VM rows (`ready|creating`, backup states `-`, `running`, `failed`, `done`). VMs created outside any pool (e.g. by `make e2e`) appear in a final `no pool` group. `POOL=<pool>` restricts the output to one pool. All read data comes live from the cluster; VMs that were never created or were deleted simply do not appear, and an empty namespace prints an informational message (exit 0). Read-only.
- The adoption run must use the same checkout (`GUEST_KEY`) that created the pool: RHEL VMs were created with that key's public half, and guest SSH in later steps uses the private half.
- Cleanup for a test pool (never `make clean-all` for this): `oc delete vm,svc,secret -n "$NAMESPACE" -l virt-cbt-lab/pool=<pool>` plus backup objects/PVCs labeled `virt-cbt-lab/run-id=<pool>-NNNN`.


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

Each stage can also be run separately; see [Staged CBT lifecycle commands](#staged-cbt-lifecycle-commands) for the target table, the argument and identity rules, and a stage-by-stage example.

### Timestamped E2E logs

`make e2e` logs UTC timestamps and `elapsed_seconds` for preflight and each top-level target. `vm-cbt-demo` separately times VM setup/baseline workload, the full backup, each incremental pass, and verification/restore. After all planned backups complete, the cluster-read-only monitor persists each backup's API creation time, `Done.lastTransitionTime`, duration in seconds, and reason under `backup_timings` in the run report and `runs/<run-id>/run.json`.

For a separate live monitor, run `make monitor VM=vm-<run-id>` after setup creates `runs/<run-id>/run.json`. It watches the full backup and every planned incremental name, including backup objects not yet created. On completion, it writes `fragments/backup-timings.json` and updates `report.json` if present.

The full-backup step logs baseline file count and payload bytes. Each incremental pass records added files and payload bytes, the modified baseline file's hash, and cumulative workload totals. The structured JSON report retains per-pass payload/checkpoint data and restore results for the baseline and every prefix.

Each staged `make e2e TYPE=...` invocation prints and records a final verdict in `runs/<run-id>/logs/workflow.log`. `TYPE=full` reports the full backup as passed while marking the lifecycle incomplete until the planned incremental passes and verification finish. A successful final incremental reports `PASS` only after checkpoint-chain and restore verification; a non-final incremental reports that verification is still pending.

Each `TYPE=all` or `TYPE=full` lifecycle uses a unique run ID by default (`<UTC YYYYMMDDHHMMSS>-<adjective>-<noun>-<hex tag>`), or a fixed ID from `NAME`/`VM`. Generated IDs sort by UTC start time at one-second precision and stay within the existing 40-character run-ID limit; supplied IDs remain unchanged. Fixed IDs must be unused and cannot be reused because each run directory is immutable. Resource names derive from the ID, so separate lifecycles coexist in `NAMESPACE` without cleanup. `TYPE=incremental` and `TYPE=verify` use the existing `VM` and its saved lifecycle state. Run `make clean-all` to remove all workflow-managed runs:

```sh
make clean-all
```

Cleanup deletes only resources labeled `app.kubernetes.io/managed-by=virt-cbt-lab` (every run this workflow created) and waits for their dynamically provisioned PVs to be reclaimed; it does not delete the namespace itself or any unrelated resources in it. It does not uninstall KubeVirt or delete the shared storage class. See `docs/vm-cbt-workflow.md` for the full resource-naming scheme.

## Synchronization helper

`make sync` (also `make resync`) pushes the working tree; it is not a report pull. The push excludes `.env` files, `.git`, local credentials, generated data (including legacy and v2 scenario `runs/`), and tooling state. `make pull-reports` is a read-only remote file transfer into the **local/control checkout**, preserving repository-relative paths. These targets use `REMOTE_HOST` and `REMOTE_DIR` from Make variables or `.env`, with no built-in host/path defaults.

Run from the local/control checkout after remote report writers have finished:

```sh
# All reports; omit SCENARIO entirely for an unfiltered pull.
make pull-reports REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout

# One scenario and only its referenced lifecycle evidence/proposal documents.
make pull-reports SCENARIO=CBT-F-05 REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout

# Equivalent shell interface.
REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout ./sync.sh --pull-reports --scenario CBT-F-05
```

With `REMOTE_HOST` and `REMOTE_DIR` configured in `.env`, use `make pull-reports` or `make pull-reports SCENARIO=CBT-F-05`. `SCENARIO` may also be configured in the environment; unset it to pull all reports. An ID must be one safe nonempty path component, not a path or `..`; quote host/path values containing spaces.

**Selection and destinations:**

- No filter: pull **all** repository-root `runs/**`, plus all v2 scenario output trees and scenario-keyed `artifacts/<ID>/**`.
- `SCENARIO=<ID>`: pull `cbt-chaos/scenarios_v2/<ID>/{bugs/**,runs/**,consolidated-report.md,approval.json}` and `artifacts/<ID>/**`. Root `runs/<lifecycle-id>/**` is restricted to `.lifecycle_ids` arrays and `.lifecycle_id` strings referenced in that scenario's direct attempt `run.json` and `analysis.json`; unrelated lifecycle runs are not pulled. Missing referenced lifecycle directories, such as a BLOCKED-before-setup attempt, are reported without fabricating evidence.
- Pull exact proposal documents listed in attempt metadata `.proposed_scenarios`: repository-relative `cbt-chaos/scenarios_v2/<new-ID>/jira-issue.md` strings. The Lead must record every created specialist draft in its owned `run.json.proposed_scenarios` before closeout; it must not edit independent `analysis.json`. Missing claimed-created drafts fail the pull. Unfiltered pulls also include standalone Jira drafts marked proposed and unexecuted, not ordinary scenario source Jira files.

Proposal Jira documents must carry an explicit status line
`PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW` (Markdown emphasis is allowed).
An ordinary source document merely mentioning those words is not a proposal.

Existing source scripts, specs and agent files are not pulled or deployed. Remote evidence remains canonical: pulling does not archive, regrade, retry, clean up evidence or change the cluster. Guest workload files remain inside the VM.

**Safety and verification:** pull requires local `ssh`, `rsync` and Python3, plus remote Python3. The inventory helper is streamed over SSH without installing scripts or writing remote manifests/directories. No cluster preflight or kubeconfig is needed for this read-only file transfer. Credential filenames/directories (`.env*`, kubeconfig variants, `.kube`, `.ssh`, keys/private-key files and Windows password files) and backup disk/image files are excluded; symlinks are never followed and special files are not payload. Filename filtering is **not embedded-log redaction**: evidence must already be sanitized.

The helper hashes the exact selected remote regular files with full SHA-256, compares local content hashes, transfers changed files, and verifies **every** selected local file. It obtains a second remote inventory and fails if selection or content changed during transfer; size/mtime or `rsync --checksum` alone are not proof. Unsafe metadata/paths, destination symlinks/collisions, missing proposals, an empty overall selection, transfer errors, corruption or source instability fail explicitly, without silent retries or a success claim for a partial copy.

Every replaced local file, including approval/consolidation files and review edits, is backed up outside the synced trees at `artifacts/sync-backups/<UTC-unique>/`. There is no `--delete`; local-only files and human-review drafts are preserved. Output reports counts, exclusions/missing lifecycle references, any conflict backup path and the verified result; unchanged stable reruns can succeed.

For chaos v2, the Lead **must** perform a verified local pull after **every terminal remote attempt**, including BLOCKED, INVALID and partial attempts, once analysis, bugs, reports, consolidation and proposals are final. Repeat after any later remote report, diagnosis or proposal update. Do not run the pull inside the remote checkout or substitute `make sync` afterward. Already-local execution needs no SSH pull. Record actual successful local report/evidence/proposal paths and the verified outcome in the final user summary; on failure preserve remote evidence and state **local synchronization incomplete**, with the failure, rather than claiming success.

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
├── artifacts/            # AI-generated reports, matrices, bug reports, analyses, plans, and archived closed-run evidence (gitignored; see scripts/archive-run.sh)
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

### AI-generated artifacts

`artifacts/` (gitignored) holds general AI-generated reports, matrices, analyses and plans, organized by scenario and `_`-prefixed categories. `scripts/archive-run.sh <run-id>` is an optional, explicitly requested archive of closed evidence (refuses in-flight runs); `--index` regenerates its archive index. CBT chaos v2 is a narrow exception: its reports, bugs and proposed scenario drafts stay canonical with their scenario, not in `artifacts/`; never automatically archive them. Existing archived/legacy evidence is not moved or regraded.

## CBT chaos v2

Request **“run CBT-F-01 with the chaos team”** via `cbt-chaos-team-v2`.
Main dispatches one dedicated `cbt-chaos-lead` subagent and relays human
approval/clarification requests. The Lead owns discovery, approval recording,
execution/monitoring, recovery, verified local report pulls and both reports.
It uses a prepare-only Chaos Engineer and one independent Analyst as
grading owner. After execution, Lead may assign additional expert Analysts to
distinct bounded read-only areas; they return findings through Lead and never
write competing overall grades or `analysis.json`. The script author never
validates its own injection.

### omp model routing

Project agent definitions in `.omp/agents/` load the existing role skills.
Model roles are indirected through `.omp/config.yml`'s `modelRoles` map, not
hardcoded per agent — check that file for the current physical model behind
each role alias:

| Agent | Role alias / thinking | Assignment |
|---|---|---|
| `cbt-chaos-lead` | `@cbt_lead` / high | Dedicated execution Lead; loads `cbt-chaos-lead-v2`, delegates specialists and requests human approval through main. |
| `cbt-chaos-engineer` | `@cbt_engineer` / high | Default Engineer: new trigger design, ambiguous evidence, complex injection repair. |
| `cbt-chaos-engineer-fast` | `@cbt_engineer_fast` / high | Engineer alternative: constrained adaptations of a verified pattern with explicit inputs, command metadata and effect checks. |
| `cbt-chaos-analyst` | `@cbt_grader` / xhigh | Every `grading-owner` assignment, and any `area-specialist` question Lead judges ambiguous or safety-relevant. |
| `cbt-chaos-analyst-fast` | `@cbt_grader_fast` / medium | A bounded, narrow, low-ambiguity `area-specialist` question only — never `grading-owner`. |

Lead assigns each Engineer spawn `bundle-preparer` (owns the one approved
bundle; at most one at a time per scenario attempt) or a bounded
`task-specialist` question, and each Analyst spawn `grading-owner` (exactly
one per attempt) or a bounded `area-specialist` question — reusing the same
two skills (`cbt-chaos-trigger-preparer-v2`, `cbt-chaos-analyst-v2`). Lead may
spawn as many specialists as the work needs, each with one assignment and a
bounded scope; there is no fixed count or mandatory committee.
Asynchronous task dispatch, parent/child messaging and at least two delegation
levels are required: main → Lead → Engineer/Analyst. If unavailable, block
rather than silently moving execution back into main.

Open `/agents`, press **Ctrl+R**, enable the definitions if needed, and confirm
their project source, effective model/thinking and disabled prewalk/advisor.
Per-agent UI settings override file defaults. Skill autoloading must resolve
`cbt-chaos-lead-v2` for Lead, `cbt-chaos-trigger-preparer-v2` for Engineers and
`cbt-chaos-analyst-v2` for Analyst; Lead also reads its skill explicitly.
Check child transcripts when smoke-testing setup. **Alt+A** opens
Agent Hub to inspect the actual worker model and activity. Model availability
fallback is not task-difficulty routing; do not silently downgrade the Analyst
or use prewalk to change models mid-assignment.

Lead sends main the exact commands, complete bundle hashes, parameters,
target/window, blast radius and rollback, bound to a unique approval request
and SHA-256 package fingerprint. Main uses structured **Approve bundle** /
**Do not run**, then returns the exact answer, matching IDs/fingerprint and UTC
timestamp. Lead records it and revalidates the bundle before execution.
No answer, rejection, stale/mismatched response or changed bundle permits
execution. Main never self-approves or runs a second workflow.

Engineers prepare only; Lead owns execution. Analyst cluster access is
read-only by policy, but a Bash grant and the approval relay are not security
sandboxes: use read-only cluster credentials when enforcement is required.
Only the four shared agent definitions are eligible for version control;
other `.omp/` settings and connection metadata remain ignored.

When approval is the only remaining work, Lead returns `approval_pending`
instead of polling or holding a dummy process open. Main asks the user and
resumes that same idle/parked Lead through messaging; pending is not completion.
Newly installed skills missing from a session's autoload/URI snapshot are read
directly from their canonical `.agents/skills/` paths.

### Scenario discovery and evidence

Discover the requested scenario under `cbt-chaos/scenarios_v2/`; read its
`scenario-spec.md` and `jira-issue.md`, then inspect the executing checkout with
`make help` and `make stage-list`. Read the selected Make recipe/stage scripts
and scenario entrypoint before execution; use existing stages, monitor/watch
helpers and an applicable scenario evaluator rather than a parallel workflow.
The default full-interruption evaluator is not valid for arbitrary scenarios,
including stable-system faults. No scenario or workflow script is generated
merely by this documentation.

CBT-F-05 has a prepared [native handler-interruption bundle](cbt-chaos/scenarios_v2/CBT-F-05/scenario-spec.md).
Its `run.sh --plan` describes setup, full-copy injection, read-only multilevel
cleanup observation through a fixed 300-second post-terminal test window, and
the conditional same-VM follow-up. Residual or UNKNOWN cleanup safely blocks
restore/reuse while preserving all resources. Execution requires complete-bundle
approval, including the existing-handler host-mount/sysfs read scope and window.
Guest-key approval supports an existing pair or setup-managed creation; only
the existing setup stage may create a missing pair. Generic launcher-interruption
evaluators are not applicable: independent analysis assesses scenario evidence.

Before accepting a bundle, the Lead/Engineer reviews relevant existing
scenario/component bug drafts and maps known failure surfaces to proposed
coverage. History informs preparation, not the independent Analyst's verdict:
its handoff contains neutral approved requirements and current raw evidence.
The recovery map separates API, guest/workload and underlying host/storage
state, with CLEAR / RESIDUAL / UNKNOWN and explicit observation bounds.
The Engineer plans bounded read-only final collection on success **and abort**;
the Analyst audits surviving resources and investigates cleanup warnings even
when Ready/conditions clear. The Lead reports data correctness, availability
and resource release separately, without claiming causality from recurrence.
These duties use the existing role capabilities, with no fixed committee,
extra execution/monitoring agents, unapproved control workloads, cleanup
mutations or artifact ledger.

Canonical layout, relative to `cbt-chaos/scenarios_v2/<ID>/`:

```text
scenario-spec.md, jira-issue.md
run.sh                         # reusable scenario entrypoint
inject.sh / condition/effect helpers (optional; names unrestricted)
approval.json                  # local explicit approval + complete bundle hashes
runs/<attempt-id>/
  run.json                     # phase/verdict, identities, relation, timestamps, paths/statuses
  injection-confirmation.json  # raw-evidence references and effect checks
  analysis.json                # independent Analyst assessment
  run-report.md                # Lead report, including INVALID/BLOCKED attempts
  ... raw evidence and logs
consolidated-report.md         # Lead roll-up of every terminal attempt
bugs/<defect-slug>.md           # Analyst, one confirmed product defect across runs
```

Lifecycle evidence stays at repository `runs/<lifecycle-id>/` and is referenced,
not copied. Raw attempt data and `approval.json` are gitignored; sanitized
reports, bugs and scenario drafts may be committed. No extra verdict file,
event ledger or output index is required.

New chaos run IDs use
`<dd-mm-yyyy-hh-mm-ss>-<vm_name>-<note>-iteration-<number>` with current UTC,
the exact existing/planned VM name, and a short lowercase note. For example,
`./cbt-chaos/run-id.sh vm-demo full-copy 1` prints that format. The Lead
increments the scenario iteration for each new attempt, including a repaired
retry, and records it in `run.json`. Lifecycle IDs keep their separate
40-character limit: never pass the descriptive chaos ID as Make's `RUN_ID`.
Existing run directories are not renamed.

Approve the **complete bundle once**: entrypoint, every invoked local script
and configuration, spec/Jira conditions, effective blast radius/window and run
parameters. Record explicit approval and hashes, verify immediately before
execution, and never edit mid-run. Unchanged approved bundles may rerun without
another approval. After INVALID caused by an injection defect, permit **one**
repair by the Chaos Engineer, fresh approval and a fresh attempt—never a silent
retry. Close/report the original attempt before that optional retry.

Injection proof captures condition-before-action, exact target UID before/after,
timestamps, effect and exclusions using scenario-specific fail-closed machine
checks, not sleeps or tool self-certification. Verdicts are PASS, product FAIL,
INVALID injection, INCONCLUSIVE product evidence, or BLOCKED prerequisites.
Every mandatory requirement must be proven for PASS; an expected interrupted
backup's nonzero exit is not automatically product FAIL. Reports preserve
deterministic failures/unknowns and link independent analysis and scoped evidence.

The grading owner or an area specialist may create an actual
`scenarios_v2/<new-ID>/jira-issue.md` after Lead deduplicates the idea and
allocates an unused ID/path. Drafts must be **PROPOSED — UNEXECUTED — PENDING
HUMAN REVIEW**, with source evidence, author area, test intent, scope/risks
and honest unknowns. The final user summary and run/consolidated reports list
every created ID, purpose and actual path, not just chat suggestions. Humans
review/revise or manually delete unwanted drafts; agents never auto-prune or
archive them. Creating a draft does not approve execution. Lead alone records
deduplicated evidence-backed lessons in its skill's `improvement.md`.

## Chaos observer readiness

`cbt-chaos/watch-resource.sh <namespace|-> <resource> <name|label|field> <selector> <output.jsonl> <ready-file>` is a read-only, long-lived resource watch for both legacy and v2 scenarios. The caller creates a fresh scenario run's `observer/` directory and exports its approved host-local `KUBECONFIG_PATH` (or `KUBECONFIG`) before starting the helper. Use `-` as the namespace for cluster-scoped resources; `name` filters `metadata.name` even when the object does not exist yet. It saves `<output>.baseline.json`, streams updates to `<output>`, and writes errors to `<output>.stderr`. A ready file appears only after a successful scoped API read and healthy watch startup, and is removed when the watch stops or fails. Supervise the helper process and confirm the ready file still exists before injection. Readiness alone does **not** prove a scenario-specific signal, target UID/owner, or disruption; the scenario's observer must verify these separately. No cluster objects are modified.

The same child checks `watch` authorization before arming. A ready file only describes startup: if the watch exits, it is revoked, so the coordinator must also stop/hold a not-yet-fired action when a required watch dies.

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
- `recovery.attempts[]`: separate blocked, failed, and successful same-VM recovery records, including original failed artifacts, recovery backup/PVC/checkpoint, tracker transition, and baseline restore checks.

`summary.json` is the compact, human-facing projection written by `make e2e` and direct `make vm-cbt-verify`. It shows the lifecycle/recovery verdict (`PASS`, `FAIL`, `INCOMPLETE`, or `BLOCKED`), the last invocation result, Full/incremental status and timings, recovery attempts, CBT/checkpoint status, baseline/final guest file counts, payload bytes and manifest SHA-256 values, plus restore hash-match results. `payload_bytes` means guest workload data, not qcow2 bytes copied or physical storage use; PVC capacity is separate. The summary is generated from `run.json` and `report.json`, not an independent qemu-img audit. Keep `report.json` as the detailed record; see [independent CBT verification](docs/cbt/13-independent-cbt-verification.md) for raw bitmap/artifact evidence.

`run.json` is the separate lifecycle index; it stores the saved configuration, VM UID, pass counters, backup/checkpoint records, recovery attempt records, and lifecycle status. Updates are atomic; `make clean-all` marks it cleaned but retains it with the run report.

Unlike transient `state/` (the checkout operation lock), `runs/` is not deleted by `make clean-all` — it preserves each run's metadata, report, and debugging evidence. Normal output shows top-level Make stages and key progress/status; routine substeps/actions/successes are in `logs/workflow.log`, and `DEBUG=true` prints them plus detailed status snapshots. Inspect a run with `jq . runs/<run-id>/report.json` or compare two reports. Log collection is best-effort and does not collect cluster component logs.

For CBT chaos v2, the independent Analyst drafts confirmed product defects from
[`cbt-chaos/template/bug-template-v2.md`](cbt-chaos/template/bug-template-v2.md)
at `cbt-chaos/scenarios_v2/<ID>/bugs/<defect-slug>.md`, deduplicated across
attempts. Valid injection plus an observed required product violation is
necessary; root cause may be unknown. Unknown outcomes, injection failures and
harness issues belong in analysis/reports, not product bug drafts. A draft does
not create a Jira issue; never invent a Jira key or claim one was filed.

Keep each draft engineering-friendly and standalone: sanitized reproduction
preconditions/window/blast radius, measured versions and object UIDs, actual
versus expected behavior, decisive scoped evidence/timestamps, recovery and
limits, and links to independent analysis and supporting attempts. The more
detailed [`engineering-jira-issue-template.md`](cbt-chaos/template/engineering-jira-issue-template.md)
remains available for other engineering investigations; historical drafts
retain their original format.

## Known limitations

- All runs share the namespace and local/RWO storage. The checkout E2E lock prevents concurrent `make e2e` operations in one checkout; use separate repository copies for parallel operations. Staged `TYPE=incremental` commands use the per-VM lifecycle record. `make clean-all` removes every workflow-managed run in the namespace, not only the most recent one.
- The workflow depends on preview/alpha backup APIs and cluster-specific storage/feature-gate configuration.
- Debian uses small local/RWO disks, RHEL 9 uses an 80Gi root/full-backup request with 25Gi/30Gi incremental PVCs on HPP/ODF, and Windows uses a 40Gi Block-mode root plus 48Gi/30Gi ODF Filesystem backup PVCs. These are demo configurations, not production storage or disaster-recovery guidance.
- `StrictHostKeyChecking=no` is limited to the ephemeral localhost port-forward used by the demo; do not copy that SSH configuration to general remote administration.
- `make vm-cbt-restore-test` uses a privileged pod to reconstruct backups and read guest files from ext4 (Debian), XFS (RHEL 9), or NTFS (Windows). Build and push `images/restore-helper/Dockerfile` with `qemu-img`, `qemu-nbd`, `kmod`, `util-linux`, and `ntfs-3g`, set `RESTORE_HELPER_IMAGE`, and allow the privileged pod. The pod mounts the node's `/dev` and `/lib/modules`: when the `nbd` kernel module is available (or can be loaded by the pod's `modprobe`), the backup's qcow2 chain is mounted directly through `qemu-nbd`; otherwise the pod falls back to converting each image to a raw file and mounting it with `losetup`. Both paths run the identical read-only mount and hash verification.
- `sync.sh` is an operator convenience, not a deployment or release mechanism.
