# KubeVirt CBT VM backup workflow

This guide explains the repository's `make e2e` demonstration: create a VM, write and hash `hello.txt`, take a full backup, append data, take an incremental backup, and verify the CBT result.
For the component/control-plane, network, storage, checkpoint, and failure-boundary model behind the workflow, see the [modular CBT knowledgebase](cbt/README.md), starting with [`cbt-architecture.md`](cbt-architecture.md). The [chaos-test design](cbt/10-chaos-test-design.md) page maps lifecycle boundaries to injection and verification points.

## What the demo proves

Changed Block Tracking (CBT) records changed virtual-disk blocks. The guest file is the workload used to cause a disk change; CBT operates on the VM disk, not on `hello.txt` by name.

The demo proves the flow end to end by checking that:

1. CBT is enabled on the VM.
2. The first `VirtualMachineBackup` completes as `Full` and records a checkpoint in a `VirtualMachineBackupTracker`.
3. The guest disk changes after that checkpoint.
4. A second backup completes as `Incremental`, with a different checkpoint.
5. The tracker advances to the incremental checkpoint.
6. The full backup, and the full backup rebased with the incremental, actually reconstruct into a disk containing the exact guest data recorded at backup time (see "Restore verification" below).

KubeVirt's CBT/incremental-backup feature (`backup.kubevirt.io/v1alpha1`) does not define a restore API; it only writes qcow2 files (a full image, then incremental overlays) to the PVC named in each backup's `spec.pvcName`. Restoring is left to backup vendors. This repo's restore test performs the reference `qemu-img rebase`/`convert` reconstruction itself so that CI can assert on real guest data rather than trusting backup/PVC status alone.

The incremental-backup feature is preview/alpha, not a GA feature. The cluster must enable the `incrementalBackup` feature gate. The VM manifest supplies the custom `cbt-demo=enabled` label; selector configuration is KubeVirt-version-dependent and is not treated as a preflight gate. `vm-setup.sh` and `vm-cbt-verify.sh` stop unless the resulting VM CBT status is `Enabled`.

Upstream background: [CBT label selectors, PR #14772](https://github.com/kubevirt/kubevirt/pull/14772), [incremental VM backups, PR #16285](https://github.com/kubevirt/kubevirt/pull/16285), and the [KubeVirt v1.8.0 release](https://github.com/kubevirt/kubevirt/releases/tag/v1.8.0).

## Prerequisites

The target server needs:

- OpenShift Virtualization/KubeVirt with the `backup.kubevirt.io/v1alpha1` backup APIs.
- The `IncrementalBackup` feature gate.
- The `ocs-storagecluster-ceph-rbd` virtualization storage class for the default `MANIFEST_VARIANT=odf` (see `docs/odf-setup-plan.md`), or `cbt-demo-hpp` with `MANIFEST_VARIANT=default`/`large`.
- Outbound HTTPS access from the cluster's CDI importer to `cloud.debian.org`, so `vm-setup.sh` can import the Debian golden image into `vm-cbt-images` the first time it runs.
- Bash, Make, `oc`, `ssh`, `ssh-keygen`, `jq` (builds/merges the per-run JSON report), and access to the local kubeconfig.
- For `make vm-cbt-restore-test`: build and push `images/restore-helper/Dockerfile` (provides `qemu-img` and `util-linux`; Windows restore also requires `ntfs-3g`) to a registry you control, and set `RESTORE_HELPER_IMAGE` to that reference. The cluster must allow the privileged pod this step runs.

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
vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```

`make e2e NAME=foo` uses `foo` as the run ID instead of a random one, for a deterministic, repeatable run name; omit `NAME` to keep the default random `<adjective>-<noun>-<hex tag>` scheme.

Each step can also be run separately:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
```

The scripts emit concise structured progress messages to stderr: numbered workflow steps, `→` action descriptions, `✓` success messages, and an active-step failure message before the original command diagnostic. Make-level headers show the four demo stages; raw shell tracing is intentionally not enabled.

## Step-by-step behavior

### 1. `make vm-setup`

`scripts/vm-setup.sh`:

1. Applies `manifests/debian-image.yaml` and waits for `DataVolume debian-golden` (namespace `vm-cbt-images`) to reach `Succeeded`. The first run imports the ~2 GiB Debian genericcloud qcow2 from `cloud.debian.org`; later runs see it already `Succeeded` and return immediately, since `vm-cbt-images` lives outside `clean-all`'s scope.
2. Ensures a dedicated guest SSH key exists locally on the target server. The public key is inserted into the cloud-init user data; the private key stays at `GUEST_KEY` with mode `0600` (by default, repository-local `keys/id_ed25519`, which is gitignored).
3. Generates a fresh run ID (`<adjective>-<noun>-<hex tag>`, e.g. `dark-forest-80d7`) and persists it to `state/run-id`, then applies `manifests/vm.yaml`, which creates namespace `$NAMESPACE` (if missing) and the run's VM (`vm-<run-id>`) and SSH service (`vm-ssh-<run-id>`), each labeled `app.kubernetes.io/managed-by=virt-cbt-lab` and `virt-cbt-lab/run-id=<run-id>`.
4. Creates a root `DataVolume` from the `debian` `DataSource` — 6 GiB on `ocs-storagecluster-ceph-rbd` for the default `MANIFEST_VARIANT=odf`, or 5 GiB on `cbt-demo-hpp` under `MANIFEST_VARIANT=default`. This must stay larger than the golden image's size; a target smaller than the source fails the clone. The VM has one vCPU, 2 GiB memory, pod networking, and cloud-init SSH access for `cbt-demo`. The golden image itself (`manifests/debian-image.yaml`) always stays on `cbt-demo-hpp` regardless of variant; CDI clones across StorageClasses without issue.
5. Labels the VM `cbt-demo=enabled`, waits for the VM `Ready` condition, and checks `.status.changedBlockTracking.state == Enabled`.
6. Connects through a local `oc port-forward`, writes `Hello from the VM CBT demo.` followed by a `GUEST_DATA_SIZE_MB` (default 64) MiB random payload to `/home/cbt-demo/hello.txt`, prints its SHA-256 hash, and records that hash to `state/full-backup.sha256` (this is the content the full backup will contain, since no guest mutation happens before `make vm-backup` runs). The larger payload gives CBT a realistic block delta to track rather than a single text line.

All later steps (`vm-backup`, `vm-cbt-backup`, `vm-cbt-verify`) read the run ID back from `state/run-id` rather than generating a new one, so they operate on the same run's resources. Deleting or overwriting `state/run-id` between steps of one E2E run breaks the chain; `make clean-all` removes it along with the rest of the local run state.

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
2. Waits for the tracker checkpoint to match the full backup checkpoint. This avoids starting the next backup before the base checkpoint is recorded.
3. Appends a `GUEST_INCREMENTAL_DATA_SIZE_MB` (default 32) MiB random payload followed by `This line was added after the full backup.` to `hello.txt` if that exact line is not already present, prints the new SHA-256 hash, and records it to `state/incremental-backup.sha256` (the content the full+incremental restore must reproduce).
4. Applies `manifests/incremental-backup.yaml`, creating the `vm-incremental-pvc-<run-id>` PVC (3 GiB, sized for the delta only) and `vm-incremental-<run-id>` backup, both labeled with the run's ownership labels. Its source is the same tracker, so KubeVirt can use the tracker's checkpoint as the incremental base.
5. Waits for `Done=True`, requires `.status.type == Incremental`, and prints the new checkpoint.

The append is idempotent for retries: the same line is not appended twice.

**ODF-backed variant (default).** `make e2e` defaults to `MANIFEST_VARIANT=odf` (see `.env.example`), which uses `manifests/vm-odf.yaml`, `manifests/full-backup-odf.yaml`, and `manifests/incremental-backup-odf.yaml` — same structure as the plain manifests apart from `storageClassName: ocs-storagecluster-ceph-rbd` instead of `cbt-demo-hpp`, and larger PVC sizing (6Gi/6Gi/4Gi vs. the plain 5Gi/5Gi/3Gi). The larger sizing was found necessary by running `make e2e MANIFEST_VARIANT=odf` against the target ODF cluster: CDI's clone-time filesystem-overhead reservation inflates the root disk past the nominal 5Gi, and Ceph RBD enforces PVC capacity strictly (unlike `cbt-demo-hpp`, which silently tolerates the same overcommit), so a flat 5Gi backup-target PVC failed the full backup with `Backup has failed: No space left on device`. Requires ODF/Ceph deployed on the cluster first (see `docs/odf-setup-plan.md`); it does not affect the golden image cache, which stays on `cbt-demo-hpp` regardless of variant. Set `MANIFEST_VARIANT=default` to fall back to plain `cbt-demo-hpp` manifests on clusters without ODF.

**Large-disk variant.** Setting `MANIFEST_VARIANT=large` swaps in `manifests/vm-large.yaml` (40Gi root disk), `manifests/full-backup-large.yaml` (40Gi PVC), and `manifests/incremental-backup-large.yaml` (25Gi PVC) on `cbt-demo-hpp`, structurally identical to the plain manifests apart from sizes. `MANIFEST_VARIANT=large-odf` gives the same sizing intent on ODF/Ceph — `manifests/vm-large-odf.yaml` (48Gi), `manifests/full-backup-large-odf.yaml` (48Gi), `manifests/incremental-backup-large-odf.yaml` (30Gi) — scaled up with the same capacity margin as the `odf` variant, for the same reason (CDI overhead + Ceph RBD's strict capacity enforcement). Both are opt-in and do not change default `make e2e` behavior beyond what `MANIFEST_VARIANT` selects.

By itself, a bigger disk does not widen the live block-copy window (`cbt-chaos/chaos-plan.md`): a page-cache-absorbed copy on a node with hundreds of GB of free RAM finishes a 64/32 MiB payload in a few seconds regardless of PVC size. What actually widens the window is a correspondingly large `GUEST_DATA_SIZE_MB`/`GUEST_INCREMENTAL_DATA_SIZE_MB`. Measured with `scripts/monitor.sh` on cbt-demo-hpp: `GUEST_DATA_SIZE_MB=8192` gave a ~28s full backup, and `GUEST_INCREMENTAL_DATA_SIZE_MB=12288` gave a ~16s incremental backup — both comfortably past a 15s target for chaos scenarios to land mid-copy. Duration scaled roughly linearly with incremental payload size in the 4-12GiB range tested (4096→~6s, 8192→~11s, 12288→~16s), so further tuning can extrapolate from those points rather than guessing.

### 4. `make vm-cbt-verify`

`scripts/vm-cbt-verify.sh` checks the API state rather than inferring success from command exit codes. It requires:

- VM CBT state `Enabled`.
- `vm-backup-<run-id>` type `Full` and `Done=True`.
- `vm-incremental-<run-id>` type `Incremental` and `Done=True`.
- Non-empty, different checkpoint names.
- `vm-tracker-<run-id>.status.latestCheckpoint.name` equal to the incremental backup checkpoint.

It prints `CBT verification passed` only when every condition holds. The hashes printed by setup and incremental backup separately show that the guest file content changed.

### 5. Restore verification (`scripts/vm-cbt-restore-test.sh`, runs as step 4/4 of `vm-cbt-verify`)

This is the step that actually proves the backups contain correct, restorable data, rather than only checking backup/PVC status:

1. Reads the expected hashes recorded in `state/full-backup.sha256` and `state/incremental-backup.sha256`.
2. Confirms both backup PVCs (`vm-backup-pvc-<run-id>`, `vm-incremental-pvc-<run-id>`) are `Bound`.
3. Applies `manifests/restore-verify-pod.yaml` (with placeholders substituted, the same pattern `vm-setup.sh` uses for the SSH public key) as a short-lived pod that mounts both backup PVCs read-only, then:
   - `qemu-img convert` the full backup's qcow2 straight to raw (full-only restore).
   - `qemu-img rebase` the incremental qcow2 onto the full qcow2, then `qemu-img convert` the result to raw (full+incremental restore).
   - Extracts `/home/cbt-demo/hello.txt` from each raw disk with `losetup` + a direct `mount -o ro` of its ext4 root filesystem (see `images/restore-helper/Dockerfile`).
4. Deletes the pod (via a trap, on success or failure) and reads its logs for the two hashes and whether the incremental marker line is present in each.
5. Asserts: the full-only restore matches `state/full-backup.sha256` and does **not** contain the incremental marker line; the full+incremental restore matches `state/incremental-backup.sha256` and **does** contain the marker line.

Any mismatch fails the step (exit 1) — a missing incremental delta, a stale/corrupt/empty restored disk, or a backup that silently drops data will all produce a hash or marker-line mismatch here rather than passing on PVC status alone. All checks in this step and in `vm-cbt-verify.sh`'s step 3/4 run to completion (they do not stop at the first failure), so a failing run's report shows every check's outcome, not just the first one.

## Run report

`vm-setup.sh` also generates a `REPORT_ID` (`run_<UTC timestamp>`, kept separate from the resource-naming run ID) and persists it to `state/report-id`. Every later stage appends a JSON fragment to `report/<REPORT_ID>/fragments/`:

- `vm-setup.sh` → `setup.json`: namespace, VM name, guest file path, and the full-backup guest hash/size (`size_bytes` and `size_mb`)/capture time.
- `vm-backup.sh` → `full-backup.json`: full backup name/type/checkpoint, its PVC name/requested size/capacity, and the VM's recorded backup start/end timestamps and completion status (captured immediately after `Done=True`, since `status.changedBlockTracking.backupStatus` is overwritten by the next backup).
- `vm-cbt-backup.sh` → `incremental-backup.json`: same shape as above, plus the incremental-backup guest hash/size (`size_bytes` and `size_mb`)/capture time.
- `vm-cbt-verify.sh` → `verify.json`: tracker name/latest checkpoint and the 5 CBT/checkpoint checks (each with a `passed` boolean). This stage also collects the VM's `virt-launcher` pod's full log to `report/<REPORT_ID>/logs/virt-launcher.log`.
- `vm-cbt-restore-test.sh` → `restore-test.json`: the PVC-bound and hash/marker checks (each with a `passed` boolean). The restore-verify pod's full log is saved to `report/<REPORT_ID>/logs/restore-verify-pod.log`.

`vm-cbt-verify.sh` merges every fragment (deep-merging objects, concatenating each stage's `checks` array) into `report/<REPORT_ID>/report.json`, adds `run_id`/`report_id`, sets `verification.overall_passed` from all checks across both scripts, and records a `logs` object pointing at the collected pod logs. `report/` is not touched by `make clean-all` — unlike `state/`, it is meant to persist as a debugging record across runs. Log collection is best-effort: if a pod is already gone, the workflow logs a warning and continues rather than failing the run.

## Resources and names

All workflow objects live in the shared, globally configured `$NAMESPACE` (default `vm-cbt-demo`, set in `.env`). Every `make e2e` invocation generates one run ID (`<adjective>-<noun>-<hex tag>`, e.g. `dark-forest-80d7`, persisted to `state/run-id`) and derives every resource name from it, so repeat runs coexist in the same namespace without collisions:

| Resource | Name | Purpose |
|---|---|---|
| VirtualMachine | `vm-<run-id>` | Debian guest with CBT label |
| DataVolume/PVC | `vm-disk-<run-id>` | Persistent VM root disk |
| Service | `vm-ssh-<run-id>` | Guest SSH access for the scripts |
| VirtualMachineBackupTracker | `vm-tracker-<run-id>` | Stores the base/latest checkpoint |
| VirtualMachineBackup | `vm-backup-<run-id>` | Initial full backup |
| PVC | `vm-backup-pvc-<run-id>` | Full backup output |
| VirtualMachineBackup | `vm-incremental-<run-id>` | Backup based on the tracker checkpoint |
| PVC | `vm-incremental-pvc-<run-id>` | Incremental backup output |
| Pod (short-lived) | `vm-restore-verify-<run-id>` | Reconstructs and reads the guest disk during `vm-cbt-restore-test` |

Every resource above is labeled `app.kubernetes.io/managed-by=virt-cbt-lab` and `virt-cbt-lab/run-id=<run-id>`; those labels, not the namespace, are the ownership mechanism `clean-all` uses. `vm-setup.sh` generates a new run ID at the start of every run; `vm-backup.sh`, `vm-cbt-backup.sh`, `vm-cbt-verify.sh`, and `vm-cbt-restore-test.sh` read the current one back from `state/run-id`.

The Debian golden image (`DataVolume`/`DataSource` `debian-golden`/`debian`) lives in namespace `vm-cbt-images`, deliberately outside `$NAMESPACE`, so it survives `make clean-all` and is only downloaded once.

## Repeated runs without cleanup

```sh
make e2e
make e2e
make e2e
```

Each invocation creates its own isolated VM/disk/backup/tracker set in the same namespace; nothing needs to be torn down in between. Run these sequences sequentially from one checkout: `state/run-id`, `state/report-id`, and the guest-hash files are shared local state and concurrent invocations can cross-wire a report. Use separate repository copies for concurrent runs. Run `make clean-all` any time to remove every run's resources from the namespace (it finds them by the `app.kubernetes.io/managed-by=virt-cbt-lab` label).

## Cleanup

```sh
make clean-all
```

`scripts/clean-all.sh` does **not** delete the namespace. It deletes run-labeled VMs, DataVolumes, backups, trackers, PVCs, services, pods, and Windows OOBE Secrets from `$NAMESPACE`, waits for managed PV reclamation, removes only the workflow-owned Debian SSH key, and clears local `state/`. Reports and shared golden images remain. Unrelated namespace resources are preserved.

## Windows VM setup and CBT profile

Run `make windows-vm-setup` first to provision one Windows Server 2022 VM and initialize `C:\cbt-data\hello.txt` over QEMU Guest Agent. If `windows-server-2022` is not cached, setup installs Windows from the Evaluation ISO, installs Python 3.12.4 and the file-writer/SQLite-writer/HTTP-server workloads, registers their SYSTEM startup task, verifies them, removes generated test data, syspreps the disk, and publishes the reusable DataSource in `vm-cbt-images`. The runtime clone is then checked for startup workload continuity before the CBT file is initialized. This is separate from the Debian default and does not require SSH access to Windows.

`WINDOWS_ADMIN_PASSWORD_FILE` must point to a readable, gitignored password
file on the execution host for the one-time image build and every runtime
clone; each clone uses it to create a run-scoped OOBE Secret.

After the single-VM setup is validated, run `make e2e VM_OS=windows NAME=windows-cbt-1` for the full Windows CBT workflow. It reuses the existing generic full-backup, tracker, incremental-backup, report, and verification stages; Windows-specific logic covers OOBE, guest mutation, and NTFS restore inspection. The Windows profile requires the ODF virtualization Block class for VM disks and the ODF Filesystem class for backup PVCs. Follow [`docs/windows-server-2022-setup-runbook.md`](windows-server-2022-setup-runbook.md) for the end-to-end setup procedure; this document remains the exact repository workflow reference.

## Troubleshooting signals

- Guest SSH retries indicate that the VM service or guest SSH daemon is not ready; inspect the local `oc port-forward` log and VM readiness.

- `CBT is not enabled ...`: verify the cluster feature gate and that the VM has label `cbt-demo=enabled`.
- Debian golden image import stuck or failing: check `oc get dv debian-golden -n vm-cbt-images` and its importer pod logs; confirm cluster CDI importers can reach `cloud.debian.org`. Force a re-import with `oc delete namespace vm-cbt-images`.
- PVC remains pending: verify `cbt-demo-hpp` is available and can provision local demo volumes.
- `vm-incremental-<run-id> already exists`: two script invocations shared the same run ID (only possible if `RUN_ID` was manually exported); run `make vm-setup` to start a fresh run.
- Incremental type is not `Incremental`: check that the full checkpoint reached the tracker and inspect the `VirtualMachineBackup` conditions and tracker status.
