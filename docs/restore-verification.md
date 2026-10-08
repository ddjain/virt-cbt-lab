# Restore verification: proving the CBT backups contain the expected guest files

This guide describes the data-plane assertion in `make vm-cbt-restore-test`. It reconstructs the full-only disk and every cumulative full-plus-incremental prefix, mounts each read-only, and compares the guest workload directory against the run's manifest. Each incremental prefix contains both newly added files and one deterministically modified baseline file. Backup API status and PVC binding alone are not restore proof.

## Why this uses a custom restore path

KubeVirt's CBT incremental-backup API writes qcow2 artifacts but does not define a restore API:

- A `Full` backup writes a standalone qcow2 base image.
- Each `Incremental` backup writes an overlay based on the tracker’s latest checkpoint. Pass 1 is based on the full checkpoint; later passes are based on the previous incremental checkpoint.

The restore sequence converts the full-only disk, then rebases each pass-specific overlay onto the preceding checkpoint, converts that cumulative prefix to raw, and compares it to the matching per-pass manifest before continuing. The short-lived privileged pod mounts backup PVCs read-only and uses the node's `/dev` for loop devices. Debian restores mount ext4, RHEL 9 restores mount XFS, and Windows restores mount NTFS with `ntfs3` or `ntfs-3g`.

The restore pod creates no additional PVC: it mounts the existing full and incremental backup PVCs read-only. Its `/work` volume is an `emptyDir` for raw images and the temporary incremental copy; `/dev` is a hostPath for loop devices. The `emptyDir` has no `sizeLimit` in the current manifest, so its ephemeral-storage use is separate from the PVC budget.

## Workload and manifest contract

The CBT workload is a dedicated, flat guest directory:

- Debian and RHEL 9: `/home/cbt-demo/cbt-workload`
- Windows: `C:\cbt-data\workload`

Setup creates `GUEST_BASE_FILE_COUNT` baseline files before the full backup. Each incremental pass adds `GUEST_INCREMENTAL_FILE_COUNT` new files and deterministically modifies one existing baseline file. Every file has a deterministic name and content, and a reproducibly selected whole-MiB size from the inclusive `GUEST_FILE_SIZE_MIN_MIB`–`GUEST_FILE_SIZE_MAX_MIB` range. Defaults are 8 baseline files, 4 additions per pass, one modified baseline file per pass, and a 4–12 MiB size range.

Each run records `runs/<run-id>/workload-manifest.json`. It includes the guest directory, size range, baseline entries, every incremental addition and per-pass baseline modification, per-file sizes and SHA-256 hashes, payload totals, and the baseline plus cumulative-prefix manifest hashes. The manifest is kept outside the guest workload directory and survives `make clean-all`.

A canonical manifest hash is SHA-256 over sorted rows of:

```text
relative-path<TAB>size-bytes<TAB>file-sha256<LF>
```

The restore pod computes the same rows from the mounted disk. Thus, count equality alone cannot pass when a file is missing, extra, renamed, resized, or has different contents.

The incremental PVC contains only its disk delta; it is not a standalone cumulative file tree. Assertions are made on the reconstructed full-only disk and on every full-plus-incremental prefix.

## Restore sequence

```text
VM workload directory
  baseline files (N) -> full checkpoint -> full.qcow2
  pass 01: add M1 files + modify one baseline file -> overlay based on full
  pass 02: add M2 files + modify one baseline file -> overlay based on pass 01
  ...

scripts/vm-cbt-restore-test.sh
  validate runs/<run-id>/workload-manifest.json
  confirm the full and every pass PVC are Bound
  convert full qcow2 -> full.raw; validate baseline
  for each pass in order:
    rebase its overlay onto the previous checkpoint
    convert the cumulative prefix to raw and validate its manifest
```

| Restore image | Expected file count | Expected manifest |
|---|---:|---|
| Full-only | N | `baseline.manifest_sha256` |
| Prefix through pass k | N + sum of `files_added` for passes 1..k | The `.incrementals[]` entry whose `pass` is k; its digest includes all baseline modifications through k |

A mismatch fails the workflow and is added to `verification.checks` in the report. The checks include expected and observed values. The restore pod log is retained at `runs/<run-id>/logs/restore-verify-pod.log`.

## Reproduce and inspect a run

Run the full workflow or execute a lifecycle in stages:

```sh
make e2e TYPE=full NAME=restore-demo GUEST_INCREMENTAL_PASSES=3
make e2e-incremental VM=vm-restore-demo  # repeat three times
```

Inspect the baseline, additions, modifications, and each cumulative pass:

```sh
manifest="runs/restore-demo/workload-manifest.json"
jq '{guest_directory, size_range_mib,
     baseline: {file_count: .baseline.file_count,
                total_payload_bytes: .baseline.total_payload_bytes,
                manifest_sha256: .baseline.manifest_sha256},
     incrementals: [.incrementals[] |
       {pass, files_added, modified_paths: [.files_modified[].path],
        added_payload_bytes, modified_manifest_sha256,
        total_file_count, total_payload_bytes, manifest_sha256}]}' "$manifest"
```


Independently confirm the backup objects and destination PVCs for that run:

```sh
vm=vm-restore-demo
run_id="${vm#vm-}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
oc get vmbackup -n "$NAMESPACE" -l "virt-cbt-lab/run-id=$run_id" \
  -o custom-columns=NAME:.metadata.name,TYPE:.status.type,DONE:'.status.conditions[?(@.type=="Done")].status',CHECKPOINT:.status.checkpointName,PVC:.spec.pvcName
oc get pvc -n "$NAMESPACE" -l "virt-cbt-lab/run-id=$run_id" \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage
```

For a direct restore-only run:

```sh
make vm-cbt-restore-test VM="$vm"
oc logs "pod/vm-restore-verify-$run_id" -n "$NAMESPACE"
```


The pod emits these fields for the full image and every cumulative incremental prefix:

```text
FULL_WORKLOAD_FILE_COUNT=...
FULL_WORKLOAD_PAYLOAD_BYTES=...
FULL_WORKLOAD_MANIFEST_SHA256=...
PASS_01_WORKLOAD_FILE_COUNT=...
PASS_01_WORKLOAD_PAYLOAD_BYTES=...
PASS_01_WORKLOAD_MANIFEST_SHA256=...
...
PASS_NN_WORKLOAD_FILE_COUNT=...
PASS_NN_WORKLOAD_PAYLOAD_BYTES=...
PASS_NN_WORKLOAD_MANIFEST_SHA256=...
```

Compare the full fields with `.baseline` and each `PASS_NN` set with the matching `.incrementals[]` entry, including deterministic modifications. The script records every comparison in `runs/<run-id>/fragments/restore-test.json`, which is merged into `runs/<run-id>/report.json` by `make vm-cbt-verify`.

The restore pod is deleted automatically on success and failure. To rebuild the helper image when needed:

```sh
podman build -t quay.io/<you>/cbt-restore-helper:latest images/restore-helper
podman push quay.io/<you>/cbt-restore-helper:latest
```

Set `RESTORE_HELPER_IMAGE` in `.env` to the pushed image. The image provides `qemu-img`, `util-linux`, `findutils`, and coreutils; Windows restores also need `ntfs-3g`. The cluster must permit the privileged pod and node `/dev` mount.

## What this proves and what it does not

**Proven:** the full backup reconstructs the exact baseline file set. For every cumulative prefix, the full backup plus incremental overlays reconstructs the exact new-file set, modified baseline content, and unchanged file content. Matching the canonical digest checks every expected filename, exact size, and per-file SHA-256.

**Not proven:** that the restored disk boots as a VM, or that the incremental qcow2 stores only the minimum changed blocks. This test reads the reconstructed guest filesystem; it does not boot a second VM or assert the physical delta representation.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` on `vm-restore-verify-<run-id>` | `RESTORE_HELPER_IMAGE` is unset, mistyped, or unavailable to the cluster | Confirm the image was pushed and the `.env` reference is correct. |
| Restore pod cannot find a workload directory | Setup and restore profile paths differ, or the backup does not contain the generated files | Inspect `workload-manifest.json`, the pod log, and the selected OS-specific restore manifest. |
| File count matches but manifest check fails | A path, size, or file's bytes differ | Compare the per-file entries in `workload-manifest.json` with the restore log and guest directory. |
| `qemu-img: ... backing format must be specified` | The selected `qemu-img` requires an explicit backing format | The current manifests pass `-F qcow2` to `qemu-img rebase`; rebuild/update an older helper copy. |
| `losetup` cannot access loop devices | The pod lacks the node's `/dev` or privileged access | Confirm the restore pod mounts the `host-dev` volume and the cluster permits privileged pods. |
| NTFS mount fails | The helper image lacks `ntfs-3g`, or the partition is not NTFS | Rebuild the helper with `ntfs-3g`; inspect the pod log and selected disk partition. |
