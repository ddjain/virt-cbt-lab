# 13. Independent CBT verification

## Purpose and verdict boundaries

Use this procedure to judge a CBT run from raw Kubernetes, virt-launcher/libvirt, qcow2, and guest evidence. Do not treat a `make` result, repository `report.json`, lifecycle JSON, or a verifier-generated PASS as proof. Those artifacts describe what the repository concluded; they are not independent observations.

Report four conclusions separately:

1. **Backup completion:** KubeVirt reports a terminal successful Full and Incremental backup, and advances the tracker.
2. **CBT path exercised:** the VM reports CBT `Enabled`; the incremental request is tracker-sourced; virt-launcher names the preceding checkpoint as the incremental source; the live libvirt checkpoint tree has the incremental checkpoint as a child of the expected base.
3. **Recovered data integrity:** independently computed path/size/SHA-256 rows from the reconstructed full-plus-incremental disk match a separately inventoried guest state or a baseline captured before backup.
4. **Physical delta evidence:** qcow2 metadata and allocation maps show the incremental artifact is an overlay with data allocated at the child layer. This is a stronger artifact-level claim than the API type or file hashes.

A successful hash comparison proves the reconstructed contents, **not by itself that CBT produced them**: a full copy could contain identical guest data. Conversely, an incremental overlay can be large when many guest blocks changed. Never infer CBT from backup file size alone.

## 1. Read the live API state directly

Set the names from the run's Kubernetes objects, not from a report:

```sh
NAMESPACE=vm-cbt-demo
VM=vm-<run-id>
RUN_ID="${VM#vm-}"
FULL="vm-backup-${RUN_ID}"
INCREMENTAL="vm-incremental-${RUN_ID}-p01"
TRACKER="vm-tracker-${RUN_ID}"
```

Inspect the VM's CBT state and both backup objects:

```sh
oc get vm "$VM" -n "$NAMESPACE" -o json |
  jq '{ready: .status.ready, cbt: .status.changedBlockTracking.state}'

oc get vmbackup "$FULL" "$INCREMENTAL" -n "$NAMESPACE" -o json |
  jq '[.items[] | {
    name: .metadata.name,
    source: .spec.source,
    type: .status.type,
    done: [.status.conditions[]? | select(.type == "Done") | .status],
    reason: [.status.conditions[]? | select(.type == "Done") | .reason],
    checkpoint: .status.checkpointName,
    includedVolumes: .status.includedVolumes
  }]'

oc get vmbackuptracker "$TRACKER" -n "$NAMESPACE" -o json |
  jq '{latestCheckpoint: .status.latestCheckpoint,
       checkpointRedefinitionRequired: .status.checkpointRedefinitionRequired}'
```

Require `cbt: Enabled`; a Full object with `type: Full`; an Incremental object with `type: Incremental`; `Done=True` with a successful terminal reason (not just `Done=True`); a non-empty, distinct checkpoint for the incremental; tracker `latestCheckpoint.name` equal to that incremental checkpoint; and the expected root disk in `includedVolumes`. Confirm the incremental `spec.source.kind` is `VirtualMachineBackupTracker` and its name is this run's tracker.

## 2. Confirm the runtime checkpoint relationship

Capture the live virt-launcher compute log and checkpoint tree independently of repository logs:

```sh
LAUNCHER="$(oc get pod -n "$NAMESPACE" \
  -l "vm.kubevirt.io/name=$VM" -o jsonpath='{.items[0].metadata.name}')"
DOMAIN="${NAMESPACE}_${VM}"
INCREMENTAL_CHECKPOINT="$(oc get vmbackup "$INCREMENTAL" -n "$NAMESPACE" \
  -o jsonpath='{.status.checkpointName}')"

oc logs "pod/$LAUNCHER" -n "$NAMESPACE" -c compute |
  grep -F "Generating incremental backup $INCREMENTAL from checkpoint:"
oc exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh checkpoint-list "$DOMAIN" --tree
oc exec -n "$NAMESPACE" "$LAUNCHER" -c compute -- \
  virsh checkpoint-dumpxml "$DOMAIN" "$INCREMENTAL_CHECKPOINT"
```

The launcher log must name the prior full checkpoint (pass 1) or preceding incremental checkpoint (later pass). The checkpoint tree must show that same parent-child relation. The child checkpoint XML must repeat the expected parent and identify the root disk with `checkpoint='bitmap'` and a non-empty `bitmap` name. A tree without a bitmap entry proves checkpoint ancestry, not bitmap-based changed-block tracking. Save the raw output and timestamps before deleting the VM or allowing its launcher pod to restart; a later launcher may not retain the original log/tree.

## 3. Inspect the backup artifacts, not only their API labels

Find the qcow2 files by mounting both backup PVCs read-only in a temporary inspection pod. The pod needs an image with `qemu-img`. Filesystem hash inspection also needs loop devices and read-only guest filesystem mounts; that operation requires the cluster to permit the corresponding device access. Keep backup PVC mounts read-only, put scratch files on an `emptyDir`, and delete the temporary pod afterward. Do not run a repository restore script in this pod.
Raw conversions can consume scratch space approaching the virtual disk size. Check node ephemeral-storage capacity before running them, and remove the scratch data and inspection pod after capture.

Identify exactly one qcow2 file per backup PVC and record:

```sh
qemu-img info --output=json "$FULL_QCOW2"
qemu-img info --output=json "$INCREMENTAL_QCOW2"
qemu-img map --output=json "$FULL_QCOW2"
```

Inspect the incremental's original `backing-filename`. It may reference a runtime CBT qcow2 path that is not mounted in the inspector; in that case, `qemu-img map` on the unmodified incremental can fail because its backing file is unavailable. Record the exact error and backing path. Do not classify that alone as a backup failure or silently substitute an unrelated base.

To inspect the child's allocation against the full checkpoint without changing either PVC artifact, rebase a scratch copy onto the full image, then inspect the resulting chain:

```sh
cp "$INCREMENTAL_QCOW2" /work/pass01.qcow2
qemu-img rebase -u -b "$FULL_QCOW2" -F qcow2 -f qcow2 /work/pass01.qcow2
qemu-img info --output=json /work/pass01.qcow2
qemu-img map --output=json /work/pass01.qcow2
```

Record `format`, `virtual-size`, `actual-size`, `backing-filename`, map `depth`, and bytes in allocated data extents at depth 0 (the child overlay) and depth 1 (the full base). For example, for a JSON map file:

```sh
jq '{depths: ([.[].depth] | unique),
     overlay_data_bytes: ([.[] | select(.depth == 0 and .data == true) | .length] | add // 0),
     base_data_bytes: ([.[] | select(.depth == 1 and .data == true) | .length] | add // 0)}' map.json
```

A non-empty overlay map plus the API/runtime parent relationship is evidence of child-layer data. Compare the map to the full artifact and expected guest changes; do not require the incremental file to be smaller when the pass changes a large amount of data. Metadata, preallocation, compression, and storage allocation affect file size. Allocation maps alone do not prove that the controller selected the correct checkpoint; combine them with Sections 1 and 2.

## 4. Independently verify restored file hashes

Capture a reference inventory independently from the live guest (or from a trusted pre-backup capture). Each row must be sorted and canonicalized as:

```text
relative-path<TAB>size-bytes<TAB>file-sha256<LF>
```

For example, in a Linux guest:

```sh
DIR=/home/cbt-demo/cbt-workload
while IFS= read -r -d '' file; do
  name="${file##*/}"
  size="$(stat -c '%s' -- "$file")"
  read -r digest _ < <(sha256sum -- "$file")
  printf '%s\t%s\t%s\n' "$name" "$size" "$digest"
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)
```

Independently reconstruct the full-only image and the full-plus-incremental prefix from the PVC files using `qemu-img convert` and the scratch overlay rebase above. Attach each raw image with a loop device, mount the guest root read-only, and compute the same sorted path/size/SHA-256 rows. Compare rows, not just aggregate file counts:

- full-only image versus the baseline inventory captured before the full backup;
- combined prefix versus a live guest inventory captured at the matching pass boundary (or a separately trusted pass capture).

A full-only backup cannot be compared byte-for-byte with the current guest for paths intentionally modified after that checkpoint. Compare it with the pre-backup capture, and report those expected post-checkpoint changes separately. Hash inputs must come from raw guest/filesystem reads, not from the repository report or its restore log.

## Verdict rules for an LLM reviewer

- **CBT API/runtime PASS:** all Section 1 requirements pass and Section 2 independently shows the incremental child of the expected checkpoint.
- **Recovered-data PASS:** independently computed hashes match for the full baseline and each reconstructed prefix. This proves guest-data recovery, not CBT selection by itself.
- **Physical-overlay PASS:** Section 3 shows readable qcow2 artifacts and child-layer allocation consistent with the expected modifications, corroborated by the source checkpoint relationship. State any limits of the map evidence.
- **Overall CBT claim:** call the run “successful KubeVirt CBT incremental backup” only when completion, CBT API/runtime, and recovered-data checks pass. Claim “physical changed-block delta independently verified” only when the artifact/map checks also pass. If raw API, runtime tree/log, or artifact inputs are unavailable, say `INCONCLUSIVE` for that layer; do not substitute repository `report.json` or a green workflow result.

The repository's ordinary restore verifier checks semantic guest files. Its output is useful as supporting evidence, but it does not make the independent artifact or hash assertions in this guide. See [07. Restore verification](07-restore-verification.md) for the existing automation's scope and limits, and [08. Operations](08-operations.md) for direct cluster inspection commands.
