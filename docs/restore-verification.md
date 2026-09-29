# Restore verification: how we prove the CBT backup contains correct, restorable data

This document is for engineers who need to independently verify (not just re-run)
the claim behind `make vm-cbt-restore-test`:

> The full backup, and the full backup with the incremental applied, actually
> restore into a disk containing the exact guest data recorded at backup time.

It gives the full chain of commands and the YAML applied at each stage so you
can reproduce every step by hand with `oc` and cross-check the automated
result independently, the same way `validation/e2e-validation-summary-2026-09-29.md`
independently re-checked the earlier (pre-restore) verification steps.

## Why this needs a custom approach (read this first)

KubeVirt's CBT incremental-backup feature (`backup.kubevirt.io/v1alpha1`,
alpha/`IncrementalBackup` feature gate) intentionally does **not** define a
restore API. A `VirtualMachineBackup` only writes a qcow2 file per disk to the
PVC named in its `spec.pvcName`:

- A `Full` backup writes a standalone qcow2.
- An `Incremental` backup writes a qcow2 **overlay**, whose backing file is
  the previous checkpoint's qcow2.

The upstream design doc for this feature states restore is the backup
vendor's responsibility and only sketches a reference method: `qemu-img
rebase` the incremental overlay onto the full image, `qemu-img convert` the
result to raw, then import that raw image somewhere you can read it. This
repo's restore test performs exactly that reconstruction and then reads the
actual guest file out of the result, so we assert on real data instead of
trusting `VirtualMachineBackup`/PVC status alone.

The demo guest (`manifests/vm.yaml`, Debian golden `DataSource` in
`vm-cbt-images`) uses an **ext4** root filesystem, which every helper image
can mount directly via a loop device — no userspace filesystem parser
required. The restore-verification pod still runs a small custom image
(`images/restore-helper/Dockerfile`) to keep `qemu-img` and mount tooling
together, and still needs `privileged: true` to attach loop devices, but the
extraction step itself is a plain `mount -o ro`.

## Architecture

```text
VM (ext4 root disk)
  -> Full VirtualMachineBackup (hello-full)      -> PVC hello-full-output        (qcow2)
  -> Incremental VirtualMachineBackup (hello-incremental)
                                                   -> PVC hello-incremental-output (qcow2 overlay)

scripts/vm-cbt-restore-test.sh:
  1. Read state/full-backup.sha256, state/incremental-backup.sha256
     (captured from the guest itself at backup time, by vm-setup.sh and
     vm-cbt-backup.sh — see "Where the expected hashes come from" below)
  2. Confirm both backup PVCs are Bound
  3. Run manifests/restore-verify-pod.yaml (privileged pod, mounts both PVCs
     read-only + the node's /dev):
       qemu-img convert   full.qcow2                    -> full.raw
       qemu-img rebase    incremental.qcow2 onto full.qcow2 (fixes backing file)
       qemu-img convert   incremental.qcow2 (rebased)   -> combined.raw
       losetup -fP        full.raw / combined.raw       -> loop device + partitions
       mount -o ro        <root partition>               -> mounted ext4 filesystem
       sha256sum + grep   mounted hello.txt
  4. Assert: full.raw content == full-backup.sha256, marker line ABSENT
  5. Assert: combined.raw content == incremental-backup.sha256, marker line PRESENT
```

Any mismatch fails the step (`exit 1`). A missing incremental delta, a
corrupt/stale/empty restore, or a backup that silently drops data will all
produce a hash or marker-line mismatch here — not a pass based on `Bound`
PVC status alone.

## Where the expected hashes come from

- `scripts/vm-setup.sh` writes `hello.txt` in the guest, prints its SHA-256,
  and records it to `state/full-backup.sha256`. Nothing mutates the guest
  disk between `vm-setup.sh` and `vm-backup.sh`, so this is exactly the
  content the full backup contains.
- `scripts/vm-cbt-backup.sh` appends the marker line
  `This line was added after the full backup.` to `hello.txt`, prints the new
  SHA-256, and records it to `state/incremental-backup.sha256` before taking
  the incremental backup.
- `state/` is gitignored (runtime artifact, not repository content).

## Step-by-step: reproduce by hand

Everything below assumes `KUBECONFIG` is exported and you are in the
repository root on the machine with cluster access.

### 1. Run the backup workflow (or use an existing one)

```sh
make vm-setup
make vm-backup
make vm-cbt-backup
```

Capture the two expected hashes (also visible in each command's own output):

```sh
cat state/full-backup.sha256
cat state/incremental-backup.sha256
```

### 2. Independently confirm backup state via the API

```sh
oc get vmbackup hello-full hello-incremental -n vm-cbt-demo \
  -o custom-columns=NAME:.metadata.name,TYPE:.status.type,DONE:'.status.conditions[?(@.type=="Done")].status',CHECKPOINT:.status.checkpointName,PVC:.spec.pvcName

oc get pvc hello-full-output hello-incremental-output -n vm-cbt-demo \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage
```

Expected (values will differ per run — checkpoints are timestamped):

```text
NAME                 TYPE          DONE   CHECKPOINT                              PVC
hello-full            Full          True   hello-full-2026-09-29_19-43-58          hello-full-output
hello-incremental      Incremental   True   hello-incremental-2026-09-29_19-44-21   hello-incremental-output

NAME                       STATUS   CAPACITY
hello-full-output          Bound    5Gi
hello-incremental-output   Bound    3Gi
```

### 3. Build and push the restore-helper image (one-time per registry)

```sh
podman build -t quay.io/<you>/cbt-restore-helper:latest images/restore-helper
podman push quay.io/<you>/cbt-restore-helper:latest
```

`images/restore-helper/Dockerfile`:

```dockerfile
FROM registry.fedoraproject.org/fedora:41

RUN dnf install -y --setopt=install_weak_deps=False \
      qemu-img \
      util-linux \
      findutils \
      coreutils \
      grep \
    && dnf clean all
```

Set it in `.env`:

```sh
RESTORE_HELPER_IMAGE=quay.io/<you>/cbt-restore-helper:latest
```

### 4. Run the restore-verification pod

This is exactly what `make vm-cbt-restore-test` automates. To run it by hand
for independent verification, apply the manifest with the placeholders filled
in (the script does this with `sed`; you can do the same substitution or just
copy the rendered YAML below):

```sh
FULL_PVC=hello-full-output
INCREMENTAL_PVC=hello-incremental-output
HELPER_IMAGE=quay.io/<you>/cbt-restore-helper:latest

sed \
  -e "s|__POD_NAME__|hello-restore-verify|g" \
  -e "s|__NAMESPACE__|vm-cbt-demo|g" \
  -e "s|__FULL_PVC__|$FULL_PVC|g" \
  -e "s|__INCREMENTAL_PVC__|$INCREMENTAL_PVC|g" \
  -e "s|__HELPER_IMAGE__|$HELPER_IMAGE|g" \
  -e "s|__HELLO_FILE__|/home/cbt-demo/hello.txt|g" \
  -e "s|__MARKER_LINE__|This line was added after the full backup.|g" \
  manifests/restore-verify-pod.yaml | oc apply -f -

oc wait pod/hello-restore-verify -n vm-cbt-demo \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m

oc logs pod/hello-restore-verify -n vm-cbt-demo
```

Full rendered pod manifest for reference (`manifests/restore-verify-pod.yaml`,
placeholders already substituted for this demo's fixed resource names):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-restore-verify
  namespace: vm-cbt-demo
  labels:
    cbt-demo-restore-verify: "true"
spec:
  restartPolicy: Never
  volumes:
    - name: full-backup
      persistentVolumeClaim:
        claimName: hello-full-output
        readOnly: true
    - name: incremental-backup
      persistentVolumeClaim:
        claimName: hello-incremental-output
        readOnly: true
    - name: work
      emptyDir: {}
    - name: host-dev
      hostPath:
        path: /dev
        type: Directory
  containers:
    - name: restore-verify
      image: quay.io/<you>/cbt-restore-helper:latest
      securityContext:
        privileged: true
      volumeMounts:
        - name: full-backup
          mountPath: /backups/full
          readOnly: true
        - name: incremental-backup
          mountPath: /backups/incremental
          readOnly: true
        - name: work
          mountPath: /work
        - name: host-dev
          mountPath: /dev
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -euo pipefail
          hello_file="/home/cbt-demo/hello.txt"
          marker_line="This line was added after the full backup."

          full_qcow2="$(find /backups/full -name '*.qcow2' | head -n1)"
          incremental_qcow2="$(find /backups/incremental -name '*.qcow2' | head -n1)"
          if [[ -z "$full_qcow2" ]]; then
            echo "ERROR: no qcow2 file found under /backups/full" >&2
            exit 1
          fi
          if [[ -z "$incremental_qcow2" ]]; then
            echo "ERROR: no qcow2 file found under /backups/incremental" >&2
            exit 1
          fi
          echo "FULL_QCOW2=$full_qcow2"
          echo "INCREMENTAL_QCOW2=$incremental_qcow2"

          # Full backup alone: convert straight to raw.
          qemu-img convert -f qcow2 -O raw "$full_qcow2" /work/full.raw

          # Full + incremental: rebase the overlay onto the full image, then
          # convert the reconstructed chain to raw.
          cp "$incremental_qcow2" /work/incremental.qcow2
          qemu-img rebase -b "$full_qcow2" -F qcow2 -f qcow2 -u /work/incremental.qcow2
          qemu-img convert -f qcow2 -O raw /work/incremental.qcow2 /work/combined.raw

          # Extract the guest file by mounting the raw disk's ext4 root
          # filesystem directly via a loop device (Debian's genericcloud
          # image uses ext4, which every helper image can mount natively).
          extract_hello_file() {
            local raw_image="$1" out_dir="$2"
            local loop_dev part mount_dir found
            loop_dev="$(losetup -fP --show "$raw_image")"
            udevadm settle --timeout=5 2>/dev/null || sleep 1
            part="$(lsblk -blnpo NAME,SIZE "$loop_dev" | tail -n +2 | sort -k2 -n | tail -n1 | awk '{print $1}')"
            mount_dir="$out_dir/mnt"
            mkdir -p "$mount_dir"
            mount -o ro "$part" "$mount_dir"
            found="$(find "$mount_dir" -type f -name "$(basename "$hello_file")" | head -n1)"
            if [[ -n "$found" ]]; then
              mkdir -p "$out_dir/extract"
              cp "$found" "$out_dir/extract/"
              found="$out_dir/extract/$(basename "$hello_file")"
            fi
            umount "$mount_dir"
            losetup -d "$loop_dev"
            printf '%s' "$found"
          }

          full_hello_path="$(extract_hello_file /work/full.raw /work/full-extract)"
          combined_hello_path="$(extract_hello_file /work/combined.raw /work/combined-extract)"
          if [[ -z "$full_hello_path" ]]; then
            echo "ERROR: could not locate $hello_file in the full-only restore" >&2
            exit 1
          fi
          if [[ -z "$combined_hello_path" ]]; then
            echo "ERROR: could not locate $hello_file in the full+incremental restore" >&2
            exit 1
          fi

          full_hash="$(sha256sum "$full_hello_path" | awk '{print $1}')"
          combined_hash="$(sha256sum "$combined_hello_path" | awk '{print $1}')"

          full_has_marker=no
          if grep -Fqx "$marker_line" "$full_hello_path"; then full_has_marker=yes; fi
          combined_has_marker=no
          if grep -Fqx "$marker_line" "$combined_hello_path"; then combined_has_marker=yes; fi

          echo "FULL_HASH=$full_hash"
          echo "COMBINED_HASH=$combined_hash"
          echo "FULL_HAS_MARKER=$full_has_marker"
          echo "COMBINED_HAS_MARKER=$combined_has_marker"
```

A `PodSecurity "restricted:latest"` admission **warning** (not an error) is
expected on clusters enforcing the default restricted profile — the pod does
still get created and run. It needs `privileged: true` and the node's `/dev`
mounted in order to attach loop devices for `losetup`/`mount`.

### 5. Read and independently interpret the output

Actual output from a demo run (`hello-full-2026-09-29_19-43-58` /
`hello-incremental-2026-09-29_19-44-21` checkpoints):

```text
FULL_QCOW2=/backups/full/vm-cbt-demo/hello-full-2026-09-29_19-43-58/hello-full-rootdisk.qcow2
INCREMENTAL_QCOW2=/backups/incremental/vm-cbt-demo/hello-incremental-2026-09-29_19-44-21/hello-incremental-rootdisk.qcow2
FULL_HASH=86465948fd4c202dbd6905f48b7a639681ec6cf26be3ca7e33de909ee19b59d6
COMBINED_HASH=2c4cc2481630200313b91d02333cf35cbc08b6e5ec10eeb22eb8144aa3621373
FULL_HAS_MARKER=no
COMBINED_HAS_MARKER=yes
```

Cross-check against the state files captured in step 1:

```sh
diff <(echo "$FULL_HASH") state/full-backup.sha256
diff <(echo "$COMBINED_HASH") state/incremental-backup.sha256
```

Both `diff` commands must produce no output. `FULL_HAS_MARKER` must be `no`
(the marker line was added *after* the full backup's checkpoint, so it must
not be present when only the full backup is restored) and
`COMBINED_HAS_MARKER` must be `yes` (the incremental backup must actually
carry that change).

If you want to see this fail — confirming the check is not a rubber stamp —
corrupt the recorded expectation and re-run:

```sh
cp state/full-backup.sha256 /tmp/full-backup.sha256.bak
printf 'deadbeef' > state/full-backup.sha256
make vm-cbt-restore-test   # exits non-zero: "Full-backup restore mismatch: expected hash deadbeef, got <real hash>."
cp /tmp/full-backup.sha256.bak state/full-backup.sha256
```

### 6. Clean up

```sh
oc delete pod hello-restore-verify -n vm-cbt-demo --ignore-not-found
```

`scripts/vm-cbt-restore-test.sh` does this automatically via a trap, on both
success and failure.

## What this does and does not prove

**Proven:** the full backup's qcow2 and the incremental backup's qcow2
overlay, taken together, reconstruct into a disk whose guest file content is
byte-for-byte identical (verified by SHA-256, not just presence) to what was
actually written and mutated in the running guest at backup time — including
the specific incremental delta (the marker line), which would be absent if
the incremental backup were empty, stale, or failed to apply.

**Not proven by this step:** that the reconstructed disk is *bootable* as a
full VirtualMachineInstance (this only reads files from it; it does not boot
a second VM). If that guarantee is needed, see the note in
`docs/vm-cbt-workflow.md` about the alternative "boot a second VM" approach
that was considered and intentionally deferred in favor of this faster,
deterministic, non-flaky file-level check.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` on `hello-restore-verify` | `RESTORE_HELPER_IMAGE` unset, mistyped, or not pushed | Confirm `podman push` succeeded and the tag in `.env` matches exactly |
| `qemu-img: Could not change the backing file ...: backing format must be specified` | Older `qemu-img` requires an explicit `-F qcow2` on `rebase` | Already fixed in the current manifest; if you see this, your copy predates that fix |
| `libguestfs: error: cannot find any suitable libguestfs supermin ...` | Only relevant if reverting to a libguestfs-based approach; the appliance path env var isn't inherited when the container command is overridden | N/A for the current mount-based approach, which does not use libguestfs |
| `mount: unknown filesystem type 'ext4'` | Helper image's kernel/mount tooling doesn't support ext4 (very unlikely on any modern Linux) | Use a helper base image with standard kernel/mount support; Fedora (the current base) always does |
| `losetup: ...: failed to set up loop device: No such file or directory` | Pod's own minimal `/dev` lacks real loop device nodes | Already fixed by mounting the node's `/dev` (`host-dev` volume); if you see this, your copy predates that fix |
| `ERROR: could not locate ... in the full-only restore` (intermittent) | Rare loop-device/udev race when multiple ad-hoc privileged pods share a node's loop devices | Already mitigated with `udevadm settle` + selecting the partition by size rather than position; re-run `make vm-cbt-restore-test` if it recurs |
