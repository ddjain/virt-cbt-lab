# QE Chaos-Testing Plan: KubeVirt Native VirtualMachineBackup/CBT Mechanism

**Date:** 2026-09-30
**Investigator:** fresh, independent investigation per AGENTS.md evidence hierarchy — live cluster on `<target-host>` → actual scripts in `/path/to/cbt-setup` → actual manifests → executed/observed behavior → Krkn source → inference.
**System under test:** the real KubeVirt `backup.kubevirt.io/v1alpha1` `VirtualMachineBackup`/`VirtualMachineBackupTracker` mechanism (part of the installed HCO 4.22.9 / virt-operator stack, **not** a custom third-party controller). `make e2e` on `/path/to/cbt-setup` is only the orchestration harness.
**Chaos executed:** none. Only read-only inspection plus the pipeline's own normal, non-destructive steps were run. `make clean-all` was attempted but blocked by the local sandbox's destructive-action classifier, so this investigation reused the completed full+incremental backup already present in the `vm-cbt-demo` namespace from a prior 2026-09-29 run, and independently re-derived the state machine from `oc get/describe/logs -o yaml`, `oc events`, and `virt-launcher`/`virt-controller` container logs for that run's timestamps (20:01:xx UTC), plus a fresh `./preflight` execution.

Evidence-type legend: **OBSERVED** (seen live on <target-host> this session) · **SOURCE** (read directly from script/manifest/CRD/log text) · **DOCUMENTED** (Krkn docs) · **INFERRED** (reasoned, not directly observed) · **UNKNOWN**.

---

## A. Discovered CBT Architecture

**Evidence:** `oc get crd virtualmachinebackups.backup.kubevirt.io -o yaml` shows `labels: app.kubernetes.io/managed-by: virt-operator, app.kubernetes.io/part-of: hyperconverged-cluster, app.kubernetes.io/version: 4.22.9`.
**Observation:** the `VirtualMachineBackup`/`VirtualMachineBackupTracker` CRDs are installed and owned by `virt-operator` itself, versioned with the rest of KubeVirt (4.22.9) — this is KubeVirt's own in-tree "Push mode" VM backup API, not a bolt-on operator.
**Conclusion:** the real implementation to reason about is virt-controller + virt-launcher + virt-handler, not a separate backup service.
**Evidence Type:** OBSERVED + SOURCE.

### A.1 Components actually involved (OBSERVED, `vm-cbt-demo` namespace)

| Component | Role | Evidence |
|---|---|---|
| `VirtualMachine`/`VirtualMachineInstance vm-cbt-demo` | Guest; `.status.changedBlockTracking.state=Enabled` is the CBT enablement signal | OBSERVED |
| `virt-launcher-vm-cbt-demo-*` pod (`compute` container) | Runs QEMU **and** the actual backup job code (`backup.go`) in-process | OBSERVED: `oc logs -c compute` shows `component:"virt-launcher"` log lines `pos:"backup.go:60/74/83/121/181/194/324/366"` doing the backup itself — there is **no separate export/backup pod** |
| `hp-volume-*` hotplug attachment pods | Short-lived pods KubeVirt creates to hotplug the backup destination PVC as a block device into the running VMI | OBSERVED via `oc get events`: `SuccessfulCreate ... Created hotplug attachment pod hp-volume-pdwnz, for volume hello-full-backup-target-pvc` |
| `virt-controller` (2 replicas, `openshift-cnv`) | Reconciles `VirtualMachineBackup`/`VirtualMachineBackupTracker` objects, drives hotplug, calls into virt-launcher's backup API, updates CR status and the tracker's `latestCheckpoint` | OBSERVED in `oc logs -l kubevirt.io=virt-controller`: `pos:"backup.go:1336"` `"Successfully updated BackupTracker ... with checkpoint ..."`, `pos:"backup.go:1290"` `"Successfully completed VirtualMachineBackup"` |
| `virt-handler` (DaemonSet, one per node) | Node-local agent; per the `VirtualMachineBackupTracker` CRD schema, owns `checkpointRedefinitionRequired` — redefining libvirt checkpoints in a new libvirt instance after a VMI restart | SOURCE (CRD schema comment: *"set to true by virt-handler when the VM restarts and has a checkpoint that needs to be redefined in libvirt"*) |
| `persistent-state-for-vm-cbt-demo-<hash>` PVC | KubeVirt's per-VMI **backend-storage** PVC; mounted into virt-launcher at `/run/kubevirt-private/backend-storage-meta` (subPath `meta`) **and** at `/var/run/kubevirt-private/libvirt/qemu/cbt` (subPath `cbt`) | OBSERVED: `oc get pod ... -o yaml` volumeMounts/volumes |
| `rootdisk.qcow2` overlay | The actual CBT dirty-bitmap-bearing file. QEMU's blockdev chain is `libvirt-3-storage` (raw `disk.img` on the `vm-cbt-root` DataVolume PVC, backing) + `libvirt-2-storage`=`/var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2` (qcow2 format layer, **on the persistent-state PVC, not the root disk PVC**) | OBSERVED: full `qemu-kvm` command line in `virt-launcher` compute container log, `-blockdev` args |
| `VirtualMachineBackupTracker hello-tracker` | Anchors `.status.latestCheckpoint.name`, the checkpoint the next incremental backup diffs against | SOURCE + OBSERVED |
| `VirtualMachineBackup hello-full` / `hello-incremental` | Backup request/result CRs | SOURCE + OBSERVED |
| `hello-restore-verify` pod | Repo-supplied (not KubeVirt-native) helper that reconstructs the guest disk from the two backup PVCs via `qemu-img rebase/convert` + `btrfs restore`, and is the only real data-correctness check in the pipeline | SOURCE (`scripts/restore-lib.sh`) |

**Correction of a prior assumption (see §I):** the CBT/checkpoint state is **not** purely in-memory QEMU state. It is a qcow2 overlay file living on a dedicated per-VMI persistent PVC (`persistent-state-for-vm-cbt-demo-*`), independent of both the VM's root-disk PVC and the virt-launcher pod's own lifecycle.
**Evidence Type:** OBSERVED (blockdev args + volume mounts).

### A.2 Real data/control path (OBSERVED + SOURCE)

```
oc apply manifests/full-backup.yaml (PVC hello-full-output, VirtualMachineBackupTracker, VirtualMachineBackup hello-full)
  → virt-controller reconciles hello-full:
      - hotplugs hello-full-output PVC into the running virt-launcher pod
        (creates attachment pod hp-volume-*, waits for VolumeMountedToPod)
      - calls virt-launcher's internal backup API (local, in-pod — NOT a k8s Service call)
  → virt-launcher (backup.go, inside the compute container):
      - "Backup begin called" → freezes the VMI via qemu-guest-agent fsfreeze (~70ms)
      - thaws immediately once the backup job itself has started inside QEMU
      - QEMU executes a live block-copy of the CBT-bearing qcow2 overlay onto the
        hotplugged destination PVC (this is the actual multi-second/-minute window
        where the guest keeps running normally but the block copy is in flight)
      - "Backup has been completed successfully" → notifies virt-handler/virt-controller
        over a local Notifier channel with the checkpoint name and included volumes
  → virt-controller:
      - unhotplugs the destination PVC
      - sets VirtualMachineBackup.status.{type,checkpointName,conditions[Done]=True}
      - updates VirtualMachineBackupTracker.status.latestCheckpoint to this backup's checkpoint
For the next (incremental) backup:
  → virt-launcher log: "Generating incremental backup <name> from checkpoint: <prior checkpoint name>"
  → QEMU computes the delta using the libvirt checkpoint (dirty bitmap) chain rooted
    at that named checkpoint, confirmed via `virsh checkpoint-list <domain> --tree`
    showing a parent→child tree: hello-full-<ts> → hello-incremental-<ts>
```

**Evidence:** `virsh checkpoint-list vm-cbt-demo_vm-cbt-demo --tree` (read-only, executed via `oc exec`) returned:
```
hello-full-2026-09-29_20-01-21
  |
  +- hello-incremental-2026-09-29_20-01-43
```
**Observation:** the checkpoint chain is a real libvirt/QEMU checkpoint tree (not a metadata field invented by the CR), keyed by name and referenced by name across backup requests.
**Conclusion:** CBT correctness depends on this libvirt checkpoint tree surviving and staying consistent with what the `VirtualMachineBackup`/`VirtualMachineBackupTracker` CRs claim; a mismatch between the CR-recorded checkpoint name and the actual libvirt checkpoint tree is a concrete corruption mode.
**Evidence Type:** OBSERVED.

---

## B. Observed Backup Lifecycle (Full)

Timeline reconstructed from `virt-launcher` compute-container logs and cluster events for `hello-full` (created 2026-09-29T20:01:21Z):

1. `20:01:21` — `oc apply` creates PVC `hello-full-output`, tracker, and `VirtualMachineBackup hello-full`.
2. `20:01:2x` — hotplug attachment pod `hp-volume-pdwnz` created; event `HotplugFailed: failed to mount filesystem hotplug volume ... lstat .../disk.img: no such file or directory` fires (transient — hostpath-provisioner hadn't yet materialized `disk.img` on the freshly-bound PVC), followed by `VolumeMountedToPod` succeeding on retry.
3. `20:01:24.041` — `virt-launcher`: `"Backup begin called"` → `"Initializing backup"` → `"Freezing VMI to capture backup state"`.
4. `20:01:24.113` — `"Thawing VMI after backup job started"` (freeze window ≈72ms).
5. `20:01:24.127` — `"Backup started"`; controller receives a duplicate/retried "begin" call at `20:01:24.139` and virt-launcher correctly replies `"Backup already in progress"` (idempotent, non-fatal).
6. `20:01:41.688` (≈17.5s later) — `"Backup has been completed successfully"`; backup metadata pushed via Notifier.
7. `20:01:41` (event) — `VirtualMachineBackupCompletedSuccessfully` **and**, milliseconds apart, a `Warning VirtualMachineBackupFailed: Backup has failed: VMI backup status was lost` event on the same object.
8. `virt-controller` unhotplugs the PVC (`VolumeUnMountedFromPod`), deletes the attachment pod, sets `Done=True`, `type=Full`, `checkpointName=hello-full-2026-09-29_20-01-21`.

**Evidence:** step 7's two contradictory events for the *same, successful* backup, taken directly from `oc get events -n vm-cbt-demo`.
**Observation:** this is a real, reproducible transient false-negative signal in the current implementation — the backup genuinely succeeded (confirmed by the final `Done=True`/`checkpointName` and, independently, by the restore test in §H), but an intermediate reconciliation pass emitted a `Warning ... Failed` event before the terminal `Done=True` state was written. A monitoring/alerting system watching only for `Warning` events on `VirtualMachineBackup` objects would produce a false alarm on a perfectly good backup.
**Conclusion:** any chaos-test verification logic must key off the **terminal** `Done` condition and the restore/data check, never off the presence/absence of a `Warning` event.
**Evidence Type:** OBSERVED.

---

## C. Incremental Backup Lifecycle and CBT State Transition

1. `hello-incremental` created at `20:01:43Z`, `source=hello-tracker` (same tracker as the full backup) — this is how virt-controller identifies the base checkpoint, per the CRD's own field docs: *"When Kind is VirtualMachineBackupTracker: uses the tracker to get the source VM and the base checkpoint for incremental backup. The tracker will be updated with the new checkpoint after backup completion."* (SOURCE: CRD schema text.)
2. `20:01:46.112` — `"Previous backup hello-full completed at 20:01:41.689..., initializing new backup hello-incremental"`.
3. `20:01:46.114` — `"Generating incremental backup hello-incremental from checkpoint: hello-full-2026-09-29_20-01-21"` — **explicit, named reference to the prior checkpoint**, not an implicit "latest state" diff.
4. `20:01:46.177` — thaw; `20:01:46.182` — `"Backup started"`; `20:01:46.187` — `"Backup has been completed successfully"` (≈5ms of actual copy time for this tiny disk delta — the guest only appended one line to a text file).
5. `20:01:46.207` — a **second** `"Backup begin called"` arrives for `hello-incremental` and is correctly rejected: `"Failed to initialize backup metadata" reason:"backup hello-incremental that started at ... already executed, finished at ..., completed: true"`.
6. `virt-controller` logs explain the duplicate call: `"failed to update backup status" reason:"Operation cannot be fulfilled on virtualmachinebackups.backup.kubevirt.io \"hello-incremental\": the object has been modified; please apply your changes to the latest version and try again"` → `"reenqueuing VirtualMachineBackup vm-cbt-demo/hello-incremental"`.

**Evidence:** virt-controller log text above (SOURCE/OBSERVED, exact log lines).
**Observation:** the duplicate backup-begin call is caused by a standard Kubernetes optimistic-concurrency conflict (stale `resourceVersion`) during controller reconciliation, which triggers a requeue that re-executes the reconcile function, including a second call into virt-launcher's backup API. virt-launcher's own idempotency check (`"already executed ... completed: true"`) is what prevents this from corrupting anything.
**Conclusion:** the backup pipeline already has one real concurrency hazard baked in (duplicate begin calls under controller requeue) that is currently harmless only because virt-launcher's backup state machine checks for a matching, already-completed backup name+start-time. A chaos scenario that widens the race window (e.g., slowing virt-launcher's gRPC/socket response, or killing/restarting virt-controller mid-reconcile) is a direct, source-grounded way to stress this exact safety check rather than a speculative one.
**Evidence Type:** OBSERVED + SOURCE.

### C.1 What proves the incremental backup is really incremental

- **SOURCE**: the explicit log line naming the base checkpoint (`"Generating incremental backup ... from checkpoint: hello-full-..."`).
- **SOURCE**: `virsh checkpoint-list --tree` shows a real parent→child checkpoint tree, not two independent checkpoints.
- **SOURCE** (`scripts/vm-cbt-restore-test.sh` + `restore-lib.sh`): the repo's own Tier-B check rebases the incremental qcow2 onto the full qcow2 via `qemu-img rebase`, converts both to raw, and reads the guest file via `btrfs restore`, asserting: (a) the full-only restore's SHA-256 matches the hash captured live from the guest *before* the incremental mutation, and does **not** contain the marker line; (b) the full+incremental restore's SHA-256 matches the hash captured *after* the mutation, and **does** contain the marker line. This is real data-level proof, not just CR-field trust.
- **Gap (INFERRED, not exercised by this repo's scripts):** nothing in the pipeline asserts the incremental qcow2's `backing_file`/cluster-allocation count independently — i.e., nothing distinguishes "true CBT delta" from "incidentally-correct full re-copy" except that the artifact sizes differ enough to be practically distinguishable. This matches a gap already flagged in the pre-existing `cbt-verification-report.md` (see §I).

---

## D. Failure Boundaries

| Boundary | Component | Real risk | Evidence |
|---|---|---|---|
| Hotplug-attach race | virt-controller ↔ hostpath-provisioner ↔ virt-launcher | Backup destination PVC's `disk.img` may not exist yet when the hotplug mount is first attempted (`HotplugFailed: ... no such file or directory`), currently masked by an internal retry | OBSERVED event, self-healed in both backups observed |
| Freeze/thaw window | virt-launcher ↔ qemu-guest-agent (local virtio-serial, not network) | ~70ms guest filesystem freeze to get a crash-consistent starting point; a slow/unresponsive guest agent here could stall backup start | OBSERVED timestamps; INFERRED effect of agent unresponsiveness |
| Live block-copy window | QEMU inside virt-launcher, writing to the hotplugged destination PVC on **local hostpath storage** | The only window with real, sustained I/O; a full 30Gi disk sized realistically (rather than this tiny demo disk) would keep this window open for a meaningful time. Node/storage disruption here directly risks a truncated destination PVC | OBSERVED (log timestamps bound the window); INFERRED effect of interrupting it (untested — no chaos executed) |
| Controller reconcile duplicate-call race | virt-controller (resourceVersion conflict → reenqueue → duplicate begin call) | Currently masked by virt-launcher's own idempotency guard; widening this race (slow socket, controller restart mid-reconcile) is the most source-grounded correctness probe available | OBSERVED (§C) |
| CBT checkpoint persistence | qcow2 overlay (`rootdisk.qcow2`) on the per-VMI **persistent-state PVC**, decoupled from virt-launcher pod lifecycle and from the VM root-disk PVC | This PVC is itself single-node local storage (same `cbt-demo-hpp` StorageClass). I/O errors or loss of this specific PVC breaks the checkpoint chain independent of the root disk or the backup destination PVCs | OBSERVED (volume mounts); INFERRED consequence |
| Checkpoint redefinition after VMI restart | virt-handler, `VirtualMachineBackupTracker.status.checkpointRedefinitionRequired` | CRD schema documents that virt-handler must redefine libvirt checkpoints after a VM restart. Whether this redefinition succeeds under an interrupted/killed virt-handler, or when the persistent-state PVC content is stale/partial, is **UNKNOWN** — not exercised in this observation window (no restart occurred) | SOURCE (CRD field doc) only; UNKNOWN behavior |
| Backup destination capacity | `hello-full-output`/`hello-incremental-output` PVCs | Local hostpath storage; a live block-copy that runs out of destination space mid-copy is untested — does `VirtualMachineBackup` report a clean failed condition, or can `Done=True` still be reached over a truncated file? | UNKNOWN (not observed; the repo's own scripts never induce this) |

---

## E. Chaos Injection Points (deterministic, not sleep-based)

For each: the observable condition to trigger on is a `VirtualMachineBackup.status.conditions[?(@.type=="Progressing")].status==True` (i.e., backup created but not yet `Done`) combined, where possible, with tailing `virt-launcher`'s compute container log for the specific `"Backup started"` line for the target backup name — this is the real, source-confirmed start of the live block-copy window (§B step 5 / §C step 4), as opposed to CR-creation time which includes the hotplug-attach race window (§D row 1) as a distinct, separately-interesting window.

1. **Injection point 1 — during the live block-copy** (`"Backup started"` logged, before `"Backup has been completed successfully"`).
   - Component affected: virt-launcher pod (compute container/QEMU) and/or the node hosting it and the hotplugged destination PVC.
   - Operation in progress: QEMU block-copy from the CBT qcow2 overlay to the destination PVC.
   - Why it matters: this is the only window with sustained state mutation to the backup artifact; any interruption here is the single most direct way to test whether `Done=True` can ever be reached over an incomplete/corrupt artifact (a false positive in the exact sense the AGENTS/task brief cares about).
   - What could go wrong: truncated backup PVC content reported as `Done=True`; or the block-copy silently restarts as a full copy on retry, invalidating an intended incremental test.
   - Expected recovery (INFERRED, unverified): virt-controller re-enqueues and would presumably retry `Backup begin` on the same object once the transient failure clears — the exact idempotency guard observed in §C should apply, but has not been tested against a genuine (not merely racy) failure.
   - Verification: `Done` condition final value + `checkpointName` set + Tier-B restore-test (rebuild both full-only and full+incremental disks, hash + marker-line check) — **never** trust the transient `Warning` events alone (§B).

2. **Injection point 2 — the hotplug-attach race** (backup CR created, `hp-volume-*` attachment pod scheduled, before `VolumeMountedToPod`).
   - Component: hostpath-provisioner CSI path + virt-controller's hotplug logic.
   - Why it matters: already flaky under normal conditions (`HotplugFailed` observed even with zero injected chaos); widening this window (slow/disrupted storage) tests whether the existing retry has a bound, or can wedge the backup CR indefinitely.
   - Verification: whether `VirtualMachineBackup` eventually reaches `Done=True`/`Progressing=False` or times out cleanly; no artifact-correctness claim applies here since no bytes have been copied yet.

3. **Injection point 3 — between full completion and incremental start, before guest mutation** (`hello-tracker.status.latestCheckpoint.name == full checkpoint`, no incremental CR yet).
   - Component: virt-launcher pod / node (VMI restart), or the persistent-state PVC.
   - Why it matters: this is the only way to test the `checkpointRedefinitionRequired` path (§D) in isolation, without conflating it with an in-flight copy. A VMI restart here (pod kill, forcing KubeVirt's `runStrategy: Always` to recreate it) is the deterministic, source-grounded way to exercise checkpoint redefinition.
   - Expected recovery: SOURCE says virt-handler sets/clears `checkpointRedefinitionRequired` and virt-controller processes it; whether the subsequent incremental backup still correctly diffs against the pre-restart checkpoint, or virt-launcher/libvirt loses the bitmap and silently produces a full-sized "incremental" is **UNKNOWN and the single highest-value untested question** this investigation surfaced.
   - Verification: after restart, run the incremental step and check (a) `type=Incremental` is still reported, (b) artifact size is still delta-sized, (c) `virsh checkpoint-list --tree` still shows the expected parent→child relationship, (d) Tier-B restore test still matches expected hashes.

4. **Injection point 4 — reconcile-duplicate race amplification** (any point where virt-controller would naturally retry, e.g. immediately after `Done=True` is first computed).
   - Component: virt-controller.
   - Why it matters: §C already shows this race exists under normal load; a controller pod kill/restart at this exact moment tests whether the idempotency guard (matching backup name + start time + completed:true) holds under a harder failure than a simple resourceVersion conflict — e.g., whether a *different* virt-controller replica retrying after a leader-election failover could get a stale view and re-trigger a backup, potentially producing a second, conflicting checkpoint for the same name.

---

## F. Krkn Mapping

Only scenarios and parameter names found directly in `/Users/darjain/projects/krkn-chaos/website` are used; everything else is marked NEEDS VALIDATION. `krknctl`/exact CLI invocation strings are not fabricated — only `SCENARIO_TYPE`/parameter names confirmed from the doc-synced YAML files are cited.

| Krkn scenario (confirmed name) | Source doc | Affected CBT dependency | Maps to injection point |
|---|---|---|---|
| `kubevirt_vm_outage` (`SCENARIO_TYPE: kubevirt_vm_outage`, docs: `content/en/docs/scenarios/kubevirt-outage/`) | `_tab-krkn.md`, `_index.md` | Deletes the VMI (`vm_name`, `namespace`, `kill_count`, `disable_auto_restart` params confirmed) | Injection point 3 (VMI restart between full and incremental) |
| `vmi-network` (krkn-hub id `vmi-network`) | `content/en/docs/scenarios/network-chaos-ng-scenarios/vmi-network/_index.md` | Shapes bandwidth/latency/loss on the VM's own tap interface inside the virt-launcher netns, isolated from node-wide OVN/BFD | Guest-mutation SSH path (`common.sh:guest_ssh`) between full and incremental — **not** the backup-copy path itself, since that path is local-node I/O, not pod-network-dependent (confirmed by the qemu blockdev args using local `file` driver, not NBD-over-network) |
| `vmi-network-filter` (krkn-hub id `vmi-network-filter`) | same dir, `vmi-network-filter/_index.md` | iptables-based selective port/protocol block on VM tap0 via nsenter | Same as above; useful to isolate SSH-only (port 22) outage from full network loss |
| `pod_disruption_scenarios` (`SCENARIO_TYPE: pod_disruption_scenarios`, params `POD_LABEL`/`NAME_PATTERN`/`NAMESPACE`/`FORCE`/`DISRUPTION_COUNT`) | `data/params/pod-scenarios/krkn-hub.yaml` | Kills the `virt-launcher-vm-cbt-demo-*` pod (matches by `NAME_PATTERN` in `vm-cbt-demo` namespace) directly during injection point 1, or the `hp-volume-*` attachment pod for injection point 2 | Injection points 1, 2, 4 (also usable against a `virt-controller` replica in `openshift-cnv` for point 4) |
| `node_scenarios` (`SCENARIO_TYPE: node_scenarios`, `ACTION: node_stop_start_scenario` confirmed default, params `NODE_NAME`/`LABEL_SELECTOR`/`DURATION`) | `data/params/node-scenarios/krkn-hub.yaml` | Stops/starts the node hosting virt-launcher, the hotplugged PVC, and the persistent-state PVC (all node-pinned local storage) | Injection point 1 (harder variant) and 3 |
| `pvc_scenarios` (`SCENARIO_TYPE: pvc_scenarios`, params `PVC_NAME`/`FILL_PERCENTAGE`/`DURATION`/`BLOCK_SIZE`) | `data/params/pvc-scenario/krkn-hub.yaml` | Fills a target PVC to a percentage for a duration — directly usable against `hello-full-output`/`hello-incremental-output` during the copy window, or against `persistent-state-for-vm-cbt-demo-*` to test checkpoint-write failure independent of backup-artifact failure | Injection point 1 (destination-full case) and a new checkpoint-storage-pressure case not previously identified |
| `storage_throttle_scenarios` (`SCENARIO_TYPE: storage_throttle_scenarios`, params `PVC_NAME`/`THROTTLE_TYPE`/`READ_IOPS`/`WRITE_IOPS`/`READ_BPS`/`WRITE_BPS`/`DURATION`) | `data/params/storage-throttle/krkn-hub.yaml` | Throttles bandwidth/IOPS on a target PVC via cgroup — widens the block-copy window (injection point 1) deterministically and reversibly, without an outright failure, useful for testing whether a *slow* (not failed) copy can still race the controller's reconcile-duplicate path (§C/point 4) | Injection points 1 and 4 |
| `hog_scenarios` (`SCENARIO_TYPE: hog_scenarios`, `SCENARIO_FILE: scenarios/kube/io-hog.yml`, node-level I/O stress) | `data/params/node-io-hog/krkn-hub.yaml` | Generic node I/O contention — lower-fidelity than `storage_throttle_scenarios` for this specific target since it stresses the whole node rather than the one relevant PVC | Injection point 1, lower priority than the PVC-scoped throttle scenario |
| A `cnv`-specific example (`scenarios-hub/cnv/snapshot_creation_disruption.yaml`) is referenced by name in `kubevirt-outage/_tab-krkn.md` as an example scenario file, but its content was not vendored into this local Krkn checkout — **NEEDS VALIDATION** before relying on any specific syntax from it. | referenced, not present locally | Possibly backup/snapshot-specific | N/A until validated |

No exact `krknctl` command syntax is stated here beyond the confirmed `SCENARIO_TYPE`/parameter names above; constructing a full invocation is **NEEDS VALIDATION** against `krknctl`'s own CLI help/source, which was not part of this local checkout.

---

## G. QE Chaos Matrix

| # | Priority | Chaos Type | Krkn Scenario | Target | Backup Operation | Injection Condition | Failure Risk | Expected Recovery | Backup Verification | Data Verification |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P0 | Pod kill | `pod_disruption_scenarios` | `virt-launcher-vm-cbt-demo-*` | Full or incremental, live block-copy (injection point 1) | virt-launcher log shows `"Backup started"` for the target backup name, `Done` condition not yet True | Truncated destination PVC reported `Done=True`; or backup silently restarts as full | virt-controller reenqueues; backup either fails to a terminal non-Done state or genuinely restarts cleanly — never `Done=True` over bad bytes | `Done` condition final value, `checkpointName`, `virsh checkpoint-list --tree` matches expected parent/child | Tier-B restore test (`vm-cbt-restore-test.sh`): hash + marker-line on both full-only and full+incremental reconstructions |
| 2 | P0 | Storage pressure | `pvc_scenarios` | `hello-full-output` / `hello-incremental-output` | Live block-copy (injection point 1) | Same as #1 | Capacity exhaustion during copy — untested whether this fails clean or truncates silently | Backup fails to a terminal error condition, not `Done=True` | `Done` condition + PVC `.status.capacity` vs actual bytes written | Tier-B restore test |
| 3 | P0 | Storage pressure (new, this investigation) | `pvc_scenarios` | `persistent-state-for-vm-cbt-demo-*` (the CBT bitmap PVC, distinct from backup-destination PVCs — not identified in the prior 2026-09-29 plan) | Checkpoint write during either backup | Backup CR created, `Progressing=True` | Corrupting/filling the checkpoint-bearing qcow2 overlay could invalidate the entire checkpoint chain, independent of whether the destination PVC itself is healthy | UNKNOWN — no prior evidence either way; this is the highest-novelty untested question | `virsh checkpoint-list --tree` integrity, tracker `.status.latestCheckpoint` | Tier-B restore test; also compare pre/post `virsh checkpoint-list` tree structure |
| 4 | P0 | VM/KubeVirt disruption | `kubevirt_vm_outage` | `vm-cbt-demo` VMI | Between full completion and incremental start (injection point 3) | Tracker checkpoint == full checkpoint, guest not yet mutated | Tests `checkpointRedefinitionRequired` path; whether incremental after restart is still a true delta or silently degrades to full | virt-handler sets/clears `checkpointRedefinitionRequired`; subsequent incremental still diffs correctly (SOURCE-documented expectation, UNKNOWN if actually correct) | `type=Incremental` still reported; checkpoint tree still parent→child; artifact still delta-sized | Tier-B restore test |
| 5 | P1 | Controller disruption | `pod_disruption_scenarios` | `virt-controller` replica (`openshift-cnv`) | Immediately after `Done=True` is first computed (injection point 4) | Backup CR just reached `Done=True`, before the other replica/leader has necessarily converged | Tests whether the observed benign duplicate-call race (§C) can become a genuine double-checkpoint or conflicting-status bug under leader failover | Only one terminal checkpoint per backup name; tracker never regresses or duplicates | `oc get vmbackup -o yaml` conditions history, `oc logs virt-controller` for duplicate/conflicting reconciles | N/A (control-plane correctness, not guest data) |
| 6 | P1 | Storage throttle | `storage_throttle_scenarios` | `hello-incremental-output` PVC | Live block-copy, incremental (injection point 1, slow variant) | Same as #1 | A slowed (not failed) copy widens the window for the reconcile-duplicate race (§C) to matter for real, rather than being masked by sub-second completion | Same as #1, plus explicit timing correlation with any duplicate `"Backup begin called"` log lines | virt-launcher log for duplicate begin attempts during the widened window | Tier-B restore test |
| 7 | P1 | Pod kill | `pod_disruption_scenarios` | `hp-volume-*` hotplug attachment pod | Hotplug-attach window, before `VolumeMountedToPod` (injection point 2) | Backup CR created, attachment pod not yet `Running`/mounted | Already flaky without chaos (`HotplugFailed` observed); tests whether the retry has a real bound or can wedge indefinitely | Attachment eventually succeeds or `VirtualMachineBackup` fails to a terminal, non-`Done` state within a bounded time (not indefinite pending) | `Progressing` condition and `oc get events` for repeat `HotplugFailed` | N/A (no bytes copied yet at this stage) |
| 8 | P2 | Network chaos (VMI-scoped) | `vmi-network-filter` | VM tap0, TCP/22 | Guest mutation step (`vm-cbt-backup.sh` step 2, between full and incremental) | During `guest_ssh` append call | Tests whether `common.sh:guest_ssh`'s 30-attempt port-forward retry loop fails closed with a clear error rather than hanging past `oc wait` timeouts elsewhere | Script exits non-zero with actionable stderr, not a silent hang | Script exit code/stderr | N/A (guest-mutation path, not backup-artifact path) |
| 9 | P2 | Node disruption | `node_scenarios` (`node_stop_start_scenario`) | Node hosting virt-launcher + both storage-relevant PVCs | Live block-copy (harder variant of #1) | Same as #1 | Combines pod loss, storage loss, and checkpoint-PVC loss simultaneously — hardest, most realistic failure but also the least isolated (compounds with #1 and #3) | UNKNOWN; run only after #1, #3 individually understood, to attribute effects correctly | Same as #1 | Tier-B restore test |
| 10 | P3 | I/O hog (generic) | `hog_scenarios` (`io-hog`) | HPP-hosting node | Live block-copy | Same as #1 | Lower-fidelity, whole-node version of #6; kept only as a coarse cross-check once #6 is understood | Same as #1 | Tier-B restore test |

---

## H. Verification Strategy

Distinct layers, none of which alone is sufficient:

1. **Workflow/orchestration verification** — `make e2e`/`Done=True` exit status. **Never used alone.** §B's observed `Warning ... Failed` event on a genuinely-successful backup is direct, observed proof that even a single status condition read at the wrong instant can mislead; only the terminal, settled `Done` condition (post-reconcile) counts.
2. **Backup metadata verification** — `VirtualMachineBackup.status.{type,checkpointName,conditions}` and `VirtualMachineBackupTracker.status.latestCheckpoint`, read only after the object has stopped changing (poll until unchanged across two reads, not a single snapshot).
3. **Backup artifact verification** — inspect the actual destination PVC content directly (`qemu-img info`/`qemu-img map` on the backup qcow2, comparing the incremental's `backing-filename` and allocated-cluster count against the full) — **not currently done by this repo's own scripts** and is the concrete gap this investigation confirms independently of the prior 2026-09-29 report's Gap 4.
4. **CBT/checkpoint verification** — `virsh checkpoint-list <domain> --tree` inside the virt-launcher pod (read-only, used in this investigation) to confirm the parent→child relationship actually matches what the CRs claim; also watch `VirtualMachineBackupTracker.status.checkpointRedefinitionRequired` across any VMI restart.
5. **Restored VM/guest data verification** — the repo's own Tier-B mechanism (`vm-cbt-restore-test.sh`/`restore-lib.sh`): reconstructs both a full-only and a full+incremental disk image and asserts guest-file SHA-256 + marker-line presence/absence against hashes captured live from the guest at backup time. This is real, already-implemented, evidence-based verification — the strongest layer that exists in the pipeline today.

**Concrete false positives investigated:**

| Possible false positive | Status after this investigation |
|---|---|
| A backup reports `Done=True` while the copy was actually truncated by an interruption | UNKNOWN/untested — no chaos was executed (boundary respected); §D/§E identify exactly where to test this |
| `Warning ...Failed` events on `VirtualMachineBackup` mean the backup failed | **Disproven for the observed case** — OBSERVED transient event on a backup that in fact completed correctly (§B); a monitoring rule keyed on Warning events alone would misclassify a healthy backup |
| Incremental backup silently becomes a full re-copy while still labeled `Incremental` | Not disproven — no independent `backing_file`/cluster-count assertion exists in the pipeline; only artifact-size and Tier-B correctness suggest (but don't prove) a true delta was taken (§C.1) |
| CBT checkpoint state is lost on VMI/pod restart, forcing silent fallback to full | **Partially corrected, not resolved** — this investigation found the checkpoint state is NOT purely in-memory (it is a qcow2 overlay on a dedicated, persistent, per-VMI PVC), and KubeVirt has an explicit `checkpointRedefinitionRequired` recovery path for restarts. Whether that recovery path actually works correctly under real disruption is still UNKNOWN and remains the single highest-value untested question (§E point 3, §G #4) |

---

## I. Comparison Against the Prior 2026-09-29 Validation Docs

Read only at this final stage, per instructions, as a secondary cross-check.

**Agreements:**
- `validation/qe-chaos-testing-plan.md` correctly identified that there is no separate backup-export pod and that `virt-launcher` is the only meaningful pod-kill target for an in-flight export — this investigation independently confirmed the same fact directly from `backup.go` log lines inside the `compute` container.
- Both documents agree the checkpoint-name-based diffing (via the tracker) is the real mechanism, and both flag the same residual gap: nothing in the pipeline independently inspects the incremental qcow2's `backing_file`/cluster count to prove a true delta was taken (their "Gap 4").
- Both documents agree `hello-restore-verify`'s Tier-B rebuild-and-hash check is the strongest available correctness evidence in the pipeline today.

**Disagreements / corrections:**
- The prior plan states the CBT dirty-bitmap is *"in-memory (INFERRED not persisted independent of the VMI process)"* and treats node/pod loss as risking an **unrecoverable, silently-degraded** bitmap. This investigation found direct, OBSERVED evidence (blockdev args + volume mounts) that the CBT-bearing qcow2 overlay is persisted on a dedicated per-VMI PVC (`persistent-state-for-vm-cbt-demo-*`), independent of the virt-launcher pod's lifecycle, and that KubeVirt has an explicit, named recovery mechanism (`checkpointRedefinitionRequired`, owned by virt-handler) for exactly this scenario. The correct framing is not "the bitmap is lost on restart" but "there is a specific, previously-undiscovered redefinition path whose correctness under real disruption is untested" — a more precise and more testable failure boundary than the prior plan's framing.
- The prior plan's "highest priority" scenario (node failure during in-flight incremental backup, its NF1) is still valid but this investigation adds a narrower, more attributable predecessor test: killing/restarting the VMI or virt-launcher **between** backups (not during a copy) to isolate the checkpoint-redefinition question from the copy-interruption question — the prior plan's own P4 control gestured at this but did not have the persistent-state-PVC evidence to explain *why* it matters.
- This investigation additionally surfaces a race the prior plan did not identify at all: the benign-but-real virt-controller reconcile-duplicate-call race from a `resourceVersion` conflict (§C), currently masked only by virt-launcher's own idempotency check on backup name+start-time — a concrete, source-grounded, previously-undocumented target for a controller-disruption chaos scenario (§G #5).
- The prior plan's timing claim ("~90 seconds end-to-end... far shorter than multi-minute figures implied by 31Gi qcow2 sizes") is consistent with what this investigation observed (full backup block-copy ≈17.5s, incremental ≈5ms, both against very small realized writes) — no disagreement, just independent reproduction.
