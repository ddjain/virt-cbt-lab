# Restore verification: proving the CBT backups contain the expected guest files

This guide describes the data-plane assertion in `make vm-cbt-restore-test`. It reconstructs the full-only disk and the full-plus-incremental disk, mounts each read-only, and compares the guest workload directory against the run's manifest. Backup API status and PVC binding alone are not restore proof.

## Why this uses a custom restore path

KubeVirt's CBT incremental-backup API writes qcow2 artifacts but does not define a restore API:

- A `Full` backup writes a standalone qcow2 image.
- An `Incremental` backup writes a qcow2 overlay based on the prior checkpoint.

The workflow rebases the incremental overlay onto the full image, converts both the full-only and combined images to raw, then mounts the guest disk in a short-lived privileged pod. The pod mounts backup PVCs read-only and uses the node's `/dev` for loop devices. Debian restores mount ext4; Windows restores mount NTFS with `ntfs3` or `ntfs-3g`.

## Workload and manifest contract

The CBT workload is a dedicated, flat guest directory:

- Debian: `/home/cbt-demo/cbt-workload`
- Windows: `C:\cbt-data\workload`

Setup creates `GUEST_BASE_FILE_COUNT` baseline files before the full backup. After the full checkpoint, the incremental step adds `GUEST_INCREMENTAL_FILE_COUNT` new files. Each file has a deterministic name and content, and a reproducibly selected whole-MiB size from the inclusive `GUEST_FILE_SIZE_MIN_MIB`–`GUEST_FILE_SIZE_MAX_MIB` range. Defaults are 8 baseline files, 4 incremental files, and a 4–12 MiB size range.

Each run records `report/<REPORT_ID>/workload-manifest.json`. It includes the guest directory, file-size range, baseline entries, incremental additions, per-file byte sizes and SHA-256 hashes, payload-byte totals, and baseline/combined canonical manifest hashes. The manifest is kept outside the guest workload directory and survives `make clean-all`.

A canonical manifest hash is SHA-256 over sorted rows of:

```text
relative-path<TAB>size-bytes<TAB>file-sha256<LF>
```

The restore pod computes the same rows from the mounted disk. Thus, count equality alone cannot pass when a file is missing, extra, renamed, resized, or has different contents.

The incremental PVC contains only a disk delta; it is not expected to contain a standalone N+M file tree. The assertion is made on the reconstructed full-plus-incremental disk.

## Restore sequence

```text
VM workload directory
  baseline files (N) -> full checkpoint -> full backup PVC
  add incremental files (M) -> incremental checkpoint -> incremental PVC

scripts/vm-cbt-restore-test.sh
  validate report/<REPORT_ID>/workload-manifest.json
  confirm both backup PVCs are Bound
  convert full qcow2 -> full.raw
  rebase incremental qcow2 onto full qcow2 -> combined.raw
  mount full.raw and combined.raw read-only
  inventory the guest workload directory in each
  compare counts, payload bytes, and canonical manifest hashes
```

Assertions:

| Restore image | Expected file count | Expected manifest |
|---|---:|---|
| Full-only | N | `baseline.manifest_sha256` |
| Full + incremental | N+M | `incremental.manifest_sha256` |

A mismatch fails the workflow and is added to `verification.checks` in the report. The checks include expected and observed values. The restore pod log is retained at `report/<REPORT_ID>/logs/restore-verify-pod.log`.

## Reproduce and inspect a run

Run the workflow stages, or use `make e2e` to run the sequence after preflight:

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
```

Inspect the expected baseline and combined summaries:

```sh
report_id="$(cat state/report-id)"
manifest="report/$report_id/workload-manifest.json"
jq '{guest_directory, size_range_mib,
     baseline: {file_count: .baseline.file_count,
                total_payload_bytes: .baseline.total_payload_bytes,
                manifest_sha256: .baseline.manifest_sha256},
     incremental: {files_added: .incremental.files_added,
                   total_file_count: .incremental.total_file_count,
                   total_payload_bytes: .incremental.total_payload_bytes,
                   manifest_sha256: .incremental.manifest_sha256}}' "$manifest"
```

Independently confirm the backup objects and destination PVCs:

```sh
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
RUN_ID="$(cat state/run-id)"
oc get vmbackup "vm-backup-$RUN_ID" "vm-incremental-$RUN_ID" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,TYPE:.status.type,DONE:'.status.conditions[?(@.type=="Done")].status',CHECKPOINT:.status.checkpointName,PVC:.spec.pvcName
oc get pvc "vm-backup-pvc-$RUN_ID" "vm-incremental-pvc-$RUN_ID" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage
```

For a direct restore-only run:

```sh
make vm-cbt-restore-test
oc logs "pod/vm-restore-verify-$RUN_ID" -n "$NAMESPACE"
```

The pod emits these fields for both images:

```text
FULL_WORKLOAD_FILE_COUNT=...
FULL_WORKLOAD_PAYLOAD_BYTES=...
FULL_WORKLOAD_MANIFEST_SHA256=...
COMBINED_WORKLOAD_FILE_COUNT=...
COMBINED_WORKLOAD_PAYLOAD_BYTES=...
COMBINED_WORKLOAD_MANIFEST_SHA256=...
```

Compare those values with `baseline` and `incremental` in the manifest. The script also records the comparisons in `report/<REPORT_ID>/fragments/restore-test.json`, which is merged into `report/<REPORT_ID>/report.json` by `make vm-cbt-verify`.

The restore pod is deleted automatically on success and failure. To rebuild the helper image when needed:

```sh
podman build -t quay.io/<you>/cbt-restore-helper:latest images/restore-helper
podman push quay.io/<you>/cbt-restore-helper:latest
```

Set `RESTORE_HELPER_IMAGE` in `.env` to the pushed image. The image provides `qemu-img`, `util-linux`, `findutils`, and coreutils; Windows restores also need `ntfs-3g`. The cluster must permit the privileged pod and node `/dev` mount.

## What this proves and what it does not

**Proven:** the full backup reconstructs the exact baseline file set, and the full backup plus incremental overlay reconstructs the exact combined file set. Matching the canonical digest checks every expected filename, exact size, and per-file SHA-256.

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
