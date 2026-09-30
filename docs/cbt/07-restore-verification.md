# 07. Restore verification

## Why the repository has its own restore test

The KubeVirt CBT API writes qcow2 artifacts but does not define a native restore API. A backup vendor or operator must reconstruct the chain. The repository verifies real data instead of trusting only `Bound`, `Done=True`, or `type=Incremental`.

## Restore sequence

```mermaid
sequenceDiagram
    participant V as vm-cbt-restore-test.sh
    participant A as OpenShift API
    participant P as privileged restore pod
    participant F as full PVC
    participant I as incremental PVC
    participant Q as qemu-img + loop/mount
    participant R as report

    V->>V: Read expected full/incremental hashes
    V->>A: Check both backup PVCs are Bound
    V->>A: Apply restore-verify pod with both PVCs read-only
    P->>F: Find full qcow2
    P->>I: Find incremental qcow2
    P->>Q: Convert full qcow2 to full.raw
    P->>Q: Rebase incremental overlay onto full qcow2
    P->>Q: Convert rebased chain to combined.raw
    P->>Q: Loop-attach and mount ext4 root read-only
    P->>P: Hash hello.txt and check marker presence
    P-->>V: Full and combined hashes/markers
    V->>R: Record individual checks and overall result
    V->>A: Delete short-lived restore pod
```

## Assertions

| Restore | Expected hash | Marker |
|---|---|---|
| Full-only | Hash captured before guest mutation | Absent |
| Full + incremental | Hash captured after guest mutation | Present |

The helper uses `qemu-img convert`, `qemu-img rebase`, `losetup`, and a read-only ext4 mount. It requires a custom image built from `images/restore-helper/Dockerfile`, a privileged pod, and access to the node's `/dev`.

## Artifact-level verification gap

The restore test proves semantic guest data, not the physical delta representation. It does not currently run `qemu-img info` or `qemu-img map` assertions on both artifacts, compare the incremental `backing-filename`, or compare allocated clusters. A malformed or unnecessarily full-sized incremental image could still pass the `hello.txt` hash test if the resulting disk state is correct.

For a chaos test that claims CBT delta preservation, add a read-only artifact check before and after the injection:

```sh
qemu-img info <full.qcow2>
qemu-img info <incremental.qcow2>
qemu-img map --output=json <full.qcow2>
qemu-img map --output=json <incremental.qcow2>
```

Record the backing-file relationship, virtual size, actual file size, and allocated cluster map. Do not use file size alone as proof: qcow2 metadata, preallocation, compression, and filesystem allocation can change physical size.

## Security and scheduling requirements

The restore pod intentionally uses:

- `privileged: true`;
- a `/dev` hostPath;
- both backup PVCs mounted read-only;
- an `emptyDir` work volume.

Cloud05 emitted PodSecurity restricted warnings but allowed the pod. A cluster enforcing the restricted profile can reject it unless the namespace/SCC policy explicitly allows the operation.

## What this proves and does not prove

It proves the actual guest file can be reconstructed from the full and incremental artifacts, including the incremental marker transition.

It does not prove:

- a reconstructed VM boots;
- qcow2 cluster allocation independently proves a delta rather than a complete recopy;
- the chain survives a real node/VMI/controller failure;
- the artifacts have been replicated off cluster.

For manual commands and an independently rendered pod manifest, see [`../restore-verification.md`](../restore-verification.md).
## Upstream boundary

The absence of a native restore API is an API/design boundary, not a missing step in this repository. The backup CRD and status contract are defined in [KubeVirt API types](12-kubevirt-source-reference.md#crd-and-api-contract); the Push/backup engine ends in the [launcher storage path](12-kubevirt-source-reference.md#node-local-runtime-and-qemulibvirt-path). The repository's `qemu-img` reconstruction is therefore an external consumer of the artifacts, not a KubeVirt controller behavior.
