# KubeVirt CBT VM backup workflow

This guide explains the repository's `make e2e` demonstration: create one VM, write a deterministic baseline file set and manifest, take one full backup, then add new files and modify one baseline file per pass before taking the configured sequential incremental backups on that same VM. The workflow verifies every checkpoint and restored workload prefix.
For the component/control-plane, network, storage, checkpoint, and failure-boundary model behind the workflow, see the [modular CBT knowledgebase](cbt/README.md), starting with [`cbt-architecture.md`](cbt-architecture.md). The [chaos-test design](cbt/10-chaos-test-design.md) page maps lifecycle boundaries to injection and verification points.

## What the demo proves

Changed Block Tracking (CBT) records changed virtual-disk blocks. The workload files cause disk changes; CBT operates on the VM disk, not on guest filenames.

The demo proves the flow end to end by checking that:

1. CBT is enabled on the VM.
2. The first `VirtualMachineBackup` completes as `Full` and records a checkpoint in a `VirtualMachineBackupTracker`.
3. The guest disk changes after that checkpoint.
4. Each configured pass completes as `Incremental` and records a checkpoint distinct from the previous one.
5. The tracker advances after every pass and ends at the final incremental checkpoint.
6. The full-only backup and each cumulative full-plus-pass prefix reconstruct the exact guest data recorded at backup time (see "Restore verification" below).
KubeVirt's CBT/incremental-backup feature (`backup.kubevirt.io/v1alpha1`) does not define a restore API; it only writes qcow2 files (a full image, then incremental overlays) to the PVC named in each backup's `spec.pvcName`. Restoring is left to backup vendors. This repo's restore test performs the reference `qemu-img rebase`/`convert` reconstruction itself so that CI can assert on real guest data rather than trusting backup/PVC status alone.

The incremental-backup feature is preview/alpha, not a GA feature. The cluster must enable the `incrementalBackup` feature gate. The VM manifest supplies the custom `cbt-demo=enabled` label; selector configuration is KubeVirt-version-dependent and is not treated as a preflight gate. `vm-setup.sh` and `vm-cbt-verify.sh` stop unless the resulting VM CBT status is `Enabled`.

Upstream background: [CBT label selectors, PR #14772](https://github.com/kubevirt/kubevirt/pull/14772), [incremental VM backups, PR #16285](https://github.com/kubevirt/kubevirt/pull/16285), and the [KubeVirt v1.8.0 release](https://github.com/kubevirt/kubevirt/releases/tag/v1.8.0).

## Prerequisites

The target server needs:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` backup APIs.
- The `IncrementalBackup` feature gate.
- The default `rhel9`/`large-odf` profile requires the cluster-provided RHEL 9 DataSource and a `Bound` source PVC in `openshift-virtualization-os-images`, plus the `ocs-storagecluster-ceph-rbd` storage class.
- Debian overrides require `cbt-demo-hpp` or an ODF storage class; the cluster's CDI importer needs outbound HTTPS to `cloud.debian.org` only for the first Debian golden-image import.
- Bash, Make, `oc`, `ssh`, `ssh-keygen`, `jq`, and a SHA-256 utility (`shasum` or `sha256sum`) for the per-run workload manifest, plus access to the local kubeconfig.
- For `make vm-cbt-restore-test` and successful `TYPE=recover`: build and push `images/restore-helper/Dockerfile` (provides `qemu-img`, `qemu-nbd`, `kmod`, and `util-linux`; Windows restore also requires `ntfs-3g`) to a registry you control, and set `RESTORE_HELPER_IMAGE` to that reference. The cluster must allow the privileged pod.

Run the scripts on a server where the kubeconfig is available. Set
`KUBECONFIG_PATH` or `KUBECONFIG` to select a kubeconfig; otherwise `oc` uses
its standard default:

```sh
make e2e KUBECONFIG_PATH=/path/to/kubeconfig
```

The configured HPP class is local/RWO demo storage. This VM is not live-migratable; the setup is for a CBT demonstration, not production storage guidance.

## Run the full workflow

```sh
make e2e
```

`e2e` runs the read-only `preflight` target first. It stops before `vm-cbt-demo` if any mandatory prerequisite fails. Run `make preflight` separately to inspect readiness.

`e2e` delegates to the same sequence as `vm-cbt-demo`:
```text
vm-setup -> vm-backup -> (vm-cbt-backup x GUEST_INCREMENTAL_PASSES) -> vm-cbt-verify
```

`make e2e NAME=foo` uses `foo` as the run ID instead of a random one; omit `NAME` to use a generated `<UTC YYYYMMDDHHMMSS>-<adjective>-<noun>-<hex tag>` ID. The fixed-width UTC prefix lets generated run directories sort by start time to one-second precision; caller-supplied IDs are unchanged.

`GUEST_INCREMENTAL_PASSES` defaults to `1`. Set it to `3` for one full backup
and three incremental backups in one `make e2e` invocation:

```sh
make e2e GUEST_INCREMENTAL_PASSES=3
```

For separate invocations, start one lifecycle and add one pass at a time:

```sh
make e2e TYPE=full VM=vm-foo GUEST_INCREMENTAL_PASSES=3
make e2e TYPE=incremental VM=vm-foo  # repeat three times
```

The staged commands use the profile saved in `runs/foo/run.json`;
the third planned pass verifies the checkpoint chain and restore prefixes.
After the lifecycle is complete, add exactly one pass to the same VM:

```sh
make e2e TYPE=extend VM=vm-foo EXTEND_TO_PASS=4
```

`EXTEND_TO_PASS` is the new total and must be the current total plus one.
The extension reuses the saved workload profile, VM, full backup, and tracker;
it creates the next pass-specific backup/PVC and verifies the full restore and
every cumulative pass prefix. Repeating a completed target adds no pass; use
the next target to extend again. File counts, size range, OS, and storage
variant remain fixed. Use `TYPE=verify` to rerun verification without adding
a pass.

### Reconciling a failed incremental pass

When an incremental pass fails (lifecycle status `incremental_failed`), the
supported retry path is:

```sh
# 1. Preserve the failed backup/PVC evidence out-of-band (YAML snapshots,
#    logs), then delete the failed pass's backup object and PVC.
# 2. Reconcile the lifecycle:
make e2e TYPE=reconcile VM=vm-foo
# 3. Retry the pass:
make e2e TYPE=incremental VM=vm-foo
```

The reconcile stage validates before touching the saved state: the failed
pass's backup and PVC must already be gone from the cluster, the tracker
must still hold the prior checkpoint (the failure advanced nothing), and the
base backup must remain `Done=True` with a non-failure reason. It records a
`reconcile_events` audit entry in `runs/<run-id>/run.json`. If any
precondition fails, it refuses with the reason — the failed state is kept
for manual inspection.

### Same-VM recovery after a failed full backup

Use the explicit recovery stage only for the managed VM whose original full backup reached terminal failure:

```sh
make e2e TYPE=recover VM=vm-<run-id>
```

The stage acquires the checkout lifecycle lock and checks the saved VM UID, VM Ready condition, VMI phase, CBT state, failed full request, retained PVC, tracker checkpoint, API schema, and candidate resource names. The live `VirtualMachineBackup` v1alpha1 schema exposes `spec.forceFullBackup` as a boolean; recovery sets it to `true` and uses the existing `VirtualMachineBackupTracker` as the source.

After all read-only checks pass, the stage creates a new PVC using the failed PVC's storage class, access mode, volume mode, and requested capacity, waits for it to become `Bound`, then creates a distinct `VirtualMachineBackup`. It uses create-only API calls; name collisions fail without overwriting existing objects. The original failed backup/PVC are never patched, deleted, or used as the recovery base. Failed recovery resources remain for diagnosis and the next attempt uses new names.

The stage records each attempt in `run.json`, `report.json`, and `summary.json`, including VM/VMI/CBT state, original failed reason/checkpoint/PVC, tracker checkpoint before and after, `forceFullBackup`, included volumes, recovery backup reason/type/checkpoint, PVC disposition, and restore checks. A recovery attempt passes only when the new request reports `Full`, `Done=True` with a non-failure reason, a new checkpoint is recorded by the tracker, the expected included volumes match, the output PVC is `Bound`, and baseline restore counts, bytes, and hashes match the original workload manifest.

The recovery verifier selects the successful recovery attempt explicitly and reconstructs only its full backup as a read-only PVC. It compares that image with the baseline manifest and does not overwrite `backups.full` or accept the failed backup's checkpoint as a restore point.

Any failed readiness/API-schema/name precondition reports `BLOCKED` without creating the recovery PVC or backup. A failed create, backup, tracker/PVC validation, or restore records a failed attempt and preserves all resources already created. `TYPE=full` remains unchanged and creates a new VM; incremental and extension workflows are unchanged.


Each step can also be run separately; see [Running individual stages](#running-individual-stages) for the target table, the argument and identity rules, and each stage's preconditions and evidence.

The `logs/workflow.log` file records UTC timestamps for numbered steps, actions, statuses, progress, successes, warnings, and failures. In normal mode, terminal output uses plain separators and all-caps phase names (`PREFLIGHT`, `VM SETUP`, `FULL BACKUP`, `INCREMENTAL BACKUP`, `VERIFICATION`), two-space-indented numbered steps, and eight-space-indented `✓` success, `⚠` warning, or `✗` failure results. Routine commands, watcher transitions, heartbeat lines, and raw condition/VMI snapshots stay out of normal console output; concise step results and important warnings/failures remain visible.
Before preflight, `make e2e` prints the effective settings as `NAME=value` pairs: type, VM OS, manifest variant, namespace, debug mode, guest file counts/size range, incremental plan, restore-helper configuration status, run ID, and VM name. It then lists resource names created by that invocation, or pass-specific patterns; resources deferred to later staged commands are labeled. Credential paths, private registry references, and secret values are omitted.

`DEBUG=true` retains timestamped commands, status/progress updates, backup-condition transitions and heartbeats, raw condition JSON, and VMI backup-status snapshots. Per-target timing lines remain in `logs/workflow.log`; the E2E result box displays total elapsed time. Full and incremental backup steps show the client-side wait duration, while the read-only monitor retains the API creation-to-Done measurement as the persisted backup timing source.
Each staged `make e2e TYPE=...` invocation prints the final result box and records a timestamped verdict in `runs/<run-id>/logs/workflow.log`. The box distinguishes `PASS`, `FAIL`, and `INCOMPLETE` and includes lifecycle progress and total elapsed time. `TYPE=full` reports the full backup as passed while marking the lifecycle incomplete and prints the next incremental command. A successful final incremental reports `PASS` only after checkpoint-chain and restore verification; a non-final incremental reports verification as pending and prints the command for the next pass.

During backup waits, normal output shows the concise completion result; `DEBUG=true` exposes observed backup-condition and PVC-state changes plus 30-second heartbeats. The Backup API exposes no copied-byte counter, so logs report phase and elapsed time rather than a percentage. `Done=True` still requires checking its reason, type, checkpoint, and tracker.

After a successful workflow with all planned incrementals complete, the automatic cluster-read-only monitor reports API-object creation-to-Done durations for the full and every planned incremental backup; these include controller/PVC work, not only QEMU's data-copy interval. It also persists `created_at`, `done_at`, `duration_seconds`, and `done_reason` under `backup_timings` in the report, VM lifecycle JSON, and a `backup-timings.json` fragment for report regeneration. `TYPE=full` and non-final `TYPE=incremental` defer automatic timing collection until the plan is complete, so the staged command exits instead of waiting for backups created by later commands. A separate live monitor started with `make monitor VM=vm-<run-id>` waits for every planned backup object to appear; run it alongside the workflow or after all planned passes are complete.

## Running individual stages

Every stage has a Make target, and all of them share one dispatcher (`scripts/stage.sh <stage>`; the dispatcher also accepts `list` and a `--dry-run` flag). `make e2e` runs preflight once up front and then invokes the same stage entry points in order with `E2E_STAGE_WRAPPED=true`, so the one-shot and staged commands execute identical code — `make e2e` is not a second implementation. `make help` lists the stages; `make stage-list` prints the same mapping as a machine-readable table.

| Target | Required args | Purpose | Produces / verifies |
|---|---|---|---|
| `make vm-setup` | `NAME=<id>` optional | Start a lifecycle: create the CBT-enabled VM and the deterministic baseline workload (`VM_OS=windows` runs the Windows setup script instead). | `runs/<run-id>/run.json`, `workload-manifest.json`, and the VM/root disk/SSH service. |
| `make vm-backup` | `RUN_ID=<id>` or `VM=vm-<id>` | Take the lifecycle's single full backup. | Full `VirtualMachineBackup` checkpoint, tracker checkpoint, and backup PVC recorded in `run.json`. |
| `make vm-cbt-backup` | `RUN_ID=<id>` or `VM=vm-<id>` | Mutate the guest workload and take the next planned incremental pass. | One incremental checkpoint and its pass record in `run.json`; verification is a separate step, so run `make vm-cbt-verify RUN_ID=<id>` after the last planned pass. |
| `make vm-cbt-extend` | `RUN_ID`/`VM` plus `EXTEND_TO_PASS=N` | Prepare exactly one extra pass on a completed lifecycle; `N` is the new total (completed total + 1, `2`–`99`). | The extension plan and an `extension-pass-NN` fragment; run `make vm-cbt-backup RUN_ID=<id>` to create the pass, then `make vm-cbt-verify RUN_ID=<id>` to verify the chain and the restores. |
| `make vm-cbt-recover` | `RUN_ID=<id>` or `VM=vm-<id>` | After a terminally failed full backup, take a new full backup on the existing VM through the saved tracker (`forceFullBackup:true`). | A recorded recovery attempt and baseline restore verification; never creates a new VM. |
| `make vm-cbt-reconcile` | `RUN_ID=<id>` or `VM=vm-<id>` | Reset a failed incremental pass (`incremental_failed`) to `incremental_ready` after its failed backup/PVC are deleted. | A `reconcile_events` audit entry in `run.json`; refuses unless the tracker still holds the prior checkpoint. |
| `make vm-cbt-verify` | `RUN_ID=<id>` or `VM=vm-<id>` | Recheck VM CBT state, backup types, completion, every checkpoint, and the restored baseline and prefixes without adding a pass. | Merged `runs/<run-id>/report.json` verification results. |
| `make vm-cbt-restore-test` | `RUN_ID=<id>` or `VM=vm-<id>` | Rebuild the guest disk from the full backup and every incremental PVC and verify each cumulative file set. | Restore checks in `report.json`; see [restore-verification.md](restore-verification.md). |
| `make monitor` | `RUN_ID=<id>` or `VM=vm-<id>` | Watch the full and every planned incremental backup and record API creation-to-`Done` timings. | `runs/<run-id>/fragments/backup-timings.json`, plus `report.json`/`run.json` `backup_timings` when present. |
| `make run-summary` | `RUN_ID=<id>` or `VM=vm-<id>`; optional stage and result (`PASS`, `FAIL`, or `INCOMPLETE`) | Regenerate the compact lifecycle summary. | `runs/<run-id>/summary.json`. |

**Identity and arguments.** `make vm-setup` starts the run — pass `NAME=<id>` (a fixed `RUN_ID=<id>` works the same way), or let it generate an ID and print it. Every later stage selects that same lifecycle with `RUN_ID=<id>` or `VM=vm-<id>` and never creates a run; the selected lifecycle must exist as `runs/<run-id>/run.json`, otherwise the stage stops and points at `make vm-setup RUN_ID=<id>`. Existing-lifecycle stages reuse the profile and workload settings saved by setup instead of re-reading the environment, which is why the staged examples above pass only `VM`/`RUN_ID`.

**Knobs.** Mutating stages (`setup`, `full`, `incremental`, `extend`, `recover`, `reconcile`) run `./preflight` before they start, and `STAGE_SKIP_PREFLIGHT=true` skips that readiness check; `verify`, `restore-test`, `monitor`, and `summary` never run preflight themselves. `STAGE_DRY_RUN=true` (or `--dry-run`) resolves the identity, prints the exact shell-quoted command, and exits without executing anything or contacting the cluster. `make e2e` sets `E2E_STAGE_WRAPPED=true`, which turns the dispatcher into a pure passthrough — no extra preflight, no hints, and the child's stdout/stderr and exit code unchanged.

```sh
make vm-setup NAME=foo            # starts run foo; prints RUN_ID=foo, VM=vm-foo
make vm-backup RUN_ID=foo         # or VM=vm-foo
make vm-cbt-backup RUN_ID=foo     # one pass; repeat for each planned pass
make vm-cbt-verify RUN_ID=foo
```

**Preconditions and evidence.** The stage scripts enforce their own preconditions; each stage writes its evidence into `runs/<run-id>/` (the [Run report](#run-report) section below lists the JSON fragment each one contributes).

- **setup** — needs no existing run and refuses a run ID whose cluster resources already exist. Creates the run directory and writes `run.json` plus `workload-manifest.json`; see [step 1](#1-make-vm-setup).
- **full** — needs the setup record and the saved workload manifest; it creates the backup PVC, tracker, and full backup, and records the full checkpoint in `run.json`; see [step 2](#2-make-vm-backup).
- **incremental** — needs the full backup, its tracker checkpoint, and the saved manifest; it adds the next planned pass only after the guest inventory matches and the new checkpoint is recorded by the tracker, and it does not run chain or restore verification itself; see [step 3](#3-make-vm-cbt-backup).
- **extend** — needs a completed lifecycle, `EXTEND_TO_PASS` equal to the completed total plus one, and the target pass's backup/PVC to be absent; it records the extension plan, updates the saved lifecycle total, and reuses the saved profile, VM, full backup, and tracker. It creates no backup: add the pass with `make vm-cbt-backup RUN_ID=<id>`, then verify with `make vm-cbt-verify RUN_ID=<id>`.
- **recover** — needs the managed VM whose original full backup failed terminally (see [Same-VM recovery after a failed full backup](#same-vm-recovery-after-a-failed-full-backup)); it records a separate attempt and never patches, deletes, or reuses the failed backup/PVC.
- **reconcile** — needs lifecycle status `incremental_failed` with the failed backup/PVC already deleted and the tracker still at the prior checkpoint (see [Reconciling a failed incremental pass](#reconciling-a-failed-incremental-pass)); it writes the `reconcile_events` audit entry.
- **verify** — needs every planned pass complete; it re-checks CBT state, types, completion, and the checkpoint chain, then merges the fragments into `report.json`; see [step 4](#4-make-vm-cbt-verify).
- **restore-test** — needs the full and every planned incremental PVC `Bound` and `RESTORE_HELPER_IMAGE` set; it rebuilds and verifies each prefix; see [step 5](#5-restore-verification-scriptsvm-cbt-restore-testsh-runs-as-step-44-of-vm-cbt-verify).
- **monitor** — needs `runs/<run-id>/run.json` and is read-only on the cluster; it waits for every planned backup, including objects created later, and writes `fragments/backup-timings.json`.
- **summary** — needs `runs/<run-id>/run.json`; it regenerates `summary.json` from `run.json` and, when present, `report.json`. It takes an optional stage name and result, which default to `all` and `INCOMPLETE`.

Every run directory carries `run.json` (resumable lifecycle index), `workload-manifest.json`, `report.json` (merged fragments), `summary.json`, the `fragments/` and `evidence/` directories, and `logs/workflow.log` with the UTC-stamped numbered-step trace and the final verdict.

## Step-by-step behavior

### 1. `make vm-setup`

`scripts/vm-setup.sh`:

1. For Debian, applies `manifests/debian-image.yaml` and waits for `DataVolume debian-golden` (namespace `vm-cbt-images`) to reach `Succeeded`. The first run imports the ~2 GiB Debian genericcloud qcow2 from `cloud.debian.org`; later runs reuse the cached image. For RHEL 9, setup reads the cluster-provided `rhel9` DataSource in `openshift-virtualization-os-images` and waits for its source PVC to be `Bound`; it does not import or modify that platform image.
2. Ensures the configured guest SSH key exists locally on the target server. Setup preserves an existing private key, derives its public half when absent, or generates a private key when none exists; the public key is inserted into Linux cloud-init user data and the private key is left at `GUEST_KEY` with mode `0600` (the default repository-local path is gitignored).
3. `TYPE=all` generates a fresh run ID (or uses the supplied `NAME`); staged `TYPE=full VM=vm-<run-id>` starts the specified lifecycle. It applies the selected VM manifest and creates the VM, root disk, and SSH service with run ownership labels.
4. Creates a root `DataVolume` from the profile's DataSource. Debian uses the selected standard size (5Gi on `cbt-demo-hpp` or 6Gi on ODF). RHEL 9 maps HPP and ODF settings to large manifests with an 80Gi root DataVolume request, sized to clone the larger platform source; CDI may expand the resulting ODF PVC request. The target disk must still be at least as large as the source PVC. The VM has one vCPU, 2 GiB memory for the small Debian profile or 4 GiB for RHEL 9, pod networking, and cloud-init SSH access for `cbt-demo`.
5. Labels the VM `cbt-demo=enabled`, waits for the VM `Ready` condition, and checks `.status.changedBlockTracking.state == Enabled`.
6. Connects through a local `oc port-forward`, creates `GUEST_BASE_FILE_COUNT` (default 8) deterministic files in `/home/cbt-demo/cbt-workload`, with each size selected reproducibly from the inclusive `GUEST_FILE_SIZE_MIN_MIB`–`GUEST_FILE_SIZE_MAX_MIB` range (defaults 4–12 MiB). It hashes every file, logs the baseline file count and payload bytes, and records the file list, sizes, and hashes in `runs/<run-id>/workload-manifest.json` before the full backup.
7. Initializes `runs/<run-id>/run.json` with the VM UID, workload/profile configuration, planned pass count, and lifecycle status. Later stages update the lifecycle fields atomically without changing the saved VM identity or configuration.

One-shot and staged commands select the same run directory. In staged use, `TYPE=incremental VM=vm-<run-id>` selects the existing lifecycle and loads its profile and workload settings from `runs/<run-id>/run.json`; it does not recreate the VM or baseline workload. `make clean-all` removes the transient checkout lock under `state/` but retains each run directory with its lifecycle status marked `cleaned`.

`guest_ssh` uses a temporary randomized local port-forward, retries VM startup,
and cleans up the port-forward when the command finishes.
### 2. `make vm-backup`

`scripts/vm-backup.sh` applies `manifests/full-backup.yaml`, which creates:

- `vm-backup-pvc-<run-id>`, a 5 GiB backup PVC.
- `vm-tracker-<run-id>`, whose source is VM `vm-<run-id>`.
- `vm-backup-<run-id>`, whose source is the tracker and whose output PVC is `vm-backup-pvc-<run-id>`.

All three are labeled with the run's ownership labels. The script waits for the `Done=True` condition and requires `.status.type == Full`. On success, it prints `.status.checkpointName`. The completed full backup also sets `vm-tracker-<run-id>.status.latestCheckpoint`.

### 3. `make vm-cbt-backup`

`scripts/vm-cbt-backup.sh`:

1. Confirms the full backup completed as `Full`.
2. Confirms the tracker still holds the latest successful checkpoint (the full checkpoint for pass 1, the preceding incremental checkpoint thereafter).
3. Adds `GUEST_INCREMENTAL_FILE_COUNT` (default 4) unique deterministic files and modifies one deterministic baseline file for the next pass; verifies the complete guest inventory against the saved manifest, then appends added and modified file hashes plus cumulative totals.
4. Creates pass-specific backup and output PVC names (`vm-incremental-<run-id>-pNN` and `vm-incremental-pvc-<run-id>-pNN`) using the same tracker.
5. Waits for `Done=True`, requires `.status.type == Incremental`, verifies the new checkpoint is distinct and recorded by the tracker, then advances lifecycle state only after success.

File names, sizes, and bytes are stable across retries. Prior files must match their latest recorded hashes; each pass deliberately rewrites one baseline file with deterministic pass-specific content. Missing files are created, and unexpected or changed unrelated files fail before the incremental backup.

`GUEST_INVENTORY_VERIFY` (default `full`) sets how much of the step-3 pre-mutation inventory is hashed: `full` re-hashes every workload file, `sample` verifies names and sizes for every file and hashes every `GUEST_INVENTORY_SAMPLE_STRIDE`-th file plus the file the pass modifies, and `skip` verifies names and sizes only. Every mode still verifies exact file names and byte sizes and still rejects missing, extra, or changed unrelated files; the modes only shorten the early drift check. The inventory recorded after the mutation (which becomes the manifest the restore test compares against) and the restore verification itself always hash every file, so the end-state guarantee is unchanged. Windows guests always use `full`. On the 1000+1000-file RHEL 9 profile, `sample` shortened the incremental phase from ~126s to ~107s.

Guest file generation, inventory hashing, and the SSH transport are batched and parallelised: new files are written concurrently (each with its own size check and atomic rename), each inventory uses one `stat` pass plus a bounded parallel `sha256sum` fan-out, and one `oc port-forward` plus one multiplexed SSH connection is reused for every guest command in a run.

**Extend a completed lifecycle.** For a completed three-pass VM, add pass four
without recreating the VM or full backup:

```sh
make e2e TYPE=extend VM=vm-foo EXTEND_TO_PASS=4
```

`EXTEND_TO_PASS` is the target total and must be exactly one greater than the
completed total. The extension reuses the saved workload profile and tracker,
creates the next pass-specific backup/PVC, then verifies the full restore and
all cumulative prefixes. Repeating the completed target creates no new pass.
File counts, size range, OS, and storage variant remain fixed.
**100/50-file run profile.** The normal defaults remain 8 baseline files, 4 incremental files, and a 4–12 MiB range. For a larger per-run payload, pass `GUEST_BASE_FILE_COUNT=100 GUEST_INCREMENTAL_FILE_COUNT=50 GUEST_FILE_SIZE_MIN_MIB=5 GUEST_FILE_SIZE_MAX_MIB=10` to `make e2e`. The deterministic filename assignment totals 739 MiB baseline and 380 MiB incremental (1,119 MiB combined). The run manifest and console output record the exact counts and payload bytes.

**Default RHEL 9 large-ODF profile.** With no overrides, `make e2e` uses the cluster-provided `rhel9` DataSource and ODF large manifests. It requests an 80Gi root/full disk and 30Gi per incremental pass. Check available ODF capacity before multi-pass runs.

**Small Debian ODF variant.** For Debian on ODF, set `VM_OS=debian MANIFEST_VARIANT=odf`. It uses the 6Gi/6Gi/4Gi manifests. The margin is required because CDI clone-time filesystem overhead can inflate the root PVC and Ceph RBD enforces PVC capacity strictly; a flat 5Gi backup target failed with `No space left on device`.

**Large-disk variant.** Setting `MANIFEST_VARIANT=large` swaps in `manifests/vm-large.yaml` (40Gi root disk), `manifests/full-backup-large.yaml` (40Gi PVC), and `manifests/incremental-backup-large.yaml` (25Gi PVC) on `cbt-demo-hpp`. `MANIFEST_VARIANT=large-odf` uses `manifests/vm-large-odf.yaml` (48Gi), `manifests/full-backup-large-odf.yaml` (48Gi), and `manifests/incremental-backup-large-odf.yaml` (30Gi) on ODF/Ceph. Those are the Debian large-profile requests. RHEL 9 resolves the selected backend's large root and full-backup requests to 80Gi; incremental PVC requests remain 25Gi on HPP or 30Gi on ODF.

By itself, a bigger disk does not widen the live block-copy window: a page-cache-absorbed copy can finish quickly regardless of PVC size. Increase the baseline/incremental file counts or size range to increase workload bytes, then measure the actual window with `scripts/monitor.sh`. The previous 64/32 MiB and 8192/12288 MiB timings came from the single-file workload and do not predict this file-set workload.

**Requested RHEL 9 large workload.** Run one full backup and three sequential incrementals with 1,000 baseline files and 500 new files per pass, each 10–15 MiB:

```sh
make e2e VM_OS=rhel9 MANIFEST_VARIANT=large-odf \
  GUEST_BASE_FILE_COUNT=1000 GUEST_INCREMENTAL_FILE_COUNT=500 \
  GUEST_INCREMENTAL_PASSES=3 \
  GUEST_FILE_SIZE_MIN_MIB=10 GUEST_FILE_SIZE_MAX_MIB=15
```

The final guest contains 2,500 workload files and 25,000–37,500 MiB
(~24.4–36.6GiB) of payload, excluding the RHEL OS and filesystem metadata.
On ODF, the root/full/three incremental PVC requests total 250Gi nominally
(80Gi + 80Gi + 3 × 30Gi), before CDI root-PVC overhead and KubeVirt
persistent-state storage. Use `MANIFEST_VARIANT=large` on HPP (235Gi nominal
requests) and confirm cluster capacity before running.

An extension adds another output PVC: 30Gi on the RHEL 9 ODF profile or 25Gi
on HPP. Thus extending the three-pass ODF profile raises nominal root/full/
incremental PVC requests from 250Gi to 280Gi, before CDI root-PVC overhead
and KubeVirt persistent-state storage.

### 4. `make vm-cbt-verify`

`scripts/vm-cbt-verify.sh` checks the API state rather than inferring success from command exit codes. It requires:

- VM CBT state `Enabled`.
- Full backup type `Full` and `Done=True`.
- Exactly `GUEST_INCREMENTAL_PASSES` pass records; each pass is type `Incremental`, `Done=True`, and matches its recorded checkpoint.
- The full checkpoint and every incremental checkpoint are non-empty and distinct from their predecessor.
- `vm-tracker-<run-id>.status.latestCheckpoint.name` equals the final incremental checkpoint.

It prints `CBT verification passed` only when every configured pass is complete and the final tracker checkpoint matches. Restore verification then proves the full-only disk and every cumulative pass prefix contain the expected file sets.

### 5. Restore verification (`scripts/vm-cbt-restore-test.sh`, runs as step 4/4 of `vm-cbt-verify`)

This is the step that actually proves the backups contain correct, restorable data, rather than only checking backup/PVC status:

The verifier waits up to 30 minutes for a terminal pod phase before failing. A timeout records the current pod phase and preserves the pod logs in the run directory; a pod that reaches `Failed` remains an immediate failure.

1. Reads and validates `runs/<run-id>/workload-manifest.json`, including the baseline, each incremental pass, and cumulative manifest hashes.
2. Confirms the full backup PVC and every pass-specific incremental PVC are `Bound`.
3. Applies the OS-appropriate restore pod with all backup PVCs mounted read-only, then:
   - Converts the full backup's qcow2 to raw and verifies the baseline file set.
   - Rebases each incremental overlay onto the preceding checkpoint, converts each cumulative state to raw, and verifies its workload prefix.
   - Mounts each raw disk's root filesystem read-only and computes a sorted manifest of the workload directory.
4. Reports restored file counts, payload bytes, and canonical manifest hashes for the full-only image and every incremental prefix.
5. Requires every restore count, byte total, and manifest hash to match the corresponding baseline or cumulative pass manifest.

The pod prints `RESTORE_MOUNT_MODE=nbd|convert` so the log shows which read path it used. Both paths mount the same read-only filesystem and compute the same manifest:

- **`nbd`** — when the node offers the `nbd` kernel module, the qcow2 chain is exposed with `qemu-nbd` and mounted directly, so no full-size raw intermediate is written. The pod mounts the node `/dev` and `/lib/modules` and runs `modprobe nbd` when the helper image provides `kmod`, so the fast path is available even when the node has not loaded the module yet.
- **`convert`** — otherwise each image is converted with `qemu-img convert` and attached with `losetup`. Conversions run one stage ahead of the verification pass that consumes them, so hashing overlaps the next conversion.

Per-image hashing uses one batched `stat` and a bounded parallel `sha256sum` fan-out instead of one process per file; the sorted records, counts, byte totals, and manifest digests are identical to the previous serial implementation.

Measured effect of the two changes together (RHEL 9, `large-odf`, 1000 baseline + 1000 incremental files of 15-20 MiB): the verification step fell from ~323s to ~77-80s on the same backups, and a complete `make e2e` from ~655s to ~394s, with every count, byte total, and manifest hash still verified. The pod logs its chosen read path (`RESTORE_MOUNT_MODE`) and the partition it mounted (`RESTORE_PARTITION_<label>`) so the evidence is visible in the run log. Guest-side hashing and generation parallelise only when the guest has more than one vCPU; the standard profile uses a single vCPU, where the batching still removes the per-file process overhead.

Any mismatch fails the step (exit 1): missing or extra files, changed contents, stale/corrupt restores, or an unapplied incremental delta. The report records every comparison; PVC status alone is not treated as proof.

## Run report

`vm-setup.sh` creates `runs/<run-id>/` and stores the VM UID and saved profile in `run.json`. Later stages append JSON fragments under `runs/<run-id>/fragments/`; the workload manifest, final report, workflow trace, diagnostic evidence, and restore artifacts stay with that run.

- `vm-setup.sh` → `setup.json`: namespace, VM profile, workload directory/range, baseline count/bytes/hash, and planned pass count.
- `vm-backup.sh` → `full-backup.json`: full backup name/type/checkpoint and output PVC request/capacity. If matching VM `backupStatus` is available, its snapshot is stored under `evidence/` and referenced from the report.
- `vm-cbt-recover.sh` → `recovery-rNNN.json`: failed full/PVC evidence, VM/VMI/CBT preconditions, `forceFullBackup` request, unique recovery backup/PVC state, tracker transition, and explicit read-only baseline restore result. Recovery attempts are separate from the initial failed full.
- Each `vm-cbt-backup.sh` invocation → `incremental-pass-NN.json`: pass number, files/bytes/hash added, modified-file count/hash, cumulative workload totals/hash, backup name/type/checkpoint, and output PVC. When the VM exposes a matching `backupStatus`, its snapshot is saved under `runs/<run-id>/evidence/` and its path is referenced from the report; otherwise the evidence path is `null`.
- `vm-cbt-verify.sh` → `verify.json`: tracker and final checkpoint plus CBT/checkpoint checks; it collects the VM's `virt-launcher` log.
- `vm-cbt-restore-test.sh` → `restore-test.json`: PVC-bound and full/prefix file-count, payload-byte, and manifest-hash checks; the restore pod log is saved alongside the report.
- `e2e-stage.sh` and standalone `vm-cbt-verify.sh` → `summary.json`: compact human-facing lifecycle/recovery verdict, last invocation, backup statuses/timings, CBT-chain result, baseline/final guest payload hashes and sizes, and restore hash-match results.

`vm-cbt-verify.sh` merges the fragments into `runs/<run-id>/report.json`, concatenates pass records and check arrays, adds `run_id`, and sets `verification.overall_passed` from all API and restore checks. Available VM backup-status snapshots are kept separately under `evidence/`; `.logs.workflow` points to the complete action trace at `logs/workflow.log`. `runs/<run-id>/run.json` is the resumable lifecycle index; `make clean-all` marks it `cleaned` while preserving the run directory and report.

`summary.json` is regenerated after each staged E2E invocation and standalone final verification. It is a compact projection of `run.json` and, when available, `report.json`, not an independent source of evidence. `verdict` describes lifecycle or recovery completion; `last_invocation.result` describes the most recent command. A Full-only stage is `INCOMPLETE` while its Full backup can still be `PASS`. A successful `TYPE=recover` passes only after the new Full backup and baseline restore are verified; a recovery attempt does not claim the original failed checkpoint as valid. `payload_bytes` is guest workload payload, not qcow2 bytes copied or physical storage usage; PVC capacity is reported separately. Use `docs/cbt/13-independent-cbt-verification.md` for the separate raw-artifact audit.

### CBT chaos v2 runtime and verdicts

Chaos orchestration does not change these lifecycle script semantics.
`cbt-chaos-team-v2` runs in main as a dispatcher/approval relay and launches one
`cbt-chaos-lead`, whose `cbt-chaos-lead-v2` skill owns the full procedure.
Lead drives the existing stages and monitoring, supported by a prepare-only
Chaos Engineer and an independent CBT Analyst. Read the executing checkout's Make
recipes, selected stage scripts, scenario entrypoint and applicable evaluator
before choosing commands; do not assume the default full-interruption evaluator
covers an arbitrary scenario or stable-system fault. Start a stage exactly once,
with condition monitoring ready before the stage opens its injection window.
After execution terminates, Lead may assign expert Analysts to distinct
bounded read-only investigation areas. Exactly one grading owner writes the
overall `analysis.json`; area specialists return cited findings and allocated
proposal paths through Lead, without competing grades or report rewrites.

Lead stays in the local/control checkout, including for remote scenarios, and
owns the final verified local report pull. Main does not execute stages,
write approval/run records or grade evidence. Nested delegation requires
asynchronous task dispatch, parent/child messaging and depth of at least two;
missing runtime capabilities block rather than transfer execution to main.

Lead sends main an `approval_request` with a unique request ID, its agent and
scenario IDs, exact non-secret package and fingerprint. The package includes
all file hashes, commands, parameters, execution target, window, scope,
blast radius and rollback. SHA-256 covers canonical UTF-8 JSON from
`jq -cS .`, including its final newline. Main verifies the fingerprint, presents
the unchanged package using structured `ask`, and returns `approval_response`
with matching IDs/fingerprint, explicit user answer/decision and UTC timestamp.
Lead records that consent and rechecks the package before execution. Missing,
stale, mismatched or rejected approval never authorizes execution; changed
packages require a fresh question. Clarification responses are not approvals.
The relay is a workflow guard, not a security boundary for Bash-capable agents.
When its own jobs have finished, Lead returns an interim `approval_pending` or
`clarification_pending` result containing the outstanding request. Main relays
the question and resumes the same idle/parked Lead through messaging. Pending
is not completion; do not poll or keep a dummy process alive to await main.

The scenario-local canonical root is `cbt-chaos/scenarios_v2/<ID>/`: the
specification and Jira conditions, reusable `run.sh`, optional injection,
condition/effect helpers (names unrestricted), and local `approval.json`.
Approval binds the entrypoint, all invoked local scripts/configurations,
specification/Jira conditions, effective blast radius/window and run parameters.
Record explicit approval plus hashes and verify them immediately before
execution. An unchanged approved bundle may rerun; no mid-run edits are allowed.
After INVALID from an injection defect, only one prepare-only repair is allowed,
followed by fresh approval and a fresh attempt, never a silent retry.

Each attempt writes `runs/<attempt-id>/` **inside that scenario**, with one
canonical `run.json` holding phase, verdict, identities, attempt/retry relation,
timestamps, paths and execution/report statuses; `injection-confirmation.json`;
independent `analysis.json`; the Lead's `run-report.md`; and raw captures/logs.
No additional verdict file, ledger or index is required. Reference repository
`runs/<lifecycle-id>/{run.json,report.json,summary.json,...}` in place rather than
copying it or confusing the two `run.json` records.

Generate every new chaos attempt ID with
`cbt-chaos/run-id.sh <exact-vm-name> <note-slug> <iteration>`:
`<dd-mm-yyyy-hh-mm-ss>-<vm_name>-<note>-iteration-<number>`, using current UTC.
The Lead resolves the existing VM or preselects a new lifecycle ID and resolves
its planned VM name before generation. Iteration is the next positive number
after the highest recorded scenario `iteration`, including repaired attempts;
`attempt` (1 or 2) still tracks the request's one-repair policy. Record iteration,
VM and note in scenario `run.json`. Keep short lifecycle IDs unchanged and
separate from the chaos ID; never forward the latter to Make as `RUN_ID`.
Historical evidence keeps its original IDs.

Capture the observed condition before action, exact target UID before/after,
timestamps, effect and exclusions. Scenario-specific machine effect checks must
fail closed; sleeps or the injection tool's exit status alone are not proof.
The independent Analyst reads raw evidence rather than accepting the author's
self-certification. Scope logs by run/object UID and time; CR type alone does
not establish physical full/incremental behavior.

Before freezing criteria or accepting an existing bundle, the Lead or assigned
Engineer reviews relevant known scenario/component failure families, including
scenario-local and existing `artifacts/<ID>/bugs/` drafts. The preparation
handoff maps sources to evidenced risks/uncertainties and observation surfaces;
no matches/unavailable sources are explicit. History seeds neutral proposed
coverage, not an expected verdict or root cause. The Analyst still grades
current raw evidence before reading historical bugs for deduplication.

The same handoff declares applicable recovery layers, resource identities,
expected postconditions, baseline/final probes, owner and approved observation
bounds. API/control-plane state, actual guest/workload state and host/storage
release have independent CLEAR / RESIDUAL / UNKNOWN observations; not-applicable
layers require a reason. Backup cleanup correlates PVC UID → PV → CSI handle/
image → node attachment/pins and exact mount/device identity when applicable.
`Done=True`, VM readiness or disappearance from VMI status cannot substitute
for lower-layer release; failed/unavailable probes are UNKNOWN, not absence.

Bounded, approved, read-only final collection must survive harness aborts and
failed stages, retaining operation/collection statuses separately. Early
blockers do not authorize guessed-resource queries. The Analyst audits
surviving ownership and follows relevant EBUSY/hotplug/unmount/attach warnings
through the affected layer even when API conditions clear. The Lead limits
recovery claims to observed layers, distinguishes test bounds from documented
product SLAs, and separates recurrence from causal attribution. These checks
use the existing handoff, analysis and report, not additional agents/ledgers.
New control executions, inspectors, repair or expanded probe scope still need
approval; historical evidence never retroactively changes acceptance criteria.

| Chaos verdict | Required meaning |
|---|---|
| BLOCKED | Prerequisites prevented injection. |
| INVALID | Injection is unproven, or target, window or blast radius was wrong. |
| FAIL | Injection is confirmed valid and a required product violation was observed; root cause may be unknown. |
| INCONCLUSIVE | Injection is confirmed valid but mandatory product evidence is missing. |
| PASS | Every mandatory scenario requirement is proven. |

The lifecycle `summary.json` verdict is not the chaos verdict. For example,
an intentionally interrupted backup may return nonzero or leave a lifecycle
incomplete while meeting the scenario's expected disruption behavior. Preserve
deterministic failed/unknown results and map them to the actual mandatory
criteria; never replace unknown evidence with narrative PASS.

For [CBT-F-05](../cbt-chaos/scenarios_v2/CBT-F-05/scenario-spec.md), the
launcher supplies the active-copy signal; the fault target is the exact
node-local handler, not that launcher. The bundle owns separate setup/full
stages and arms native krkn and a read-only cleanup observer before full. The
observer follows only the original PVC UID → PV → CSI handle/image, VMI/pod
references, matching VolumeAttachment/node pin, actual guest disks/QMP and the
exact original-launcher hotplug mount in the existing node-local handler.
It samples at terminal through a fixed 300-second test observation window
(not a historic product SLA). API detach alone is insufficient; unreadable
probes are UNKNOWN, not detached. Residual/UNKNOWN state stops before restore
or destination reuse, preserving every old and new resource. With safe cleanup
and consistent terminal/checkpoint/volume operands, a successful original full
selects one incremental plus chain/restore verification; a clear failed original
selects one distinct same-VM recovery full plus baseline restore. No duplicate
restore, generic evaluator fallback, separate clean lifecycle or forced cleanup
is used. The terminal failure classifier is the shared workflow predicate,
not a literal success prefix. Guest-key approval supports existing-pair and
setup-managed modes; preflight never creates keys.

The Lead closes and reports **every** terminal attempt, including INVALID and
BLOCKED, before any optional repaired retry, and updates scenario-root
`consolidated-report.md` with all attempts and separate verdict counts. The
Analyst writes one `bugs/<defect-slug>.md` per confirmed product defect across
attempts, not bugs for unknown outcomes, injection or harness issues. Reports
cover injection validity, criteria/unknowns, scoped investigation, recovery and
limits, approved bundle references, and bug/proposal links.

After **every terminal remote attempt**, including BLOCKED, INVALID and partial
attempts, the Lead MUST complete a verified report pull from the **local/control
checkout**, after remote analyses, bugs, run/consolidated reports and proposals
are final and before any repaired retry. Repeat after any subsequent remote
report, diagnosis or proposal update. If execution was already local, no SSH
pull is needed. `make sync` is a source push, not a substitute; do not run the
pull inside the remote checkout.

```sh
# Run in the local/control checkout, not via SSH in the remote checkout.
make pull-reports SCENARIO=CBT-F-05 REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout
# Omit SCENARIO (including any environment/.env value) for all reports.
make pull-reports REMOTE_HOST=example-host REMOTE_DIR=/path/to/checkout
```

The unfiltered pull includes **all** repository-root `runs/**`. Scoped pulling
includes the chosen scenario's `bugs/**`, `runs/**`, `consolidated-report.md`
and `approval.json`, its `artifacts/<ID>/**`, and only root lifecycle directories
referenced by `.lifecycle_ids` / `.lifecycle_id` in direct attempt `run.json`
and `analysis.json`. Missing lifecycle directories are reported, not invented.
Both modes include exact repository-relative proposal Jira paths referenced by
attempt `.proposed_scenarios`; unfiltered mode also includes standalone
Jira drafts with an explicit `PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW`
status line, not ordinary scenario source Jira/spec files or body mentions.
All files retain their repository-relative local paths; existing source
scripts/specs/agents are untouched.

Pulling needs local SSH/rsync/Python3 and remote Python3, not a cluster preflight
or kubeconfig. It is remote-read-only, streams the inventory helper without
installing it, and leaves remote evidence canonical. Full SHA-256 comparison
selects changed content; verification covers every selected local file and a
second remote inventory must prove selection/content remained stable.
Checksum, source-stability, unsafe-path/metadata and transfer failures are not
success or a reason to silently retry/broaden scope. Every replaced local file
is preserved in `artifacts/sync-backups/<UTC-unique>/`; no `--delete`, local-only
draft removal, archive, regrade or new execution is implied. Credential
filenames/directories and disk images are excluded; symlinks are not followed.
Filename filtering is not embedded-log redaction: sanitize evidence before
transfer. See [Synchronization helper](../README.md#synchronization-helper)
for complete selection, exclusion and failure rules.

The final user summary MUST record successful local report/evidence/proposal
paths and the verified pull outcome. If transfer or verification fails, preserve
remote evidence and explicitly report **local synchronization incomplete** with
the failure; do not claim the local reports are complete.

The grading owner or an assigned area specialist may create a follow-up
`scenarios_v2/<new-ID>/jira-issue.md` after Lead checks duplicates and allocates
the exact unused ID/path. Mark it **PROPOSED — UNEXECUTED — PENDING HUMAN
REVIEW**, cite originating evidence/author area, separate observation from
hypothesis and describe objective, target/window, verification, scope/risks
and unknown prerequisites. This is a saved proposal document, not executable
scope or approval. No extra human approval is needed merely to save the
Lead-allocated draft; actual test execution needs its own approval.

Before closure, the Lead verifies every specialist-created draft exists and
records it in the Lead-owned attempt `run.json.proposed_scenarios` array as a
repository-relative string, for example
`cbt-chaos/scenarios_v2/CBT-F-99/jira-issue.md` (use the actually allocated ID).
Include grading-owner and area-specialist drafts; record `[]` if none. This
metadata lets scoped pulling retrieve each exact document; a claimed-created
but missing draft fails the pull. The Lead MUST NOT modify `analysis.json` to
add proposal links; that file remains solely the grading owner's.

The final user summary and run/consolidated reports list every created ID,
short purpose, actual file path, evidence and review status, including area
specialist drafts. Do not claim unwritten suggestions as created scenarios.
Leave drafts for human review/revision or manual deletion; never automatically
delete, prune or archive them. Generic lessons remain Lead-owned in its skill's
`improvement.md` (1–3 lines per deduplicated lesson).
V2 reports, bugs and drafts stay with scenarios, not `artifacts/`; raw captures
and approval are local/gitignored. Archiving is optional and explicit, never an
automatic v2 closure step. Do not move or regrade historical/legacy evidence.

## Resources and names

All workflow objects live in the shared, globally configured `$NAMESPACE` (default `vm-cbt-demo`, set in `.env`). `TYPE=all` or `TYPE=full` starts a lifecycle with a random run ID by default, or the fixed ID from `NAME`/`VM`; `TYPE=incremental`, `TYPE=recover`, and `TYPE=verify` load that existing lifecycle by `VM=vm-<run-id>`. `make e2e-incremental VM=vm-<run-id>` is the semantic alias for `TYPE=incremental`. Resource names derive from the run ID, so different runs coexist without collisions:

| Resource | Name | Purpose |
|---|---|---|
| VirtualMachine | `vm-<run-id>` | Debian or RHEL 9 guest with CBT label |
| DataVolume/PVC | `vm-disk-<run-id>` | Persistent VM root disk |
| Service | `vm-ssh-<run-id>` | Guest SSH access for the scripts |
| VirtualMachineBackupTracker | `vm-tracker-<run-id>` | Stores the base/latest checkpoint |
| VirtualMachineBackup | `vm-backup-<run-id>` | Initial full backup |
| PVC | `vm-backup-pvc-<run-id>` | Full backup output |
| VirtualMachineBackup | `vm-recovery-full-<run-id>-rNNN` | Independent same-VM Full recovery attempt using the existing tracker |
| PVC | `vm-recovery-pvc-<run-id>-rNNN` | Recovery full output; retained with its attempt |
| VirtualMachineBackup | `vm-incremental-<run-id>-pNN` | Pass-specific backup based on the preceding tracker checkpoint |
| PVC | `vm-incremental-pvc-<run-id>-pNN` | Retained output PVC for that pass |
| Pod (short-lived) | `vm-restore-verify-<run-id>` | Reconstructs and reads the guest disk during `vm-cbt-restore-test` |

Every resource above is labeled `app.kubernetes.io/managed-by=virt-cbt-lab` and `virt-cbt-lab/run-id=<run-id>`; those labels, not the namespace, are the ownership mechanism `clean-all` uses. The VM UID, lifecycle state, workload manifest, report, and evidence live under `runs/<run-id>/`; incremental backup and PVC names use `p01`, `p02`, … suffixes. `make clean-all` reclaims every pass PVC; until cleanup, provisioned backup storage grows with the pass count.

The Debian golden image (`DataVolume`/`DataSource` `debian-golden`/`debian`) lives in namespace `vm-cbt-images`, deliberately outside `$NAMESPACE`, so it survives `make clean-all` and is downloaded only once. RHEL 9 uses the cluster-managed `rhel9` DataSource in `openshift-virtualization-os-images`; the workflow waits for its backing PVC and leaves it unchanged.

## Repeated runs without cleanup

```sh
make e2e
make e2e
make e2e
```

Each `TYPE=full` invocation creates one VM and full checkpoint; each `TYPE=incremental` invocation adds exactly one pass using that VM's saved state. Commands must run sequentially within a checkout. The E2E lock prevents concurrent lifecycle commands from cross-wiring state, and `runs/<run-id>/run.json` keeps each staged lifecycle attached to its VM identity and report. Run `make clean-all` any time to remove every run's resources from the namespace.

## Density VM pools and `EXISTING_VM` adoption

`make density-setup VM_OS=rhel9|windows DENSITY_VM_COUNT=N [POOL=<id>]` creates a pool of bare, CBT-enabled VMs with kube-burner (only kube-burner 2.1.1-compatible features are used). Pool VM run IDs are fixed: `<pool>-NNNN` (1-based, zero-padded to 4), so `vm-<pool>-NNNN`, `vm-disk-<pool>-NNNN`, and `vm-ssh-<pool>-NNNN` match exactly what `set_resource_names` derives and every downstream script works unchanged. RHEL pools clone the cluster `rhel9` DataSource with the selected `MANIFEST_VARIANT` storage class and size; Windows pools clone `windows-server-2022` with the fixed 40Gi Block disk and share one pool-scoped OOBE Secret `windows-oobe-<pool>` built by `scripts/windows-oobe-secret.sh`.

The pool is metadata-light: no `runs/<id>/` exists until adoption, and no baseline workload, tracker, or backups are created by density-setup. There is no local pool metadata at all — the cluster carries the truth: VMs are labeled `virt-cbt-lab/pool=<pool>` (plus the standard managed-by/run-id labels) and annotated with `virt-cbt-lab/os-profile`, `virt-cbt-lab/manifest-variant`, and `virt-cbt-lab/incremental-passes`. A pool exists exactly while at least one of its VMs exists; `POOL` defaults to an OS-prefixed timestamp (`rhel-<MMDDhhmmss>` / `win-<MMDDhhmmss>`), and a `POOL` name that already has VMs in the namespace is refused. kube-burner creates objects without waiting (`wait: false`, `waitWhenFinished: false`, `cleanup: false`, `namespacedIterations: false`); `scripts/density-setup.sh` itself polls the cluster until every VM reports `.status.ready==true`, bounded by `DENSITY_WAIT_MINUTES` (default 240). A failed or

Adopt one pool VM into the normal lifecycle with `make e2e EXISTING_VM=vm-<pool>-NNNN` (`TYPE=all` or `TYPE=full` only; it cannot be combined with `VM`/`NAME`, and later stages use the ordinary `TYPE=incremental VM=vm-<pool>-NNNN` interface). Resolution happens in two places with the same rules: `scripts/e2e-stage.sh resolve_existing_vm` reads the VM, checks the three labels, then lets the pool annotations override `VM_OS`, `MANIFEST_VARIANT`, and `GUEST_INCREMENTAL_PASSES` from the environment (pool wins so the pipeline summary and density-status always agree); `scripts/common.sh adopt_existing_run_id` then re-checks the labels, creates `runs/<pool>-NNNN/`, and skips steps 1–3 of `vm-setup`/`windows-vm-setup` (image source, key/OOBE secret, VM+DV+Service creation). Steps 4–5 run unchanged: wait for readiness/CBT, write the baseline workload (the guest's workload directory must be empty), and initialize `run.json` with the VM's real UID. If adoption fails after `initialize_run_directory`, the leftover `runs/` directory blocks re-adoption; the error message explains the `TYPE=incremental` alternative.

RHEL adoption requires the same checkout that created the pool: density-setup injects `$GUEST_KEY`'s public half via cloud-init, and the adopted run's guest SSH uses the private half. Windows adoption skips the password-file requirement in preflight (the OOBE Secret already exists), but the pool must have been created with `WINDOWS_ADMIN_PASSWORD_FILE` readable at density-setup time.

`make density-status` is read-only and takes no lock. Without `POOL` it prints a fleet view: every managed VM in the namespace, grouped by pool, each group with its funnel (`TOTAL`, `CREATING`, `CREATED`, `FULL`, `INC1..INCn` counts) and one row per existing VM (`ready|creating`, plus per-backup state: `-` absent, `running` Done not True yet, `failed` Done True with a `Backup has failed` reason, `done` otherwise — the same terminal-failure semantics as `backup_done_reason_is_failure`). VMs created outside any pool (e.g. by `make e2e`) appear in a final `no pool` group; because state is read live, deleted or never-created VMs simply do not appear, and an empty namespace prints an informational message and exits 0. `POOL=<id>` restricts the output to one pool. `density-setup` does not take the e2e checkout lock (VM creation can take hours); `clean-all` refuses only while an e2e holds it — deleting pool resources requires the label-scoped `oc delete` in README's density section.

`ready` (and the `CREATED` funnel count) is VM-object-level: `.status.ready==true` means the DataVolume clone finished, the VMI was scheduled, and the domain started. It does not guarantee guest-OS boot completion or SSH reachability; for RHEL 9 cloud-init VMs those usually follow within seconds to a minute. This is intentional — the readiness criterion in `density-setup`'s poll and in `density-status` is the same field, so the two can never disagree. Guest-level usability is verified at adoption instead: `vm-setup.sh` step 4 re-waits on `status.ready` (20m timeout), asserts the VM's CBT state is `Enabled`, and step 5 performs a real guest SSH login to write and hash the baseline workload; a VM that is not actually usable fails loudly at adoption, not silently. For Windows, OOBE completion and QEMU Guest Agent connection (`AgentConnected`) are likewise awaited by adoption steps 4–5, not by density-status.

## Cleanup

```sh
make clean-all
```

`scripts/clean-all.sh` does **not** delete the namespace. It deletes run-labeled VMs, DataVolumes, backups, trackers, PVCs, services, pods, and Windows OOBE Secrets from `$NAMESPACE`, waits for managed PV reclamation, removes only the workflow-owned guest SSH key, and clears the transient `state/` lock. It marks lifecycle records under `runs/` as `cleaned`; those records, per-run reports, and shared golden images remain. Unrelated namespace resources are preserved.

## RHEL 9 VM setup and CBT profile

Run `make e2e VM_OS=rhel9` to use the cluster-provided `rhel9` DataSource. Preflight requires that DataSource and its source PVC to exist and be `Bound`; no local ISO or image import is needed. The Linux guest setup uses the `wheel` group and `sshd` service, while workload creation, SSH operations, incremental backups, and restore verification use the shared Linux path. The restored RHEL 9 root filesystem is XFS.

For `MANIFEST_VARIANT=default` or `large`, RHEL 9 uses the 80Gi HPP root DataVolume/full-backup requests and 25Gi incremental PVCs. For `odf` or `large-odf`, it uses the 80Gi ODF root DataVolume/full-backup requests and 30Gi incremental PVCs. The larger root disk is required because the platform RHEL 9 source PVC does not fit the small Debian disk sizing; a source PVC larger than the selected root disk still cannot be cloned.

### RHEL 9 storage footprint

Historical reference measurement from a successful RHEL 9 E2E run on 2026-10-05, before the current 80Gi request. The configured `odf` variant resolved to `large-odf`.

The measurements below are for the prior 48Gi profile and one incremental
pass; they are not a capacity estimate for the current 80Gi, three-pass run.

| PVC/resource | Declared request | Observed PVC request | Reported capacity |
|---|---:|---:|---:|
| VM root disk | 48Gi DataVolume | 54,631,984,006 bytes (~50.88Gi) | 51Gi |
| Full backup | 48Gi | 48Gi | 48Gi |
| Incremental backup | 30Gi | 30Gi | 30Gi |
| KubeVirt persistent-state | KubeVirt-generated | 580,198,073 bytes (~0.54Gi) | 1489Gi (HPP backing PV) |
| Restore verification | None | No additional PVC | — |

For that measured one-increment run, the three workflow PVCs requested
128.88Gi total and reported 129Gi combined capacity. CDI filesystem-overhead
reservation increased the root claim beyond the DataVolume's 48Gi request.
KubeVirt's persistent-state PVC added ~0.54Gi of requested storage, making
the measured per-run PVC request total ~129.42Gi; round that historical
planning budget up to 130Gi. The nominal root/full/incremental manifest
requests sum to 126Gi and omit both overhead and persistent state. Do not
count the persistent-state PVC's 1489Gi HPP status capacity as per-run
consumption; HPP reports the backing-PV capacity.

The platform `rhel9` DataSource uses a shared source PVC. In this measurement,
that pre-existing PVC requested 34,144,990,004 bytes (~31.8Gi) and reported
1489Gi capacity on HPP. It is not recreated for each run and is excluded from
the per-run total; its reported capacity is the backing-PV capacity, not
per-run data consumption.

Restore verification creates no additional PVC. It mounts the full and
incremental backup PVCs read-only, uses an `emptyDir` for reconstruction
scratch, and mounts host `/dev` for loop devices. The scratch volume is
ephemeral storage, has no `sizeLimit` in the current manifest, and is not
included in the PVC total; peak scratch usage is not recorded by the run report.
The measured restore passed with 8 baseline and 12 combined guest files.

## Windows VM setup and CBT profile

Run `make windows-vm-setup` first to provision one Windows Server 2022 VM and initialize its CBT workload under `C:\cbt-data\workload` through QEMU Guest Agent. If `windows-server-2022` is not cached, setup installs Windows from the Evaluation ISO, installs Python 3.12.4 and the file-writer/SQLite-writer/HTTP-server workloads, registers their SYSTEM startup task, verifies them, removes generated test data, syspreps the disk, and publishes the reusable DataSource in `vm-cbt-images`. The runtime clone is then checked for startup workload continuity before the CBT file set is initialized. This is separate from the Debian default and does not require SSH access to Windows.

`WINDOWS_ADMIN_PASSWORD_FILE` must point to a readable, gitignored password
file on the execution host for the one-time image build and every runtime
clone; each clone uses it to create a run-scoped OOBE Secret.

After the single-VM setup is validated, run `make e2e VM_OS=windows NAME=windows-cbt-1` for the full Windows CBT workflow. It reuses the existing generic full-backup, tracker, incremental-backup, report, and verification stages; Windows-specific logic covers OOBE, guest mutation, and NTFS restore inspection. The Windows profile requires the ODF virtualization Block class for VM disks and the ODF Filesystem class for backup PVCs. Follow [`docs/windows-server-2022-setup-runbook.md`](windows-server-2022-setup-runbook.md) for the end-to-end setup procedure; this document remains the exact repository workflow reference.
- The Windows VM template sets `evictionStrategy: None` for this demo. A migration during a QEMU Guest Agent command can invalidate the guest-exec process handle; runtime setup probes the agent socket and retries the startup workload verification once after a transient guest-agent failure.

## Troubleshooting signals

- Guest SSH retries indicate that the VM service or guest SSH daemon is not ready; inspect the local `oc port-forward` log and VM readiness.

- `CBT is not enabled ...`: verify the cluster feature gate and that the VM has label `cbt-demo=enabled`.
- Debian golden-image import stuck or failing: check `oc get dv debian-golden -n vm-cbt-images` and its importer pod logs; confirm cluster CDI importers can reach `cloud.debian.org`. Force a re-import with `oc delete namespace vm-cbt-images`.
- RHEL 9 DataSource missing or not ready: check `oc get datasource rhel9 -n openshift-virtualization-os-images` and the referenced PVC's phase; preflight reports either condition before creating demo resources.
- PVC remains pending: verify `cbt-demo-hpp` is available and can provision local demo volumes.
- `vm-incremental-<run-id>-pNN` already exists: the selected pass-specific backup name conflicts with an existing resource. Check `next_incremental_pass` in `runs/<run-id>/run.json`; do not reuse a completed pass name.
- Incremental type is not `Incremental`: check that the full checkpoint reached the tracker and inspect the `VirtualMachineBackup` conditions and tracker status.
