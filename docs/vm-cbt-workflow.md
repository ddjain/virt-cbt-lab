# KubeVirt CBT VM backup workflow

This guide explains the repository's `make e2e` demonstration: create one VM, write a deterministic baseline file set and manifest, take one full backup, then add new files and take the configured number of sequential incremental backups on that same VM. The workflow verifies every checkpoint and restored workload prefix.
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
- The `ocs-storagecluster-ceph-rbd` virtualization storage class for the default `MANIFEST_VARIANT=odf` (see `docs/odf-setup-plan.md`), or `cbt-demo-hpp` with `MANIFEST_VARIANT=default`/`large`. RHEL 9 maps either backend to large manifests with an 80Gi root/full-backup request.
- Outbound HTTPS access from the cluster's CDI importer to `cloud.debian.org` for the first Debian golden-image import. RHEL 9 instead requires the cluster-provided `rhel9` DataSource and a `Bound` source PVC in `openshift-virtualization-os-images`.
- Bash, Make, `oc`, `ssh`, `ssh-keygen`, `jq`, and a SHA-256 utility (`shasum` or `sha256sum`) for the per-run workload manifest, plus access to the local kubeconfig.
- For `make vm-cbt-restore-test`: build and push `images/restore-helper/Dockerfile` (provides `qemu-img` and `util-linux`; Windows restore also requires `ntfs-3g`) to a registry you control, and set `RESTORE_HELPER_IMAGE` to that reference. The cluster must allow the privileged pod.

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

`make e2e NAME=foo` uses `foo` as the run ID instead of a random one, for a deterministic, repeatable run name; omit `NAME` to keep the default random `<adjective>-<noun>-<hex tag>` scheme.

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

The staged commands use the profile saved in `report/vms/foo/vm-info.json`;
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

Each step can also be run separately:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
```

Workflow logs use UTC timestamps on numbered steps, actions, successes, and failures. `make e2e` prints elapsed seconds for preflight and each top-level target; `vm-cbt-demo` separately times setup/baseline workload, the full backup, each incremental pass, and verification/restore. The E2E summary reports total elapsed time including preflight, setup, all backup passes, and restore verification.

During full and incremental backup waits, logs show observed backup-condition and PVC-state changes, matching VM backup-status timestamps/results, and a 30-second heartbeat while the state is unchanged. `DEBUG=true` adds detailed condition and VM backup-status snapshots. The Backup API exposes no copied-byte counter, so logs report phase and elapsed time rather than a percentage. `Done=True` still requires checking its reason, type, checkpoint, and tracker.

After success, the read-only monitor reports API-object creation-to-Done durations for the full and every planned incremental backup; these include controller/PVC work, not only QEMU's data-copy interval. For a separate live monitor, run `make monitor VM=vm-<run-id>` after setup writes `report/vms/<run-id>/vm-info.json`; it waits for planned backup objects to appear.


## Step-by-step behavior

### 1. `make vm-setup`

`scripts/vm-setup.sh`:

1. For Debian, applies `manifests/debian-image.yaml` and waits for `DataVolume debian-golden` (namespace `vm-cbt-images`) to reach `Succeeded`. The first run imports the ~2 GiB Debian genericcloud qcow2 from `cloud.debian.org`; later runs reuse the cached image. For RHEL 9, setup reads the cluster-provided `rhel9` DataSource in `openshift-virtualization-os-images` and waits for its source PVC to be `Bound`; it does not import or modify that platform image.
2. Ensures a dedicated guest SSH key exists locally on the target server. The public key is inserted into the Linux cloud-init user data; the private key stays at `GUEST_KEY` with mode `0600` (by default, repository-local `keys/id_ed25519`, which is gitignored).
3. `TYPE=all` generates a fresh run ID (or uses the supplied `NAME`); staged `TYPE=full VM=vm-<run-id>` starts the specified lifecycle. It applies the selected VM manifest and creates the VM, root disk, and SSH service with run ownership labels.
4. Creates a root `DataVolume` from the profile's DataSource. Debian uses the selected standard size (5Gi on `cbt-demo-hpp` or 6Gi on ODF). RHEL 9 maps HPP and ODF settings to large manifests with an 80Gi root DataVolume request, sized to clone the larger platform source; CDI may expand the resulting ODF PVC request. The target disk must still be at least as large as the source PVC. The VM has one vCPU, 2 GiB memory for the small Debian profile or 4 GiB for RHEL 9, pod networking, and cloud-init SSH access for `cbt-demo`.
5. Labels the VM `cbt-demo=enabled`, waits for the VM `Ready` condition, and checks `.status.changedBlockTracking.state == Enabled`.
6. Connects through a local `oc port-forward`, creates `GUEST_BASE_FILE_COUNT` (default 8) deterministic files in `/home/cbt-demo/cbt-workload`, with each size selected reproducibly from the inclusive `GUEST_FILE_SIZE_MIN_MIB`–`GUEST_FILE_SIZE_MAX_MIB` range (defaults 4–12 MiB). It hashes every file, logs the baseline file count and payload bytes, and records the file list, sizes, and hashes in `report/<REPORT_ID>/workload-manifest.json` before the full backup.
7. Initializes `report/vms/<run-id>/vm-info.json` with the report ID, workload settings, configured pass count, and lifecycle status. Later stages update this record atomically.

One-shot and staged commands resolve the same run ID and per-lifecycle report. In staged use, `TYPE=incremental VM=vm-<run-id>` selects the existing VM and loads its profile and workload settings from `report/vms/<run-id>/vm-info.json`; it does not recreate the VM or baseline workload. `make clean-all` removes transient `state/` but retains per-VM lifecycle records as `cleaned` and retains run reports.

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
3. Adds `GUEST_INCREMENTAL_FILE_COUNT` (default 4) unique deterministic files for the next pass; verifies the baseline and earlier passes, then appends the new files and cumulative totals to the workload manifest.
4. Creates pass-specific backup and output PVC names (`vm-incremental-<run-id>-pNN` and `vm-incremental-pvc-<run-id>-pNN`) using the same tracker.
5. Waits for `Done=True`, requires `.status.type == Incremental`, verifies the new checkpoint is distinct and recorded by the tracker, then advances lifecycle state only after success.

File names, sizes, and bytes are stable across retries. Existing incremental files are retained only if their sizes and hashes match the deterministic payload; missing files are created, and unexpected or changed files fail before the incremental backup.

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

**ODF-backed variant (default).** `make e2e` defaults to `MANIFEST_VARIANT=odf` (see `.env.example`), which uses `manifests/vm-odf.yaml`, `manifests/full-backup-odf.yaml`, and `manifests/incremental-backup-odf.yaml` — same structure as the plain manifests apart from `storageClassName: ocs-storagecluster-ceph-rbd` instead of `cbt-demo-hpp`, and larger PVC sizing (6Gi/6Gi/4Gi vs. the plain 5Gi/5Gi/3Gi). The larger sizing was found necessary by running `make e2e MANIFEST_VARIANT=odf` against the target ODF cluster: CDI's clone-time filesystem-overhead reservation inflates the root disk past the nominal 5Gi, and Ceph RBD enforces PVC capacity strictly (unlike `cbt-demo-hpp`, which silently tolerates the same overcommit), so a flat 5Gi backup-target PVC failed the full backup with `Backup has failed: No space left on device`. Requires ODF/Ceph deployed on the cluster first (see `docs/odf-setup-plan.md`); it does not affect the golden image cache, which stays on `cbt-demo-hpp` regardless of variant. Set `MANIFEST_VARIANT=default` to fall back to plain `cbt-demo-hpp` manifests on clusters without ODF.

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

1. Reads and validates `report/<REPORT_ID>/workload-manifest.json`, including the baseline, each incremental pass, and cumulative manifest hashes.
2. Confirms the full backup PVC and every pass-specific incremental PVC are `Bound`.
3. Applies the OS-appropriate restore pod with all backup PVCs mounted read-only, then:
   - Converts the full backup's qcow2 to raw and verifies the baseline file set.
   - Rebases each incremental overlay onto the preceding checkpoint, converts each cumulative state to raw, and verifies its workload prefix.
   - Mounts each raw disk's root filesystem read-only and computes a sorted manifest of the workload directory.
4. Reports restored file counts, payload bytes, and canonical manifest hashes for the full-only image and every incremental prefix.
5. Requires every restore count, byte total, and manifest hash to match the corresponding baseline or cumulative pass manifest.

Any mismatch fails the step (exit 1): missing or extra files, changed contents, stale/corrupt restores, or an unapplied incremental delta. The report records every comparison; PVC status alone is not treated as proof.

## Run report

`vm-setup.sh` generates a `REPORT_ID` (`run_<UTC timestamp>`, with a run-ID suffix if needed) and stores it in both the transient state and `report/vms/<run-id>/vm-info.json`. Every later stage resolves that lifecycle's report ID from its VM info record and appends JSON under `report/<REPORT_ID>/fragments/`.

- `vm-setup.sh` → `setup.json`: namespace, VM profile, workload directory/range, baseline count/bytes/hash, and planned pass count.
- `vm-backup.sh` → `full-backup.json`: full backup name/type/checkpoint and its output PVC request/capacity.
- Each `vm-cbt-backup.sh` invocation → `incremental-pass-NN.json`: pass number, files/bytes/hash added, cumulative workload totals/hash, backup name/type/checkpoint, output PVC, and available API status fields.
- `vm-cbt-verify.sh` → `verify.json`: tracker and final checkpoint plus CBT/checkpoint checks; it collects the VM's `virt-launcher` log.
- `vm-cbt-restore-test.sh` → `restore-test.json`: PVC-bound and full/prefix file-count, payload-byte, and manifest-hash checks; the restore pod log is saved alongside the report.

`vm-cbt-verify.sh` merges the fragments into `report/<REPORT_ID>/report.json`, concatenates pass records and check arrays, adds `run_id`/`report_id`, and sets `verification.overall_passed` from all API and restore checks. `report/vms/<run-id>/vm-info.json` is the resumable lifecycle index; `make clean-all` marks it `cleaned` while preserving it and all run reports.
## Resources and names

All workflow objects live in the shared, globally configured `$NAMESPACE` (default `vm-cbt-demo`, set in `.env`). `TYPE=all` or `TYPE=full` starts a lifecycle with a random run ID by default, or the fixed ID from `NAME`/`VM`; `TYPE=incremental` and `TYPE=verify` load that existing lifecycle by `VM=vm-<run-id>`. Resource names derive from the run ID, so different runs coexist without collisions:

| Resource | Name | Purpose |
|---|---|---|
| VirtualMachine | `vm-<run-id>` | Debian or RHEL 9 guest with CBT label |
| DataVolume/PVC | `vm-disk-<run-id>` | Persistent VM root disk |
| Service | `vm-ssh-<run-id>` | Guest SSH access for the scripts |
| VirtualMachineBackupTracker | `vm-tracker-<run-id>` | Stores the base/latest checkpoint |
| VirtualMachineBackup | `vm-backup-<run-id>` | Initial full backup |
| PVC | `vm-backup-pvc-<run-id>` | Full backup output |
| VirtualMachineBackup | `vm-incremental-<run-id>-pNN` | Pass-specific backup based on the preceding tracker checkpoint |
| PVC | `vm-incremental-pvc-<run-id>-pNN` | Retained output PVC for that pass |
| Pod (short-lived) | `vm-restore-verify-<run-id>` | Reconstructs and reads the guest disk during `vm-cbt-restore-test` |

Every resource above is labeled `app.kubernetes.io/managed-by=virt-cbt-lab` and `virt-cbt-lab/run-id=<run-id>`; those labels, not the namespace, are the ownership mechanism `clean-all` uses. The VM lifecycle state and report ID live under `report/vms/<run-id>/`; the incremental backup and PVC names use `p01`, `p02`, … suffixes. `make clean-all` reclaims every pass PVC; until cleanup, provisioned backup storage grows with the pass count.

The Debian golden image (`DataVolume`/`DataSource` `debian-golden`/`debian`) lives in namespace `vm-cbt-images`, deliberately outside `$NAMESPACE`, so it survives `make clean-all` and is downloaded only once. RHEL 9 uses the cluster-managed `rhel9` DataSource in `openshift-virtualization-os-images`; the workflow waits for its backing PVC and leaves it unchanged.

## Repeated runs without cleanup

```sh
make e2e
make e2e
make e2e
```

Each `TYPE=full` invocation creates one VM and full checkpoint; each `TYPE=incremental` invocation adds exactly one pass using that VM's saved state. Commands must run sequentially within a checkout. The E2E lock prevents concurrent lifecycle commands from cross-wiring state, and `report/vms/<run-id>/vm-info.json` keeps each staged lifecycle attached to its own report. Run `make clean-all` any time to remove every run's resources from the namespace.

## Cleanup

```sh
make clean-all
```

`scripts/clean-all.sh` does **not** delete the namespace. It deletes run-labeled VMs, DataVolumes, backups, trackers, PVCs, services, pods, and Windows OOBE Secrets from `$NAMESPACE`, waits for managed PV reclamation, removes only the workflow-owned guest SSH key, and clears transient `state/`. It marks lifecycle records under `report/vms/` as `cleaned`; those records, per-run reports, and shared golden images remain. Unrelated namespace resources are preserved.

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
- `vm-incremental-<run-id>-pNN` already exists: the selected pass-specific backup name conflicts with an existing resource. Check `next_incremental_pass` in `report/vms/<run-id>/vm-info.json`; do not reuse a completed pass name.
- Incremental type is not `Incremental`: check that the full checkpoint reached the tracker and inspect the `VirtualMachineBackup` conditions and tracker status.
