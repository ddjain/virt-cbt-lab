# Scenario: Restart storage access before restore volumes are mounted

## 1. Identity

- **Jira issue:** CBT-R-03 — "Restart storage access before restore volumes are mounted" (P2, technical scenario: pod-scenarios, phase: restore startup)
- **Run family:** restore-verification workflow, CSI storage-access outage during restore startup
- **Precedents:** R-01/R-02 (standalone direct-verifier pattern with the workflow's own rendered manifest; baseline-hash comparison); I-06 (pod-scenarios force-delete of a DaemonSet pod — virt-handler — with automatic DaemonSet recovery)

## 2. Objective and hypothesis

**Jira objective:** verify that restore verification recovers when storage access is interrupted before its read-only backup volumes are mounted: the restore pod should remain pending while storage access is unavailable and recover after the CSI plugin returns; if it cannot recover, it should fail cleanly without modifying artifacts.

**Product questions:**
1. With the HostPath CSI node-plugin pod force-deleted, does a freshly applied restore verifier pod stay Pending/ContainerCreating (volume attach/mount not satisfied) rather than fail?
2. When the DaemonSet recreates the plugin pod, does the verifier pod's mount eventually succeed and the verification complete with EXACTLY baseline hashes?
3. Do the backup PVCs/artifacts remain unchanged (Bound, no rebinding)?

## 3. Workflow and mechanics

**CSI plugin identity (verified live):** DaemonSet `hostpath-provisioner-csi` (ns openshift-cnv), pod `hostpath-provisioner-csi-kmx4s` on d38-h18-000-r660, labels `k8s-app=hostpath-provisioner`; desired=ready=1 (single node). The operator (hostpath-provisioner-operator) + DaemonSet controller recreate the pod automatically on deletion.

**Timing mechanics:** kubelet's volume attach/mount for a CSI volume requires the node-driver-registrar/plugin registration; with the plugin pod gone, `oc get volumeattachment` entries for new attaches stay pending and the pod waits in ContainerCreating (kubelet does not time out mounts — SyncPod retries). The plugin pod recreation on this cluster takes ~10-60s (image cached, IfNotPresent).

**Design:**
1. Normal full + 1-pass incremental lifecycle (baseline hashes + artifacts).
2. Outage leg: apply the standalone verifier pod (R-01 pattern, distinct name) — while the backup PVCs are Bound and free, so the pod is admitted and scheduled but waits on volume mount. IMMEDIATELY (before the pod's containers can start) force-delete the CSI node-plugin pod on d38-h18-000-r660 via krkn pod-scenarios (`--label-selector k8s-app=hostpath-provisioner` + `--namespace openshift-cnv` + `--name-pattern hostpath-provisioner-csi` + `--force=true`). Race control: delete the plugin FIRST, then apply the verifier — guaranteeing "before volumes are mounted" without a race. Actually cleaner: delete plugin → apply verifier → plugin returns via DaemonSet. The Jira's "restore pod is pending waiting for volume access" is then the observed window.
   - Wait — krkn's own recovery check (`--expected-recovery-time`) polls the DELETED pod's name pattern; a DaemonSet replacement has a DIFFERENT pod name, and krkn pod-scenarios matches by pattern so the replacement satisfies it (pattern matches the DaemonSet pod prefix). I-06 verified this pattern live (virt-handler deletion: krkn matched the replacement).
3. Recovery observation: poll verifier pod phase + events (`FailedAttachVolume`/`FailedMount` events expected while plugin down); record plugin-pod replacement timestamps.
4. Outcome: verifier eventually Succeeded with exactly baseline hashes once plugin returned and mounts completed.
5. Rerun identical (Jira: "rerun produces identical hashes") — the R-01 rerun pattern with a fresh pod name, no outage this time.

## 4. Target and validated disruption

**Target:** HostPath CSI node-plugin pod (hostpath-provisioner-csi-kmx4s, ns openshift-cnv, node d38-h18-000-r660).

**Action:** krkn pod-scenarios force-delete (grace 0) while a restore verifier pod is Pending/ContainerCreating waiting for its backup-volume mounts.

**Injection window:** plugin pod deleted BEFORE the verifier's volumes mount (delete first, apply verifier second — deterministic "before").

**Duration:** immediate (per Jira); outage length = DaemonSet recreation time (~10-60s).

**Blast radius:** the CSI plugin serves ONLY this lab's HostPath pool on this node (single-node DaemonSet, desired=1). VM disk I/O for RUNNING VMs is unaffected (already-mounted volumes keep working; only NEW attaches/mounts block). Pre-existing VMI vm-cbt-demo is paused/IOerror-ing already (unrelated, since Oct 8). The running backup-source VM keeps its root disk (already attached). Risk acceptable; matches I-06's handler-delete precedent.

## 5. Verification criteria

- Outage validity: plugin pod killed (krkn log + event), replacement pod created after (DaemonSet recovery); verifier pod Pending/ContainerCreating during the gap (events: FailedAttachVolume or similar).
- Verifier recovers: after plugin replacement, verifier pod proceeds to Running and Succeeded — within the 1800s budget.
- Outputs exactly equal baseline (six fields).
- Artifacts unchanged: PVCs Bound, PV bindings identical before/after.
- Rerun (no outage) also produces identical hashes.

## 6. Pre-run guards

- HostPath pool ≥300GiB free.
- RUN_ID collision guards.
- RESTORE_HELPER_IMAGE set.
- Confirm plugin DaemonSet healthy (1/1 ready) before start.
- The run VM and its launcher hold already-attached volumes — no disruption to the source VM.

## 7. Uncertainties

- Whether the verifier pod's mount completes without a pod event storm: if kubelet already attempted registration with a stale socket, mount may need the plugin's re-registration (~seconds after pod Running). Watch events; the 1800s budget absorbs minutes.
- Krkn recovery check semantics for DaemonSet replacement (name-pattern matches prefix — I-06-proven for virt-handler; same expected here).
- If the mount NEVER completes (plugin returns but registration fails), the Jira's fallback expectation applies: clean failure without artifact modification — verdict would then be INCONCLUSIVE-to-FAIL depending on behavior; evidence would still document the product's startup behavior.

## 8. Evidence to capture

krkn log (plugin kill + recovery), verifier pod phase timeline + events (Pending window, FailedAttachVolume/FailedMount, mount success), plugin replacement pod name/times, verifier outputs, rerun outputs, PVC before/after. All under `cbt-chaos/scenarios_v2/CBT-R-03/runs/<RUN_ID>/`.
