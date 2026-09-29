# QE Chaos-Testing Plan: KubeVirt CBT Backup/Restore Pipeline

**Date:** 2026-09-30
**Scope:** Design only — no chaos executed (per the mandated Chaos Execution Boundary). Evidence gathered from repo source (`scripts/*.sh`, `Makefile`, `manifests/*.yaml`), `docs/vm-cbt-workflow.md`, prior validation reports (`validation/cbt-verification-report.md`, `validation/<target-host>-validation-summary-2026-09-29.md`), and a live, observed `make clean-all` + `make e2e` run executed on `<target-host>` on 2026-09-30 with real-time `oc get/describe/logs/top` inspection.
**System under test:** the KubeVirt CBT full/incremental backup mechanism (`backup.kubevirt.io/v1alpha1`: `VirtualMachineBackup`, `VirtualMachineBackupTracker`) — not the `make e2e` shell pipeline, which is only the harness used to exercise it.
**Confidence key:** OBSERVED (live `oc`/log output) · SOURCE (script/manifest code) · DOCUMENTED (`docs/`, prior `validation/*.md`) · INFERRED (reasoned, not yet executed) · UNKNOWN (would require reading KubeVirt internals, out of repo scope).

---

## A. Discovered CBT Architecture

### A.1 Components (OBSERVED on <target-host> + SOURCE)

| Component | Role | Evidence |
|---|---|---|
| `VirtualMachine`/`VirtualMachineInstance` `vm-cbt-demo` | Fedora guest; `.status.changedBlockTracking.state` is the CBT enablement signal | OBSERVED: `cbtState=Enabled ready=true`, `phase=Running` |
| `virt-launcher-vm-cbt-demo-*` pod | Runs the guest VM (QEMU); the **only** workload pod in the namespace besides the transient restore pod | OBSERVED: 2/2 containers, ~22m CPU / 794Mi memory at idle; no separate backup-export/controller pod exists in-namespace |
| `hostpath-provisioner-csi-*` DaemonSet (`openshift-cnv`) | CSI driver backing `cbt-demo-hpp` | OBSERVED: only **one** pod cluster-wide, colocated with the VM's node |
| `vm-cbt-root` PVC/PV, `hello-full-output`, `hello-incremental-output` PVCs | VM root disk + both backup destination volumes | OBSERVED: all three PVs carry identical `nodeAffinity: topology.hostpath.csi/node=<target-node>`, all backed by one shared pool `hpp-pool-cbt-demo-pool-<target-node>` (1489Gi) also used by an unrelated `cbt-demo` namespace and every CDI golden-image `DataSource` |
| `VirtualMachineBackupTracker` `hello-tracker` | Kubevirt CR holding `.status.latestCheckpoint` — the anchor incremental backups reference | SOURCE (`manifests/full-backup.yaml`) + OBSERVED status |
| `VirtualMachineBackup` `hello-full` / `hello-incremental` | Backup CRs; `.status.type`, `.status.checkpointName`, `.status.conditions[Done]` | SOURCE + OBSERVED |
| `vm-cbt-ssh` Service + ephemeral `oc port-forward` | Guest-mutation channel (`common.sh:guest_ssh`), used to change guest data between full and incremental backup | SOURCE |
| `hello-restore-verify` pod | Transient, privileged helper pod; only consumer that reads backup PVC contents | SOURCE (`restore-lib.sh`) + OBSERVED (triggers a PodSecurity `restricted:latest` warn, currently non-enforcing) |
| `virt-api`/`virt-controller`/`virt-handler` | KubeVirt control/data plane; `virt-handler` runs as a DaemonSet on every node (10 pods observed) | OBSERVED (implied by CRDs, not individually traced into backup reconciliation — UNKNOWN internal logic) |

**Critical discovered fact (OBSERVED):** `cbt-demo-hpp` (`kubevirt.io.hostpath-provisioner`) is single-node local storage. The VM root disk and *both* backup output PVCs are pinned to the same node as the sole HPP CSI pod. That node is a de facto single point of failure for the guest disk, both backup artifacts, and the storage driver simultaneously — not documented anywhere in `docs/vm-cbt-workflow.md`, and only visible via `oc get pv -o jsonpath='{.spec.nodeAffinity}'`. The underlying storage *pool* is additionally shared across unrelated namespaces/workloads, broadening blast radius beyond this one demo.

### A.2 Data path (SOURCE + INFERRED)

```
Guest write (SSH mutation)
  → virtio-blk on vm-cbt-root PV (node-pinned)
  → KubeVirt CBT dirty-bitmap in QEMU (in-memory, INFERRED not persisted independent of the VMI process)
  → VirtualMachineBackup reconciliation exports qcow2
      full backup   → complete disk image
      incremental   → overlay referencing the tracker's checkpoint
  → written to hello-full-output / hello-incremental-output PVCs (same node, same pool)
  → read back only by the hello-restore-verify pod via qemu-img rebase/convert + btrfs restore
    (no upstream restore API exists for this alpha feature; this repo supplies its own
     reference reconstruction — docs/vm-cbt-workflow.md line 18)
```

### A.3 Verification model as built (SOURCE)

Two tiers:
- **Tier A (API/metadata)** — `vm-cbt-verify.sh` steps 1–3: VM CBT state, backup `Done=True`/`type`, tracker `latestCheckpoint`, via `oc get`.
- **Tier B (data correctness)** — `vm-cbt-restore-test.sh`/`restore-lib.sh` (step 4/4): rebases the incremental qcow2 onto the full qcow2 inside a helper pod, converts to raw, extracts the guest file via `btrfs restore`, and asserts SHA-256 + marker-line presence against hashes captured live from the guest at backup time (`state/*.sha256`). This closes the "false success" gap identified in `validation/cbt-verification-report.md`, which predates Tier B's existence in the pipeline.

### A.4 Known structural limitation (SOURCE, `docs/vm-cbt-workflow.md` + `AGENTS.md`)

Resource names are fixed (`hello-full`, `hello-incremental`, `hello-tracker`, `hello-*-output`) — the workflow supports exactly one run per namespace, with no retry/resume semantics of its own for a failed or half-finished `VirtualMachineBackup`. Any chaos scenario leaving partial state will require `make clean-all` before the pipeline can run again. What KubeVirt's internal backup controller itself does on retry (vs. this repo's lack of retry logic) is **UNKNOWN** without reading KubeVirt source.

---

## B. Live Backup Lifecycle (OBSERVED, 2026-09-30 fresh run)

A full `make clean-all` followed by `make e2e` was executed live on `<target-host>` to confirm the model, not merely re-derived from prior reports.

- **End-to-end duration:** the entire `preflight → vm-setup → vm-backup → vm-cbt-backup → vm-cbt-verify (incl. Tier-B restore test)` cycle completed in **~90 seconds** wall-clock. This is far shorter than the multi-minute figures implied by the 31Gi qcow2 sizes seen in `cbt-verification-report.md`. **Consequence for chaos design:** the "in-flight backup" window is short — scenarios must trigger on an observed state transition (e.g., `VirtualMachineBackup` entering a non-`Done` state), not a fixed sleep offset.
- **Storage is a shared multi-tenant local pool**, confirmed live: every 30Gi-requesting PVC in this workflow actually binds to a PV reporting 1489Gi capacity from `hpp-pool-cbt-demo-pool-<target-node>`, shared with an unrelated `cbt-demo` namespace's own backup chain and all CDI golden images in `openshift-virtualization-os-images`.
- **No separate backup-export pod** was observed at any point in the run — confirming (previously INFERRED, now OBSERVED) that `virt-launcher` is the only meaningful pod-kill target for interrupting an in-flight export.
- **Resource footprint negligible under normal conditions** (`oc adm top`): `virt-launcher-vm-cbt-demo-*` ~22m CPU / 794Mi memory; node `<target-node>` at 857m CPU (0%) / 4920Mi memory (0%) overall. No ambient pressure — CPU/memory/IO-hog scenarios will produce a clean, uncontaminated signal.
- **New environmental fragility observed:** applying `manifests/restore-verify-pod.yaml` triggers a `Warning: would violate PodSecurity "restricted:latest"` admission warning every run (privileged, hostPath, no seccomp, not `runAsNonRoot`). Currently non-blocking (warn-only PSA), but a future PSA-hardening change would fail Tier-B restore verification closed on every run, independent of any chaos condition — a latent dependency worth flagging, not a chaos scenario itself.

---

## C. Full Backup Analysis

```
Trigger: apply manifests/full-backup.yaml (make vm-backup)
  → creates PVC hello-full-output, VirtualMachineBackupTracker hello-tracker
    (source: VM vm-cbt-demo), VirtualMachineBackup hello-full (source: tracker,
    output PVC: hello-full-output)
  → KubeVirt backup controller reconciles hello-full (internal mechanism UNKNOWN
    beyond observable CR status transitions)
  → export writes a complete qcow2 disk image to hello-full-output (node-pinned PVC)
  → hello-full.status.conditions[Done]=True, .status.type=Full,
    .status.checkpointName set
  → hello-tracker.status.latestCheckpoint updated to the full checkpoint
```

Per component:

| Component | Role during full backup | Observability | If it disappears |
|---|---|---|---|
| `virt-launcher` pod | Hosts the running VM/QEMU whose disk is being exported | `oc get pod`, `oc logs`, `oc adm top` | INFERRED: KubeVirt reschedules the VMI; whether the in-progress export resumes, restarts, or is lost is **UNKNOWN/untested** — highest-value pod scenario (§F, P1) |
| `hostpath-provisioner-csi` pod | Serves PVC read/write for the export destination | `oc get pod -n openshift-cnv` | Only one instance observed cluster-wide; a restart mid-export could stall or corrupt the write — untested |
| `hello-full-output` PVC/PV | Destination for the exported qcow2 | `oc get pvc`, `oc describe pv` (nodeAffinity) | If storage fills or becomes unavailable mid-export: could produce a truncated qcow2 that still reports `Done=True` — the core false-positive risk this plan targets |
| `VirtualMachineBackup` CR | Records backup progress/completion | `oc get/describe vmbackup`, `.status.conditions` | `wait_for_backup_done` (`common.sh`) has a 20m timeout then hard-fails; no partial-state cleanup — a stuck CR blocks the fixed-name pipeline until `make clean-all` |
| `hello-tracker` CR | Anchors the checkpoint the next (incremental) backup will reference | `oc get vmbackuptracker` | If it fails to update, the next backup cannot correctly identify itself as incremental — SOURCE: `vm-cbt-backup.sh` explicitly waits for this before mutating guest data |

**Completion evidence:** `hello-full.status.conditions[type=Done].status == "True"` and `.status.type == "Full"` (Tier A); actual data correctness is only proven by Tier B's full-only restore + hash/marker-line assertion.

---

## D. Incremental Backup Analysis (Full → Incremental Transition + Checkpoint/CBT State)

### D.1 What happens between full and incremental (SOURCE)

1. `vm-cbt-backup.sh` first confirms `hello-full` completed as `Full`.
2. It then **waits for `hello-tracker.status.latestCheckpoint` to match the full backup's checkpoint** before touching the guest — this is the explicit dependency ensuring the incremental backup has a valid base to diff against.
3. Only then does it mutate the guest (`guest_ssh` appends a marker line to `hello.txt`, idempotent for retries), capturing the new SHA-256 to `state/incremental-backup.sha256`.
4. It applies `manifests/incremental-backup.yaml`: creates `hello-incremental-output` PVC and `VirtualMachineBackup hello-incremental`, whose **source is the same tracker** — this is how KubeVirt is expected to identify the correct dirty-block baseline (INFERRED mechanism; the actual CBT bitmap consumption inside KubeVirt is UNKNOWN/not traced into KubeVirt source in this investigation).

### D.2 Incremental backup lifecycle (SOURCE + OBSERVED)

```
Trigger: apply manifests/incremental-backup.yaml (make vm-cbt-backup, after guest mutation)
  → VirtualMachineBackup hello-incremental created, source=hello-tracker
  → KubeVirt reconciles using the tracker's prior checkpoint as base
  → export writes an overlay qcow2 (observed 11 MB vs. 31 GB full, per
    cbt-verification-report.md — suggestive but NOT independently proven to be
    a true delta by that report alone)
  → hello-incremental.status.conditions[Done]=True, .status.type=Incremental,
    new .status.checkpointName (distinct from the full checkpoint)
  → hello-tracker.status.latestCheckpoint advances to the incremental checkpoint
```

### D.3 What actually proves CBT was used, vs. what does not (evidence-graded)

| Claim | Evidence available | Grade |
|---|---|---|
| Incremental backup type reported as `Incremental` | `oc get vmbackup -o jsonpath='{.status.type}'` | OBSERVED, but a label/field alone does not prove content is a real delta |
| Incremental artifact much smaller than full (11 MB vs 31 GB) | `cbt-verification-report.md`, prior run | OBSERVED, but size alone does not prove correctness — a backup that silently drops data would also be small |
| Incremental qcow2 backing_file actually references the full backup | Not independently inspected in this repo's scripts | **Gap identified in `cbt-verification-report.md` (Gap 4)** — `qemu-img info` on the incremental qcow2's backing chain was never run as an explicit assertion |
| Full+incremental restore reproduces guest data recorded live at backup time | Tier B (`vm-cbt-restore-test.sh`): SHA-256 + marker-line match against `state/*.sha256` | **This is the strongest available evidence** that CBT correctly captured the post-full-backup change, closing most of the original false-positive gap |
| Full-only restore does NOT contain the incremental marker line | Tier B asserts this explicitly | Confirms the full backup and incremental overlay are genuinely distinct, not the incremental silently being a full copy |

**Residual gap (INFERRED, not yet tested):** Tier B proves the *reconstructed* data is correct end-to-end, but does not independently inspect the incremental qcow2's `backing_file`/cluster count to prove *how* the delta was computed — so a failure mode where CBT silently promotes an incremental request to a full re-copy (Gap 4-class defect) could still pass Tier B undetected if the resulting data happens to be correct. This is exactly the kind of behavior chaos scenario P1 (§F) is designed to expose under stress, where a corrupted/incomplete case is more likely to surface than under a clean run.

---

## E. Failure Boundaries

| Stage | Network loss | Pod loss | Node loss | Storage pressure/unavailability |
|---|---|---|---|---|
| Guest mutation (`guest_ssh`) | `oc port-forward` dying mid-SSH triggers `common.sh:guest_ssh`'s 30-attempt retry of the **whole** port-forward+probe cycle. Likely recovers if the VM itself stays up. UNKNOWN whether retries survive an API-server blip vs. only local port-forward flakiness. | Killing `virt-launcher` restarts the VMI; guest SSH is unreachable until `Running` again. The script has no VMI-readiness wait, only a generic SSH retry — behavior on a mid-mutation kill is **UNKNOWN, worth testing.** | Losing the HPP/virt-launcher node stops the VM entirely. The CBT dirty-bitmap lives in QEMU; HPP VMs are explicitly non-live-migratable (`docs/vm-cbt-workflow.md`). INFERRED: a hard node loss risks losing the in-memory bitmap, silently forcing the next backup to full instead of incremental — **the single most important scenario in this plan.** | N/A directly — guest mutation doesn't touch backup storage. |
| `VirtualMachineBackup` creation (full/incremental) | A network partition between API server and virt-handler/virt-launcher during export could leave the backup stuck `Done=False`; `wait_for_backup_done` has a 20m timeout then hard-fails with no partial-state cleanup, blocking the fixed-name pipeline until `make clean-all`. | Killing the process performing the qcow2 export mid-backup (INFERRED target: virt-launcher itself, since no separate export pod exists — OBSERVED §B) is the highest-value pod scenario: does KubeVirt retry, or does `VirtualMachineBackup` report `Done=True` with a truncated/corrupt qcow2? Directly tests the false-positive risk from `cbt-verification-report.md`. | The same node hosts the VM disk, both backup PVCs, and the CSI driver — node failure can simultaneously kill an in-progress export and make the destination PVC unreachable. Recovery path is **UNKNOWN** (single-node local storage has no failover). | Filling `hello-full-output`/`hello-incremental-output` near capacity during export tests whether the backup fails cleanly (`Done=False`/error condition) vs. writes a truncated qcow2 that still reports `Done=True`. |
| Tracker checkpoint advancement | Brief API-server unreachability during `wait_for_full_checkpoint_in_tracker`'s 20-attempt/1s poll should just retry — low risk, untested against real API flakiness. | N/A — tracker is a CR, no dedicated pod. | N/A directly. | N/A directly. |
| Restore verification (`hello-restore-verify`) | N/A — no guest SSH involved. | Killing the pod mid-`qemu-img rebase`/`btrfs restore`: `restore-lib.sh` traps `delete_restore_pod` on RETURN and treats non-`Succeeded` phase as failure — appears correctly fail-closed; worth confirming rather than trying to break. | If the storage node is unavailable, the pod (RWO, node-pinned PV) can never schedule — verification hangs until the 10-minute timeout in `run_restore_verify_pod`, then should fail closed; worth confirming. | Read-only mounts of already-written PVCs; a fill of the *same* PVC during restore (if capacity allows another write) tests whether the read-only mount is truly unaffected. |

---

## F. Chaos Injection Points (Ranked by Backup-Correctness Risk)

Ranked by technical risk to CBT correctness, not ease of execution.

1. **Node failure of the HPP/virt-launcher node during an in-flight incremental backup** (§E, row 2/col 4; NF1 below). Simultaneously threatens the in-memory dirty-bitmap, the export in progress, and both PVC destinations. Highest risk of a silent full-vs-incremental misclassification or unrecoverable state.
2. **`virt-launcher` pod kill during an in-flight `VirtualMachineBackup` export** (P1 below). Directly tests whether KubeVirt resumes, restarts as full, or leaves the CR stuck — and whether `Done=True` can be reached over a truncated artifact.
3. **Network disruption to the export path during full or incremental backup** (N3 below). Tests the same false-positive risk as (2) via a different fault class (partition vs. process death).
4. **Storage exhaustion of the backup destination PVC during export** (S1 below). Tests whether capacity exhaustion produces a clean failure or a truncated backup reported as `Done=True`.
5. **`virt-launcher` pod kill between full completion and incremental start** (P4 below) — lower risk, but a necessary control to confirm CBT bitmap/checkpoint survives a simple VMI restart when no backup is in flight, before trusting result (2).
6. **HPP CSI driver pod kill during export or restore-verify** (P2 below) — only one instance cluster-wide; untested whether a restart stalls or corrupts in-flight writes.
7. **I/O or memory pressure on the shared storage node during export** (S2/S3 below) — lower priority; no evidence of CPU-boundedness, but the pool's cross-tenant sharing (§A.1, §B) makes this worth checking once higher-priority scenarios are validated.

---

## G. Krkn Mapping

**Status: NOT YET PERFORMED.** Phase 9/13 of this investigation (inspecting `/Users/darjain/projects/redhat-chaos/website` Krkn source to verify exact scenario names and produce `krknctl` invocation syntax) has not been executed in this pass. The scenario names below (`pod-scenarios`, `node-scenarios`, `pvc-scenario`, `hog-scenarios`, VMI-scoped network scenarios, etc.) are carried over from prior design work in this repo and are plausible based on general Krkn scenario-catalog naming, but are **not confirmed against the actual Krkn source** and no `krknctl` command strings are given, per the "never invent it" rule.

### G.1 Network disruption

| # | Krkn scenario | Target | Backup operation | Injection condition | Why this point matters | Confidence |
|---|---|---|---|---|---|---|
| N1 | VMI network chaos (name **NEEDS VALIDATION** against Krkn source) | `vm-cbt-demo` VMI tap interface | Guest mutation (`vm-cbt-backup.sh` step 3) | During `guest_ssh` append, before incremental backup is created | Tests whether the whole-port-forward retry loop in `common.sh:guest_ssh` tolerates degraded (not fully down) connectivity | INFERRED — scenario name unverified |
| N2 | VMI network filter (name **NEEDS VALIDATION**) | Block TCP/22 on VM tap0 | Guest mutation | During `guest_ssh` append | Simulates SSH-specific outage distinct from full network loss; verifies the 30-attempt retry gives up cleanly rather than hanging past other `oc wait` timeouts | INFERRED — scenario name unverified |
| N3 | Pod network chaos/filter (name **NEEDS VALIDATION**) | `virt-launcher-vm-cbt-demo-*` pod | In-flight full or incremental `VirtualMachineBackup` | `VirtualMachineBackup.status.conditions[Done].status != "True"` (backup started, not yet complete) | Tests whether a backup export that loses connectivity mid-flight fails clean (`Done=False`) or produces a silently truncated backup reporting `Done=True` — the core false-positive risk | INFERRED — scenario name unverified |
| N4 | Service disruption scenario (name **NEEDS VALIDATION**) | `vm-cbt-ssh` Service | Guest mutation | During guest mutation attempt | Coarser test of the workflow's only Service-based dependency; confirms scripts fail with an actionable message, not a bare timeout | INFERRED |

### G.2 Pod eviction/failure

| # | Krkn scenario | Target | Backup operation | Injection condition | Why this point matters | Confidence |
|---|---|---|---|---|---|---|
| P1 | Pod kill scenario (name **NEEDS VALIDATION**) | `virt-launcher-vm-cbt-demo-*` | In-flight full or incremental backup | `VirtualMachineBackup.status.conditions[Done].status != "True"` | Highest-value pod scenario (§F #2): tests resume vs. restart-as-full vs. stuck CR, and whether `Done=True` can mask a truncated export | INFERRED — scenario name unverified |
| P2 | Pod kill scenario | `hostpath-provisioner-csi-*` (`openshift-cnv`) | During export or restore-verify | Mid-export or mid-`qemu-img` operation | Only one HPP CSI pod observed cluster-wide; tests whether a CSI restart stalls/corrupts in-flight qcow2 writes | INFERRED |
| P3 | Container kill scenario (name **NEEDS VALIDATION**) | Container inside `hello-restore-verify` pod | Tier-B restore verification | Mid `qemu-img rebase` | Confirms the fail-closed behavior in `restore-lib.sh` (non-`Succeeded` phase ⇒ exit 1) actually triggers rather than reporting stale/cached hashes | INFERRED |
| P4 | Pod kill scenario | `virt-launcher-vm-cbt-demo-*` | Idle, between full completion and incremental start | Tracker `.status.latestCheckpoint` == full checkpoint, guest not yet mutated | Control case: confirms CBT bitmap/checkpoint survives a simple VMI restart with no backup in flight — required baseline before trusting P1's result | INFERRED |

### G.3 Node failure

| # | Krkn scenario | Target | Backup operation | Injection condition | Why this point matters | Confidence |
|---|---|---|---|---|---|---|
| NF1 | Node crash / stop-kubelet scenario (name **NEEDS VALIDATION**) | `<target-node>` (hosts VM, HPP CSI pod, and all three PVs' nodeAffinity) | In-flight incremental backup | `VirtualMachineBackup(hello-incremental).status.conditions[Done].status != "True"` | Single most important scenario (§F #1): guest disk, both backup artifacts, and the storage driver share one node. HPP VMs are documented non-live-migratable — determines whether CBT state survives a hard failure or the next backup silently falls back to full | INFERRED — scenario name unverified |
| NF2 | Node reboot scenario | Same node, after backups complete (idle) | Between full+incremental completion and `vm-cbt-verify.sh` | Tracker checkpoint == incremental checkpoint, `vm-cbt-verify` not yet run | Confirms whether a clean reboot (vs. crash) preserves the checkpoint and whether restore verification still passes — isolates crash-specific from reboot-specific effects | INFERRED |
| NF3 | Node stop/start scenario | A different, otherwise-idle worker node | During backup | Any in-flight backup | Negative control: confirms the pipeline is unaffected by unrelated node churn, validating NF1/NF2 results are attributable to the storage/VM node specifically | INFERRED |

### G.4 Other Krkn scenarios mapped from discovered dependencies

| # | Krkn scenario | Target | Backup operation | Injection condition | Why this point matters | Confidence |
|---|---|---|---|---|---|---|
| S1 | PVC fill scenario (name **NEEDS VALIDATION**) | `hello-full-output` or `hello-incremental-output`, filled to ~90% | In-flight export | Backup CR created, not yet `Done` | Storage is on the critical path; tests whether near-full capacity produces clean failure vs. truncated `Done=True` backup. **Scoping note:** the underlying pool is shared cross-namespace (§B) — a pool-level fill would affect other tenants and needs explicit approval; this scenario is scoped to a single PVC's logical capacity | INFERRED |
| S2 | Node I/O hog scenario | HPP node | During export | Backup CR created, not yet `Done` | Backup/restore do heavy sequential local I/O; contention could slow/corrupt export without a surfaced error. Baseline node I/O/CPU/memory was negligible (§B), so this is a clean test. Same cross-tenant scoping caveat as S1 | INFERRED |
| S3 | Node memory hog scenario | HPP/virt-launcher node | During export | Backup CR created, not yet `Done` | QEMU/CBT bitmap tracking is memory-resident; OOM pressure risks eviction mid-export (compounds with P1) or silent bitmap corruption. Baseline virt-launcher memory ~794Mi (§B) gives a sizing reference | INFERRED |
| S4 | Time-skew scenario | HPP node or virt-launcher pod | During checkpoint creation | Checkpoint about to be created (backup CR applied) | Checkpoint names embed a timestamp; clock skew is a plausible (narrow) source of ordering/uniqueness bugs given the fixed-name, single-run design. Low priority/exploratory — no evidence of a dependency beyond the label | INFERRED, low priority |

**Explicitly excluded, with reasoning:**
- Generic node-wide network chaos/filter/interface-down — superseded by VMI-scoped N1/N2, which isolate the guest without confounding node-wide OVN/BFD effects.
- CPU hog — no evidence CBT export or restore is CPU-bound; lower priority than I/O/memory given the observed data path.
- Etcd/API-server/control-plane pod-kill scenarios — target cluster-wide HA, not anything CBT-specific; out of scope per the "map to a discovered dependency" rule.

---

## H. QE Chaos Matrix

| # | Priority | Chaos Type | Krkn Scenario | Target | Backup Operation | Injection Condition | Failure Risk | Expected Recovery | Backup Verification | Data Verification |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P0 | Node failure | Node crash/stop-kubelet (NEEDS VALIDATION) | `<target-node>` (VM+both backup PVCs+HPP CSI node) | Incremental backup, in-flight | `hello-incremental.status.conditions[Done] != True` | Lost dirty-bitmap → silent full-vs-incremental misclassification; unrecoverable backup PVC | Backup either fails closed or, if VM recovers, next backup correctly identifies its own type — not silently mislabeled | `oc get vmbackup -o jsonpath='{.status.type}'` matches request; CR reaches terminal condition | Tier B restore-test hash + marker-line match against `state/*.sha256` |
| 2 | P0 | Pod kill | Pod kill (NEEDS VALIDATION) | `virt-launcher-vm-cbt-demo-*` | Full or incremental backup, in-flight | `vmbackup.status.conditions[Done] != True` | KubeVirt resumes/restarts/gets stuck; `Done=True` could mask a truncated qcow2 | Backup either resumes/retries to a correct terminal state, or fails closed — never `Done=True` over bad data | Same as above + `oc describe vmbackup` conditions/events | Tier B restore-test on both full-only and full+incremental reconstructions |
| 3 | P0 | Network disruption | Pod network chaos/filter (NEEDS VALIDATION) | `virt-launcher-vm-cbt-demo-*` | Full or incremental backup, in-flight | `vmbackup.status.conditions[Done] != True` | Same false-positive risk as #2, via partition instead of process death | Backup fails closed (`Done=False`/error) rather than completing over a partitioned export | Same as #2 | Tier B restore-test |
| 4 | P1 | Storage pressure | PVC fill (NEEDS VALIDATION) | `hello-full-output` / `hello-incremental-output` (scoped to single PVC) | In-flight export | Backup CR created, not `Done` | Truncated backup reporting `Done=True` under capacity exhaustion | Clean failure condition, not silent truncation | `oc get vmbackup` conditions + PVC `.status.capacity` vs. usage | Tier B restore-test |
| 5 | P1 | Pod kill (control) | Pod kill | `virt-launcher-vm-cbt-demo-*` | Idle, between full and incremental | Tracker checkpoint == full checkpoint, guest not yet mutated | Establishes whether CBT bitmap/checkpoint survives a simple restart absent backup pressure | Tracker checkpoint and CBT state unchanged after VMI restart | `oc get vmbackuptracker` unchanged | Guest SSH re-check of pre-mutation hash |
| 6 | P1 | Pod kill | Pod kill | `hostpath-provisioner-csi-*` | During export or restore-verify | Mid `qemu-img`/export operation | CSI restart stalls or corrupts in-flight writes; only one instance observed | Export/restore resumes or fails closed after CSI pod recovery | `oc get pod -n openshift-cnv`, `vmbackup` conditions | Tier B restore-test |
| 7 | P2 | Node failure (variant) | Node reboot | Same node, idle | Between incremental completion and `vm-cbt-verify` | Tracker checkpoint == incremental checkpoint | Isolates reboot-specific vs. crash-specific effects from #1 | Checkpoint preserved; `vm-cbt-verify` passes post-reboot | `oc get vmbackuptracker`/`vmbackup` | Tier B restore-test |
| 8 | P2 | Pod kill | Container kill (NEEDS VALIDATION) | Container in `hello-restore-verify` | Tier-B restore verification | Mid `qemu-img rebase` | Confirms fail-closed behavior of `restore-lib.sh` rather than stale/cached result | Script exits 1 on non-`Succeeded` phase; no false pass | Pod phase via `oc get pod` | N/A (confirming failure path, not data) |
| 9 | P2 | Network disruption | VMI network filter (NEEDS VALIDATION) | VM tap0, TCP/22 | Guest mutation | During `guest_ssh` append | 30-attempt retry loop should give up cleanly, not hang past other timeouts | Script fails with actionable error, not silent hang | Script exit code + stderr | N/A |
| 10 | P2 | Hog | Node I/O hog (NEEDS VALIDATION) | HPP node | In-flight export | Backup CR created, not `Done` | Silent slow corruption under I/O contention on shared local disk | `Done=True` only if artifact is byte-correct | `vmbackup` conditions + timing | Tier B restore-test |
| 11 | P3 | Hog | Node memory hog (NEEDS VALIDATION) | HPP/virt-launcher node | In-flight export | Backup CR created, not `Done` | OOM eviction mid-export (compounds with #2) or silent bitmap corruption | Clean failure or successful retry; no silent corruption | `oc adm top`, `vmbackup` conditions, eviction events | Tier B restore-test |
| 12 | P3 | Network disruption (control) | Node-wide network chaos (excluded from priority set, included as negative control) | A different idle node | During backup | Any in-flight backup | Confirms pipeline unaffected by unrelated cluster network churn | No effect on backup outcome | `vmbackup` conditions | Tier B restore-test |
| 13 | P3 | Time skew | Time-skew scenario (NEEDS VALIDATION) | HPP node or virt-launcher | Checkpoint creation | Backup CR applied, checkpoint about to be created | Checkpoint name/ordering/uniqueness bug (low evidence of real risk) | Checkpoint names remain unique/ordered despite skew | `oc get vmbackup`/`vmbackuptracker` checkpoint names | N/A |

**Priority rationale:** P0 items (#1–3) directly target the highest-confidence, highest-blast-radius correctness risk identified in §E/§F — the shared node/storage SPOF and the false-positive `Done=True` risk explicitly raised by `cbt-verification-report.md`. P1 items (#4–6) are necessary supporting/control evidence for interpreting the P0 results correctly. P2 items (#7–10) extend coverage to variants and confirm currently-believed-correct fail-closed paths. P3 items (#11–13) are lower-confidence or exploratory, included only where they map to a discovered dependency but with weaker evidence of real risk.

---

## I. Verification Strategy

The goal for every scenario is never "did `make e2e` pass" or "is `Done=True`" — it is **did the CBT backup remain correct and recoverable**.

### I.1 Required verification layers per test

1. **Kubernetes/backup CR state:** `VirtualMachineBackup.status.conditions[Done]` reaches a terminal value (never left ambiguous); `.status.type` matches what was requested (an incremental request silently becoming `Full` is a defect); `VirtualMachineBackupTracker.status.latestCheckpoint` advances correctly.
2. **Pod/controller state:** `oc describe`/`oc logs`/`oc get events` on `virt-launcher`, HPP CSI pod, and `hello-restore-verify` to distinguish "clean retry", "stuck", and "silent partial success".
3. **Storage state:** PVC `.status.capacity`/`phase`, and (where feasible) `qemu-img info` on the backup qcow2's `backing_file`/size to catch a truncated or unexpectedly-full-sized "incremental" artifact — the exact Gap 4 class of defect identified in `cbt-verification-report.md`.
4. **CBT/checkpoint state:** VM `.status.changedBlockTracking.state`, tracker `.status.latestCheckpoint`, and checkpoint-name distinctness across full/incremental.
5. **Backup content correctness (Tier B, mandatory for every scenario touching an in-flight backup):** `scripts/vm-cbt-restore-test.sh` — reconstruct via `qemu-img rebase`/`convert` + `btrfs restore`, then assert SHA-256 and marker-line presence against `state/*.sha256` captured live from the guest at backup time. **A scenario that leaves `Done=True` but fails Tier B is the concrete false-positive failure mode this entire plan exists to find.**
6. **Guest data:** where feasible, an independent guest SSH read/hash (not just the script's own recorded state) to rule out the verification script itself trusting stale state.

### I.2 False-positive analysis (per Phase 12 requirement)

Documented possibilities, graded by current evidence:

| Possible false positive | Supporting evidence | Grade |
|---|---|---|
| Truncated artifact reported `Done=True` under network/pod/storage failure mid-export | Directly implied by `wait_for_backup_done`'s pass/fail being purely condition-based (SOURCE), with no independent artifact inspection in the existing pipeline before Tier B was added | INFERRED — this is precisely what scenarios #1–4, #10 are designed to test |
| Incremental backup silently becoming a full re-copy while still reporting `type=Incremental` | `cbt-verification-report.md` Gap 4: no `backing_file`/qcow2-header assertion exists in the current scripts | INFERRED — not disproven by Tier B alone (§D.3); worth adding an explicit `qemu-img info` assertion as a pipeline improvement, independent of chaos testing |
| Stale CBT checkpoint after node/pod failure, causing the next backup to be incorrectly typed | HPP VMs are documented non-live-migratable; CBT bitmap is in-memory QEMU state (INFERRED, not confirmed against KubeVirt source) | INFERRED — scenario #1 (NF1) is designed specifically to surface this |
| Restore succeeding but guest data being wrong | Ruled out by Tier B's SHA-256 + marker-line comparison against hashes captured live from the guest, not from the backup pipeline's own claims | Currently well-covered — lowest residual risk among the listed possibilities, for *unperturbed* runs; still worth re-confirming under chaos since Tier B itself has never been run against a scenario where the underlying data was known-bad |
| VM "recovering" after node/pod failure while CBT state is actually wrong | No current script independently checks CBT dirty-bitmap contents (only enablement state) | UNKNOWN — most novel finding a chaos scenario could produce; not currently detectable by any existing verification layer, which is itself a gap worth noting alongside the chaos results |

### I.3 What still needs to happen before execution

This document is design-only, per the Chaos Execution Boundary. Before any scenario in §H is executed:
1. Confirm exact Krkn scenario names and `krknctl` syntax against `/Users/darjain/projects/redhat-chaos/website` source (currently marked NEEDS VALIDATION throughout §G/§H).
2. Re-confirm the live-observed facts in §B are still current immediately before each execution window (node names, pool sharing, timing), since this is a shared, mutable lab environment.
3. Ensure `make clean-all` is run between scenarios given the fixed-name, single-run-per-namespace design (§A.4), so partial state from one chaos scenario cannot contaminate the next.
