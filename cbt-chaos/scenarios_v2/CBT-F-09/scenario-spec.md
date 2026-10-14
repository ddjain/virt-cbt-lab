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
  - **HostPath (`cbt-demo-hpp`, the `default`/`large` manifest variant):** the storage class uses `storagePool: cbt-demo-pool`, whose 1 Ti backing disk (`/dev/sdb`, 1.5 T formatted, 331 G used) is a node-local PV **only on `d38-h18-000-r660`** (`/mnt/local-storage/cbt-demo-local-pool/wwn-0x6f4ee080760de4006720abcca844eb98`). An HPP-variant VM is therefore **guaranteed** to run on that node, and its root disk and backup destination PVCs both live on `/dev/sdb`. This is the only topology in the cluster where the Jira's target ("CBT storage filesystem on the worker node") is literally the node's local disk — the copy reads and writes the same physical device the hog writes to.
  - **ODF/Ceph (`large-odf`):** VM disk and destination PVCs are RBD volumes on remote OSDs (spread over 20 storage nodes); the node-local path only carries the RBD client traffic. An I/O hog on `/root` or any node-local path would NOT contend with the copy meaningfully.
- **Decision:** run with `MANIFEST_VARIANT=default` (HostPath) and point the hog at the pool's parent directory `/mnt/local-storage/cbt-demo-local-pool` on `d38-h18-000-r660`. This satisfies the issue's wording exactly (storage filesystem backing CBT on the VM's node), makes node placement deterministic (HPP forces `d38-h18`), and makes contention measurable (same `/dev/sdb`).
- **Hog mechanism (verified from the actual `workload-krkn-hog` image, quay digest pinned by krknctl):** privileged pod on the selected node, hostPath-mounting `--node-mount-path` as the stress path; runs `stress-ng --hdd <workers> --hdd-bytes <bytes> --hdd-write-size <block> --timeout <duration>` writing into that directory, then exits. Files are removed on pod exit.
- **Disk sizing for contention:** pool disk has ~1.2 T free; 8 workers × 2 GiB each = 16 GiB per run — negligible fill (<1.4%), meaningful write pressure (8 parallel 1 MiB-block writers).
- **krkn node-selector is static** but deterministic placement makes that moot: `--node-selector kubernetes.io/hostname=d38-h18-000-r660` always targets the VM's node for an HPP-variant run. The trigger still fail-closes if the VM lands elsewhere (pre-run VMI nodeName guard; run is INVALID if mismatched, not a product result).
- **Baseline duration:** `.env`-default workload (1000 × 15–20 MiB ≈ 17 GiB) on HostPath measured ~52–55 s (F-06/F-07 runs with the identical workload/variant). The Jira's "~29 s" refers to a smaller baseline; the comparison uses the measured same-workload no-chaos baseline (~52–55 s). `--chaos-duration 90` per the issue covers the whole copy window with overlap.

## 3. Workflow and prerequisites

`make e2e TYPE=full NAME="$RUN_ID"` with `VM_OS=rhel9`, `MANIFEST_VARIANT=default` (force-set; `.env` pre-exports `large-odf`), `.env`-default guest workload (forwarded explicitly). Follow-up planned incremental pass + restore verification afterwards (success path).

Prerequisites: `d38-h18-000-r660` Ready with the HPP pool PV attached; exactly one `hpp-pool-cbt-demo-pool-*` pod; no other I/O-sensitive campaign run in flight (the hog adds node-wide disk pressure on the shared pool — serialize with other HPP-variant scenarios); unique `RUN_ID`.

## 4. Target and validated disruption

**Primary (krknctl, native command trigger):**

```sh
krknctl run node-io-hog \
  --namespace hog-ns-cbtf09 \
  --node-selector "kubernetes.io/hostname=d38-h18-000-r660" \
  --node-mount-path /mnt/local-storage/cbt-demo-local-pool \
  --chaos-duration 90 \
  --io-workers 8 \
  --io-write-bytes 2g \
  --io-block-size 1m \
  --trigger-command "<active-copy compound condition on vm-backup-$RUN_ID>" \
  --trigger-expected-rc 0 \
  --triggers-interval 3 \
  --triggers-timeout 1800 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
```

- The compound active-copy condition (Progressing=True AND Done≠True) uses the command-trigger quoting pattern proven in F-07/F-08 (single-quoted JSONPath inside `$(...)`; exact expanded string validated via `bash -c` before the run).
- krknctl starts before `make e2e` to absorb startup; hog namespace is created by the trigger (krkn needs an existing namespace — `kubectl create namespace` first; the trigger creates and later deletes it).
- `--node-mount-path` is the pool parent dir (exists on every node; writable by the privileged hog pod; the pool subdirectory itself is PVC-mounted into the hpp-pool pod and would also work, but the parent avoids writing inside the PVC tree the pool pod manages).

**Pre-run guards in trigger:** VM's VMI nodeName must equal `d38-h18-000-r660` once Running (else abort as harness-invalid); pool deployment/pod must exist; hog namespace absent.

**Fallback:** none needed — krkn expresses the target, node, path, and compound timing natively.

## 5. Deterministic injection signal

Command trigger on `vm-backup-${RUN_ID}`: `Progressing=True` AND `Done≠True`, 3 s poll. The hog starts when the copy is in flight and runs 90 s (covering the entire remaining copy window). The observer records: trigger satisfaction time, hog pod creation/node/path (from pod spec), backup terminal time, backup duration (vs. ~52–55 s baseline), tracker state, restore results.

**Chaos duration:** 90 s per the issue.

## 6. Pass/fail criteria

A product **pass** requires all:

- Injection: hog pod scheduled on `d38-h18-000-r660` with the pool path mounted, running during the copy window (pod Running timestamps inside window; VM VMI node == hog node).
- Backup completes successfully: `Done=True`, reason `Successfully completed VirtualMachineBackup`, `status.type=Full`, one checkpoint, expected included volumes, tracker advanced exactly once.
- **Duration degradation is observable but correctness preserved**: backup duration > baseline (~52–55 s) is the expected signal, but the verdict criterion is correctness (completion + data), per "should take longer … but still complete successfully and produce correct data". If duration shows no degradation, note it as an observation (contention may be absorbed by page cache; not a failure of backup correctness) — record actual duration either way.
- VM/VMI Running/Ready with CBT `Enabled` throughout; no VMI pause/migration caused by pressure.
- Post-chaos same-VM verification: planned incremental pass + restore verification pass (file counts, bytes, manifest hashes match).
- Hog cleanup: hog pod exits after 90 s; stress files removed (pod exit); hog namespace deleted by trigger; no leftover state on the node.

**Evidence:** hog pod YAML (spec.nodeName, volumeMounts, env) in run dir; vmbackup conditions/reason + duration; tracker snapshot; summary.json timings (`backups.full.duration_seconds`); restore-verify log; observer streams.

## 7. Blast radius, recovery, and conflicts

Single-node I/O pressure on `d38-h18-000-r660` for 90 s: affects any workload using the HPP pool disk or node-local I/O on that node at that moment (11 idle campaign VMs' launcher pods are Running there but quiescent; the pre-existing unrelated `vm-cbt-demo` VMI is NotReady and untouched). 16 GiB of transient writes on a 1.2 T-free disk — no fill risk. Hog pod is privileged with hostPath — standard krkn mechanism, cluster-scoped blast limited to the one node. Recovery is automatic (pod exits at timeout). Serialize with other HPP-variant scenario runs.

Unresolved/uncertain: how much wall-clock degradation 8 stress-ng hdd workers cause on a largely idle 1.5 T disk with page-cache absorption — measured empirically by this run; the pass criterion is correctness, degradation magnitude is an observation.
