# Scenario: Sustained I/O contention on the CBT storage path during a full backup

- **Jira:** CBT-F-09 — Create sustained storage I/O contention during a full backup
- **Priority:** P1
- **Technical scenario:** node-io-hog
- **Chaos phase:** Active operation

## 1. Jira objective and hypothesis

Measure how a full backup behaves when the underlying CBT storage filesystem is under sustained I/O pressure. A privileged hog pod runs `stress-ng --hdd` workers writing large files directly onto the node directory that backs the CBT storage, for the whole duration of the active copy. Expected: the backup takes **longer than the ~29 s baseline** but still completes successfully with correct data; the tracker advances; restore hashes match. This measures performance degradation while preserving backup correctness.

Issue fields: workflow **Full backup**; target **CBT storage filesystem on the worker node**; action **generate controlled I/O load on the CBT storage path**; timing **during the active disk-copy period**; signal **full backup is actively copying**; duration **90 seconds**; recovery **I/O load stops automatically**; verification **compare backup duration vs. baseline, successful completion and checkpoint advancement, restored data hash match**.

## 2. Evidence and live target resolution

- **What the "CBT storage filesystem on the worker node" concretely is on this cluster:** every campaign VM is scheduled onto `d38-h18-000-r660` (the only node whose labels satisfy the launcher's machine-type/obsolete-host-model constraints in practice — all 11 vm-cbt-demo launchers run there; 27 of 31 nodes lack `devices.kubevirt.io/kvm` allocatable entirely). Two storage backends are possible for the demo:
  - **HostPath (`cbt-demo-hpp`, the `default`/`large` manifest variant):** the storage class uses `storagePool: cbt-demo-pool`, whose 1 Ti backing disk (`/dev/sdb`, 1.5 T formatted, 79% used, ~340 G free at preparation time) is a node-local PV **only on `d38-h18-000-r660`**. The pool's PVC (`hpp-pool-cbt-demo-pool-d38-h18-000-r660`) is bound to that local PV, and the live mount table shows `/dev/sdb` mounted at **`/var/hpvolumes/csi`**, which holds every `pvc-<uid>` directory (VM root disk and full/incremental backup destinations). An HPP-variant VM is therefore **guaranteed** to run on that node, and its root disk and backup destination PVCs both live on `/dev/sdb`. This is the only topology in the cluster where the Jira's target ("CBT storage filesystem on the worker node") is literally the node's local disk — the copy reads and writes the same physical device the hog writes to.
- **Correction (preparation-time live measurement, 2026-10-18):** the earlier note that `/mnt/local-storage/cbt-demo-local-pool/…` is the `/dev/sdb` path is wrong. `findmnt -T /mnt/local-storage/cbt-demo-local-pool` resolves to `/dev/sda4` (the node root disk, 446 G), because that directory is only the local-volume discovery parent containing a device symlink. A hostPath stress pod pointed there would contend the *wrong device* — the same class of silent wrong-target defect as the krknctl flag bug below. The approved hostPath is `/var/hpvolumes/csi`, guarded against the live mount source before the window.
  - **ODF/Ceph (`large-odf`):** VM disk and destination PVCs are RBD volumes on remote OSDs (spread over 20 storage nodes); the node-local path only carries the RBD client traffic. An I/O hog on `/root` or any node-local path would NOT contend with the copy meaningfully.
- **Decision:** run with `MANIFEST_VARIANT=default` (HostPath) and point the hog at `/var/hpvolumes/csi` on `d38-h18-000-r660`, the live mount of the pool device `/dev/sdb`. This satisfies the issue's wording exactly (storage filesystem backing CBT on the VM's node), makes node placement deterministic (HPP forces `d38-h18`), and makes contention measurable (same `/dev/sdb`). The host path is not hardcoded blindly: `iostat-collector.sh --probe` asserts `findmnt -T /var/hpvolumes/csi` → `/dev/sdb` and `/proc/diskstats` contains `sdb` before any lifecycle stage runs (BLOCKED otherwise).
- **Hog mechanism (direct, run-owned; see §4):** privileged pod pinned to the selected node with a hostPath volume at the approved path; runs `stress-ng --hdd <workers> --hdd-bytes <bytes> --hdd-write-size <block> --timeout <duration>` inside a run-scoped subdirectory it creates and removes, then exits. The pod spec is captured live from the API and asserted against the approved path (never the injector's telemetry).
- **Disk sizing for contention:** the pool device has ~340 G free; 8 workers × 2 GiB each = 16 GiB per run — negligible fill (<5%), meaningful write pressure (8 parallel 1 MiB-block writers).
- **Static node selector** makes placement deterministic: the stress pod is pinned with `kubernetes.io/hostname=d38-h18-000-r660`, and the run fail-closes if the VM lands elsewhere (post-setup VMI nodeName + root PV node-affinity guard; the attempt is HARNESS-INVALID if mismatched, not a product result).
- **Baseline duration:** `.env`-default workload (1000 × 15–20 MiB ≈ 17 GiB) on HostPath measured ~52–55 s (F-06/F-07 runs with the identical workload/variant). The Jira's "~29 s" refers to a smaller baseline; the comparison uses the measured same-workload no-chaos baseline (~52–55 s). The 90 s fault duration per the issue covers the whole copy window with overlap.

## 3. Workflow and prerequisites

The driver runs the same staged targets `make e2e` uses, one owner each: `make preflight`, then `make vm-setup RUN_ID=<lifecycle>`, `make vm-backup RUN_ID=<lifecycle>` (the injection window), and on success `make vm-cbt-backup` then `make vm-cbt-verify`, plus `make run-summary` and `make monitor`. `VM_OS=rhel9`, `MANIFEST_VARIANT=default` (force-set; the execution `.env` pre-exports `large-odf`), and the `.env`-default guest workload (1000 base files 15–20 MiB, 4 incremental files, 1 pass) are forwarded explicitly on every make command line. `MANIFEST_VARIANT=default` on rhel9 resolves to the large HPP manifests (`vm-large.yaml`, `full-backup-large.yaml`, `incremental-backup-large.yaml`).

Prerequisites: `d38-h18-000-r660` Ready with the HPP pool PV attached; exactly one `hpp-pool-cbt-demo-pool-*` pod; no other I/O-sensitive campaign run in flight (the hog adds node-wide disk pressure on the shared pool — serialize with other HPP-variant scenarios); unique `RUN_ID`.

## 4. Target and validated disruption

**Primary: direct run-owned hostPath stress pod (bounded, trigger-gated).**

> Mechanism change (2026-10-18): the krknctl v0.14.2-beta `node-io-hog` flag path
> is defective — it accepts `--node-mount-path` but silently mounts hostPath
> `/tmp` (ram-backed tmpfs) because of a krkn-lib 7.0.3 key mismatch. See
> `cbt-chaos/scenarios_v2/CBT-EXP-09/bugs/krknctl-node-io-hog-ignores-node-mount-path-writes-to-tmp-tmpfs.md`
> (raw pod specs from EXP-09 attempt 2 and the F-09 r01 corroborating run).
> The approved fault, parameters, node, window and compound trigger are
> unchanged; only the delivery mechanism is replaced by the same direct
> privileged-pod pattern proven in CBT-EXP-09 iteration 3.

The run-owned helper `direct-trigger.sh` polls the approved compound active-copy
condition (fail-closed on timeout), captures the raw `VirtualMachineBackup`
snapshot **before** acting, then creates exactly one privileged pod on the hog
node:

- `nodeSelector: kubernetes.io/hostname=d38-h18-000-r660`;
- one hostPath volume `node-volume` at **`/var/hpvolumes/csi`** (`type: Directory`)
  mounted at `/hog-data`, writing only under a run-scoped subdirectory
  `/hog-data/f09-<lifecycle>`;
- `stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --timeout 90s`
  (8 parallel 1 MiB-block writers, 16 GiB transient);
- image `quay.io/krkn-chaos/krkn-hub-multiarch@sha256:9b2000bb550cd23e46d9070ed23e40fb90c9f8476eac0e52a678fa3280fd2c82`
  (the digest already used by the proven direct pattern; never retagged);
- `restartPolicy: Never`; the pod exits by itself after the 90 s stress-ng
  timeout, removes its own subdirectory when empty, reports the removal in its
  termination message, and is then deleted (`--ignore-not-found --wait=false`).

The driver asserts the **live** pod object (`.spec.nodeName` and
`.spec.volumes[].hostPath.path`) against the approved values and fails closed on
any mismatch; krkn telemetry is not trusted anywhere in this bundle.

Execution ownership: `run.sh` creates the hog namespace
(`hog-ns-<lifecycle>`), starts the trigger and device-telemetry collectors, and
waits for both readiness markers before `make vm-setup`. The compound condition
cannot become true before `make vm-backup` creates the backup object, so the
trigger is armed early without starting the fault early.

**Pre-run guards (all read-only, all fail-closed):** node Ready + KVM
allocatable; exactly one `hpp-pool-cbt-demo-pool-*` pod Running on the hog node;
pool free ≥ 200 GiB measured through the pool mounter; HPP pool
`cbt-demo-pool` defined at `/var/hpvolumes`; `findmnt -T /var/hpvolumes/csi` →
`/dev/sdb` and `/proc/diskstats` contains `sdb` (the exact device-identity
check); VM’s VMI nodeName and root PV node-affinity equal `d38-h18-000-r660`
(after setup, before the window); hog namespace absent; no lifecycle resources
present; co-tenant VMI inventory recorded.

**Fallback:** none. krkn cannot express a trustworthy target path on this
installation (the flag path is broken and the upstream YAML workaround is not
installed), so the direct privileged pod is the supported expression of the
same fault. Read-only `oc` queries used for the condition and evidence are not
a fault-action fallback.

## 5. Deterministic injection signal

Command trigger on `vm-backup-${RUN_ID}`: `Progressing=True` AND `Done≠True`,
3 s poll, bounded at 1200 s with **fail on timeout**. On satisfaction the helper
captures the raw condition snapshot, creates the stress pod, and records its own
action statuses separately. The observer records: trigger satisfaction time,
live pod node/hostPath, Running window, backup terminal time, backup duration
(vs the measured 52–55 s uncontended RHEL baseline), tracker state, restore
results.

**Device telemetry ride-along (new):** `iostat-collector.sh` runs one bounded,
read-only `oc debug node/d38-h18-000-r660 -- chroot /host bash -c` session from
before the window until after the copy window closes. Every sample is keyed by
segment + loop index and records the approved device's `/proc/diskstats` counters,
`df` and the session mode. `iostat` is **not installed** in this RHCOS host
image (verified: `chroot /host iostat` → command not found), so the collector
uses `/proc/diskstats` and records `telemetry_mode=proc-diskstats`; if `iostat`
is present it is captured as supplementary detail. A dead session gets one
segment-preserving re-arm; if it cannot be restored before the window the run is
BLOCKED. Unavailable telemetry is recorded UNKNOWN — never as an idle device.
This is the observation that separates page-cache absorption from real
block-layer contention (CBT-EXP-09 iteration-3 limitation).

**Guest access:** the RHEL `.env`-default workload uses the SSH-over-port-forward
transport (`GUEST_KEY`, generated by `make vm-setup` when missing). The
Windows/QGA `guest-unfreeze` ride-along is intentionally out of scope here; §6
requires the planned incremental pass plus restore verification, which exercise
the same data.

**Chaos duration:** 90 s per the issue (the stress pod's own `--timeout`).

## 6. Pass/fail criteria

A product **pass** requires all:

- Injection: hog pod scheduled on `d38-h18-000-r660` with the pool path mounted, running during the copy window (pod Running timestamps inside window; VM VMI node == hog node).
- Backup completes successfully: `Done=True`, reason `Successfully completed VirtualMachineBackup`, `status.type=Full`, one checkpoint, expected included volumes, tracker advanced exactly once.
- **Duration degradation is observable but correctness preserved**: backup duration > baseline (~52–55 s) is the expected signal, but the verdict criterion is correctness (completion + data), per "should take longer … but still complete successfully and produce correct data". If duration shows no degradation, note it as an observation (contention may be absorbed by page cache; not a failure of backup correctness) — record actual duration either way.
- VM/VMI Running/Ready with CBT `Enabled` throughout; no VMI pause/migration caused by pressure.
- Post-chaos same-VM verification: planned incremental pass + restore verification pass (file counts, bytes, manifest hashes match).
- Hog cleanup: the pod exits after 90 s and removes its run-scoped stress subdirectory (reported in its termination message); `run.sh` deletes the pod (fallback) and the run-scoped `hog-ns-<lifecycle>` namespace; no leftover stress files on the node (bounded post-terminal residue probe).

**Evidence:** hog pod YAML (live spec.nodeName, hostPath, volumeMounts) and the raw trigger-condition snapshot in the run dir; vmbackup conditions/reason + duration; tracker snapshot; summary.json timings (`backups.full.duration_seconds`); restore-verify log; observer streams; device telemetry (`observer/iostat/samples/`, raw `/proc/diskstats` segments) and the duration-comparison JSON. Injection validity is decided by the independent Analyst from these raw artifacts, not by any success line.

## 7. Blast radius, recovery, and conflicts

Single-node I/O pressure on `d38-h18-000-r660` for 90 s: affects any workload using the HPP pool disk or node-local I/O on that node at that moment (11 idle campaign VMs' launcher pods are Running there but quiescent; the pre-existing unrelated `vm-cbt-demo` VMI is NotReady and untouched). 16 GiB of transient writes on a 1.2 T-free disk — no fill risk. Hog pod is privileged with hostPath — standard krkn mechanism, cluster-scoped blast limited to the one node. Recovery is automatic (pod exits at timeout). Serialize with other HPP-variant scenario runs.

Unresolved/uncertain: how much wall-clock degradation 8 stress-ng hdd workers cause on a largely idle 1.5 T disk with page-cache absorption — measured empirically by this run; the pass criterion is correctness, degradation magnitude is an observation.
