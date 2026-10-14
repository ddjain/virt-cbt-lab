# Scenario: Restart the HostPath CSI node plugin during the active full-backup copy

- **Jira:** CBT-F-07 — Restart storage access during an active full backup
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Active operation

## 1. Jira objective and hypothesis

The issue asks whether an **already-mounted** backup destination remains usable when the storage-access component (HostPath CSI node plugin) is restarted **during active writes**. Delete the single HostPath CSI node-plugin pod while the full backup's disk copy is actively running (destination attached, copy in flight). The behavior is intentionally being established: the copy may continue because the volume is already mounted, or it may fail cleanly — in either case the system must not report invalid data as successful.

Issue fields: workflow **Full backup**; target **HostPath storage CSI node plugin**; action **delete the CSI node plugin pod**; timing **during the active disk-copy period**; signal **full backup is actively copying**; duration **immediate**; recovery **automatic CSI plugin restart**; verification **CSI recovery, PVC state, backup result, checkpoint state, backup image integrity, and restore result**; expected outcome **identifies the actual recovery behavior of active storage I/O after a CSI restart**.

This is the active-copy twin of CBT-F-06 (which targeted the pre-bind provisioning window and passed). The distinguishing requirement here is that the destination PVC is already `Bound` **and attached**, and the copy is in flight, when the plugin dies.

## 2. Evidence and live target resolution

- Same cluster topology as CBT-F-06 (re-verified during that run on 2026-10-12): storage class `cbt-demo-hpp` (provisioner `kubevirt.io.hostpath-provisioner`); exactly one HostPath CSI node-plugin pod cluster-wide in `openshift-cnv`, name matching `^hostpath-provisioner-csi-`, owned by DaemonSet `hostpath-provisioner-csi`. The shared label `k8s-app=hostpath-provisioner` also matches the unrelated `hpp-pool-*` backing pod — the trigger selects strictly by name pattern (proven in CBT-F-06 r02–r05).
- `MANIFEST_VARIANT=default` (or `large`) resolves every supported `VM_OS` to `cbt-demo-hpp` for both the VM root disk and the full-backup destination PVC (`scripts/common.sh` `manifest_path()`/`set_manifest_variant_settings`; confirmed in CBT-F-06). `odf`/`large-odf` (the `.env` default) never exercise the HostPath plugin — the trigger force-sets `default` and rejects `odf` variants.
- Copy-window sizing (measured 2026-10-12, CBT-F-06 r05 on this cluster): the `.env` default workload (1000 files × 15–20 MiB ≈ 17 GiB) produces a 52 s full-backup copy window on HPP — comfortably longer than the 3 s trigger poll interval. The trigger therefore keeps the `.env`-default workload (no override): the launch pattern pre-exports it anyway (see harness learning), and a longer window only makes the mid-copy injection easier to land.
- `VirtualMachineBackup.status.conditions` array order is consistently `[Progressing, Done]` across every backup observed on this cluster (verified across all prior campaign backups on 2026-10-13); both condition types are always present once the object is processed.

## 3. Workflow and prerequisites

`make e2e TYPE=full NAME="$RUN_ID"` with `VM_OS=rhel9` (default), `MANIFEST_VARIANT=default` (force-set), and the `.env`-default guest workload (1000 × 15–20 MiB; the trigger forwards it explicitly so the printed pipeline configuration is authoritative). `TYPE=full` creates the VM, root disk, tracker, and takes one full backup; the planned incremental pass(es) and restore verification run afterwards in the follow-up stage.

Prerequisites: no other HPP-provisioning-sensitive test in flight (single plugin pod is cluster-wide); unique `RUN_ID` not present locally or on the cluster (trigger fail-closed guards).

## 4. Target and validated disruption

**Primary (krknctl, native command trigger):**

```sh
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --name-pattern '^hostpath-provisioner-csi-' \
  --disruption-count 1 \
  --trigger-command "test \"\$(oc get vmbackup vm-backup-${RUN_ID} -n vm-cbt-demo -o jsonpath='{.status.conditions[?(@.type==\"Progressing\")].status}' 2>/dev/null)\" = True && test \"\$(oc get vmbackup vm-backup-${RUN_ID} -n vm-cbt-demo -o jsonpath='{.status.conditions[?(@.type==\"Done\")].status}' 2>/dev/null)\" != True" \
  --trigger-expected-rc 0 \
  --triggers-interval 3 \
  --triggers-timeout 1800 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
```

Why a command trigger instead of the `--trigger-k8s-*` used by CBT-F-06: the k8s trigger resolves a single dot-path (e.g. `status.conditions.0.status`) and cannot express the compound "Progressing=True AND Done≠True" active-copy condition (krkn `k8s_trigger.py` parses exactly one `field op value`). The active-copy window requires both clauses; the command trigger (validated shell form, per the 2026-10-13 harness learning: JSONPath single-quoted inside the command substitution, exact expanded string proven via `bash -c` against live objects) expresses it directly.

The destination PVC is applied in the same manifest as the backup object and binds sub-second on WaitForFirstConsumer (measured), so "PVC Bound" adds nothing to the condition — `Progressing=True` with `Done≠True` is the strict active-copy signature and holds for the entire 52 s copy.

krknctl starts **before** `make e2e` (background) so image startup is absorbed ahead of the window; `--triggers-on-timeout fail` fails loudly if the backup never progresses.

No `oc` fallback needed: target and timing are expressible with the native trigger.

## 5. Deterministic injection signal

**Condition:** `vm-backup-${RUN_ID}` has `Progressing=True` and `Done≠True` — true for the whole active copy (condition holds from first processing until terminal), polled every 3 s. The pod deletion lands somewhere inside the 52 s copy window; the exact offset is recorded by the observer (delete timestamp vs. backup terminal timestamp) and reported. No arbitrary sleep anywhere.

**Chaos duration:** single pod delete (default graceful; no `--force`); recovery is the DaemonSet's own reconciliation (~10 s to a new Ready pod, measured in CBT-F-06).

## 6. Pass/fail criteria

A product **pass** requires all applicable checks:

- Injection: the CSI plugin pod (pre-captured UID) is deleted while `vm-backup-${RUN_ID}` is Progressing and not Done; the observer's timeline shows delete-time inside the copy window.
- CSI recovery: a replacement pod (new UID) reaches Ready without manual intervention; DaemonSet desired/ready counts match afterwards.
- Backup terminal semantics: the full backup either (a) completes with `Done=True`, non-failed reason, `status.type=Full`, one checkpoint, expected included volumes, tracker advanced exactly once — **or** (b) fails cleanly: `Done=True` with a clear failure reason, tracker NOT advanced, no partial image accepted as restorable. Both are acceptable per the issue ("the behavior is intentionally being established"); a FAIL verdict requires a false success over invalid data, a tracker advance from a failed copy, or an indefinite Progressing hang.
- PVC state: destination PVC remains `Bound` (or, if the backup failed, is preserved in a consistent state); no stuck attachment.
- VM/VMI: Running/Ready with CBT `Enabled` throughout.
- Post-chaos same-VM verification (required): if the full succeeded, run the planned incremental pass(es) + final restore verification (the workflow's `TYPE=incremental` on the same VM; last pass verifies the chain/restore); if the full failed, run `make e2e TYPE=recover` (distinct recovery backup/PVC, baseline restore).
- Backup image integrity: covered by the restore verification's file/byte/hash comparison (11–17 checks).

**Evidence commands:** `oc get pods -n openshift-cnv` (plugin identity before/after), `oc get ds hostpath-provisioner-csi -n openshift-cnv`, `oc get vmbackup/vm-tracker/vm -n vm-cbt-demo` snapshots, events, plus the standard run `summary.json`.

## 7. Blast radius, recovery, and conflicts

Single cluster-wide HostPath CSI plugin pod (`--disruption-count 1`, name-pattern scoped). Transient effect on any other HPP PVC provisioning in flight anywhere at that moment; do not run concurrently with other HPP-sensitive scenarios. DaemonSet owns recovery. The trigger refuses stale/duplicate RUN_IDs. Never `make clean-all`; preserve failed objects.

Unresolved/uncertain: whether a graceful pod delete (SIGTERM to the plugin containers) vs. the already-proven CSI-idle behavior (CBT-F-06) changes in-flight I/O behavior is exactly what the run establishes; the copy may continue (volume already mounted in the attachment pod's node mounts) or fail. The observer must capture the launcher-side copy behavior (compute logs) and any `HotplugFailed`/backup events to distinguish.
