# Scenario: O-01 golden rebuild + ODF baseline lifecycle

## 1. Identity

- **Jira issue:** CBT-O-01 (P1, fixture/prerequisite, no krkn scenario)
- **Run family:** ODF backend bring-up; every O-02…O-12 trigger embeds this spec's guards
- **Precedents:** learning #79 (HPP-bound golden blocks ODF runs); X-04 r01 (the failed cross-class attempt); I-05 (MANIFEST_VARIANT=odf incremental semantics); windows-golden DV (RBD golden pattern)

## 2. Objective and hypothesis

**Objective:** make rhel9-on-RBD runnable and measure the clean-backend baseline (full/incremental durations, node placement, RBD device visibility during copy).

**Hypothesis:** a registry-sourced DataVolume onto ocs-storagecluster-ceph-rbd imports cleanly (StorageProfile cloneStrategy "copy"; the cross-class failure is specific to PVC-to-PVC smart-clone requests), and the backup copy runs QEMU-local-read + kernel-RBD-write at a measurable duration.

## 3. Design

1. Guards: ceph HEALTH_OK (`oc get cephcluster -n openshift-storage`), no existing rhel9-rbd DataSource (idempotent), no RUN_ID collision.
2. Apply the golden DV + DataSource (exact YAML in CBT-O-00/README.md §1); `oc wait dv --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m`.
3. `VM_DATA_SOURCE_NAME=rhel9-rbd make e2e TYPE=full NAME=$RUN_ID VM_OS=rhel9 MANIFEST_VARIANT=odf GUEST_BASE_FILE_COUNT=1000 GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20` in background.
4. At the Progressing gate: record VM node (`oc get vmi -o jsonpath='{.status.nodeName}'`), confirm `/dev/rbd*` appears in the node's devices during the copy (oc debug node lsblk), snapshot the hp-volume attachment pod.
5. Follow-up `TYPE=incremental` + restore verify.

## 4. Target and validated disruption

None. Sizing: 80Gi root/full PVCs, 30Gi incremental PVC (large-odf profile).

## 5. Verification criteria

- DV Succeeded; DataSource rhel9-rbd → pvc rhel9-rbd-golden on ocs-storagecluster-ceph-rbd.
- Full Done=True/Successfully; incremental chains; restore bit-exact.
- Durations recorded: full copy wall, incremental wall, PVC bind time.
- Baseline numbers written to trigger-checks.txt as `CHECK baseline-full-seconds` / `CHECK baseline-incremental-seconds` (O-02+ verdicts reference these).

## 6. Pre-run guards

Ceph health; goldens absent or Succeeded; RUN_ID/resource-collision checks (standard). No HPP pool guard (HPP untouched except the untouched HPP golden).

## 7. Uncertainties

- RBD copy duration vs HPP's 52-58s — unknown until measured; if >2 min, O-scenario gate windows must widen (poll budget 450×2s may need raising in later triggers).
- VM placement is NOT node-pinned on ODF (any KVM node) — all O triggers resolve the node at gate time.

## 8. Evidence

trigger.log, full/incr stage logs, DV/DataSource YAML snapshots, lsblk-with-rbd capture, run report via standard templates.
