# Improvement: Validate mid-copy deletion of a VirtualMachineBackupTracker (second entry path to the no-deadline backup wedge)

> **Experiment / validation contract; unfiled; no Jira key.** Provenance: `cbt-chaos/scenarios_v2/CBT-EXP-08/scenario-spec.md` (EXP-8, WeaknessAnalyst P2-r1, Judge-confirmed compact design). Structure follows `cbt-chaos/template/engineering-jira-issue-template.md`.
>
> Chosen issue type is **Improvement** (contract validation), not Bug: no current product defect is claimed by this ticket. A 2026-10-14 attempt of this experiment (`artifacts/CBT-EXP-08/runs/20261014-exp08-r01/`) observed a wedge plus two extra deadlock behaviours; that record is a **lead for coverage, not a predicted result**, and it was produced by an earlier, differently-prepared bundle whose trigger died mid-recovery. No lifecycle or fault was executed for the bundle described here (`cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh`); every command below is an approved-but-unexecuted command shape.

## What this is, in one paragraph

Changed-block-tracking (CBT) push-mode backups record the chain's latest checkpoint in a small Kubernetes object called a *tracker* (`VirtualMachineBackupTracker`), and each backup (`VirtualMachineBackup`) copies a running VM's disks into a destination volume that is hot-plugged only while the copy runs. Deleting that tracker while a copy is in flight is a plausible operator cleanup action, but the backup controller only writes the tracker at completion. This ticket defines how to measure whether the in-flight backup still reaches a terminal state when the tracker disappears mid-copy, whether the controller or the operator has to recreate the tracker before the VM can be backed up again, and whether a fresh backup then completes consistently.

**When → then → expected**

- **When** a fresh RHEL 9 VM with CBT enabled has no checkpoint yet, a full `VirtualMachineBackup` of that VM is in its active copy phase (its `Progressing` condition is true, its `Done` condition is not, the launcher has logged `Backup started` for that backup name, and QMP `query-block-jobs` on the running VM shows a running backup job with a nonzero offset below its length), and the run's `VirtualMachineBackupTracker` still has no `status.latestCheckpoint`.
- **And** the disruption **CBT-EXP-08** is applied by `cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh`: 15 seconds into that copy the run issues one UID-preconditioned `DELETE` for the exact `VirtualMachineBackupTracker` through an owned local `oc proxy` using a Kubernetes `DeleteOptions` body (`preconditions.uid`), then requires the tracker `GET` to return HTTP 404 (fail-closed). This is **not** a krknctl scenario: the installed `krknctl` v0.14.2-beta metadata (`list available`; `describe`/`run --help` for `pod-scenarios` and `kubevirt-outage`) offers pod, container and VMI-level faults only, and no installed scenario deletes a named custom resource on a condition. It is a documented read-only-condition + `oc`/`kubectl` fault action (Pattern C).
- **Then (current behaviour):** not recorded for this prepared bundle. The API-side path is unproven here; the pre-registered risk set is a backup that never reaches a terminal condition (stuck `Progressing` with a tracker-404 requeue in the controller log and no deadline), a wedged backup whose own deletion also fails while the tracker is gone, a VM-wide rejection of new backups while a non-terminal backup exists, and a tracker that is never recreated automatically.
- **Expected behaviour:** the backup reaches a terminal condition inside the observation bound even though its tracker disappeared mid-copy — either a genuine completion (`Done=True`, non-failure reason, `type=Full`, checkpoint recorded) or a bounded, honest failure — and the VM can produce a verified fresh full backup again without an operator having to guess a repair order. Which of those the product actually does is exactly what this ticket measures.

## At a glance

| Field | Value |
|---|---|
| Issue type | Improvement / validation contract, not a demonstrated Bug |
| Priority (proposed) | unassigned pending triage. If the wedge reproduces, impact is loss of backup coverage for the affected VM (see Impact) |
| Severity class | availability, with a data-protection (backup-chain) component and a status-truthfulness component (hypothesis) |
| Owning component (suspected) | KubeVirt CBT backup controller's tracker handling (`updateBackupTracker` patch path) and its requeue/abort path — **suspected**; no source was read for this bundle |
| Component(s) proven involved | not established by this bundle (no run yet). The path exercised is the `backup.kubevirt.io/v1alpha1` API (`virtualmachinebackup` / `virtualmachinebackuptracker`), the `virt-controller` backup reconciler, and the virt-launcher/QMP copy surface |
| Reproducibility | Not established here. The 2026-10-14 attempt (2026-10-14, earlier bundle, different storage profile) was a single observation that wedged; this bundle is a fresh, evidence-complete validation |
| Status / confidence | Test intent fixed by the scenario; product outcome unproven |
| Blast radius | One run-owned VM, one tracker (deliberately deleted), one destination PVC retained as evidence; the recovery leg may delete the run's own wedged backup CR once and adds one re-applied tracker, one PVC and one backup on the same VM. No shared-resource fault, no other VM/tracker touched |
| Data at risk | No: disposable run-owned guest data only; the source image, the cluster's other namespaces and every other VM/tracker are excluded from the fault |
| Related scenario / execution | `CBT-EXP-08`; no execution claimed by this ticket. Cross-reference (lead only): `artifacts/CBT-EXP-08/runs/20261014-exp08-r01/` and the sibling wedge ticket `artifacts/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md` |
| Affected versions | measured values in **Environment** below; on the execution host OpenShift 4.22.15 with CNV `kubevirt-hyperconverged-operator.v4.22.12` |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt CBT push-mode backups. A `VirtualMachineBackupTracker` (the CR that stores the chain's latest checkpoint) hangs off a source `VirtualMachine`; each `VirtualMachineBackup` names that tracker as its source and copies the VM's disks into a destination PVC (persistent volume claim) that is hot-plugged into the running VM only for the copy. On success the controller writes the new checkpoint back to the tracker so the next pass can measure changed blocks against it. The tracker is also the object the controller re-reads when it needs to decide whether a backup is finished or aborted.
- **Where the failure sits** — the observable surfaces are the backup CR's `status.conditions` (`Progressing`, `Done` + `reason`, and, on the abort path, `Initializing`/`Deleting`), `metadata.finalizers`/`deletionTimestamp`, the tracker's existence and `status.latestCheckpoint`, the VMI's `status.volumeStatus` (hot-plug attachment of the destination PVC), the VM's `status.changedBlockTracking.backupStatus`, and the `virt-controller` container log.
- **Observed surface vs. origin** — the operator's action (deleting a tracker) is on one object, but the consequence is reported on other objects: the in-flight backup CR, its finalizer and its destination attachment, and events on the VM/VMI. A clean-looking tracker removal alone therefore proves nothing; this ticket captures the backup, the destination volume and the controller log explicitly.
- **Why it matters** — a backup that never reaches a terminal state keeps its finalizer and its destination attachment, blocks the API's one-backup-per-source guard, and (per the 2026-10-14 lead) makes every later backup of that VM fail at admission until an operator deletes the wedged CR — which itself needs the tracker to exist again. A VM can therefore end up with no backup coverage at all, and with no obvious repair order, purely because someone deleted a tracker object.

## Environment (measured, not assumed)

Read-only facts verified on the intended execution host (`cloud05`, executing checkout `/root/virt-cbt-lab`) while preparing this bundle. The run's own preflight re-captures all of them and is authoritative for the attempt. Rows marked `not recorded` were **not** measured during this preparation.

| Layer | Component | Version / identifier | How obtained |
|---|---|---|---|
| Platform | OpenShift Container Platform (server) | 4.22.15 | leader-verified at preparation (`oc get clusterversion version`); the run re-captures it |
| Platform | Kubernetes API server | v1.35.6 — **inherited context**, not re-measured for this preparation (recorded by the sibling CBT-EXP-06 work on the same cluster) | `oc version` (to be re-captured by the run's preflight) |
| Platform | update channel, `oc` plugin list | `not recorded` | not measured during preparation |
| Nodes | worker population | ≥ 2 Ready workers required and present | leader-verified at preparation; the run fails preflight below that |
| Nodes | OS image / kernel / container runtime | `not recorded` for this preparation; measured values for this cluster are in the sibling CBT-EXP-06 tickets | `oc get nodes -o wide` (not run) |
| Virtualization | CNV / HCO CSV | `kubevirt-hyperconverged-operator.v4.22.12` | leader-verified at preparation (`oc get csv -A`) |
| Virtualization | kubevirt observed version / virt-launcher image | `not recorded` for this preparation | to be captured from the run's own launcher pod |
| Virtualization | `virt-controller` replicas | 2 Ready replicas. **Both** are followed by the bundle's log window (label `kubevirt.io=virt-controller`, namespace `openshift-cnv`) because the backup reconciler traffic is not confined to one replica; at preparation one replica had served the recent `Successfully updated BackupTracker …` lines and the other was mostly idle (pod names and restart counts are recorded in the run evidence, not here) | leader-verified at preparation; the run records the replica list before and after the window |
| Backup API | CRD group / version and resources | `backup.kubevirt.io/v1alpha1`, `virtualmachinebackups`, `virtualmachinebackuptrackers` | leader-verified at preparation |
| Backup API | CR deletion finalizer | `backup.kubevirt.io/vmbackup-protection` on `VirtualMachineBackup`; **the tracker's own finalizer/`deletionTimestamp` behaviour is not recorded for this preparation** and is measured by the run (a tracker that does not disappear is recorded as a failed fail-closed postcondition, not repaired) | leader-verified for the backup CR; the run records the tracker's GET status |
| Storage (in use) | StorageClass / provisioner / clusterID / pool | `ocs-storagecluster-ceph-rbd` / `openshift-storage.rbd.csi.ceph.com` / `openshift-storage` / `ocs-storagecluster-cephblockpool` | leader-verified at preparation (`oc get storageclass … -o json`) |
| Storage (in use) | pool logical headroom | `ceph df` `max_avail` for the block pool = 30,600,257,863,680 bytes (≈27.8 TiB), cluster health `HEALTH_OK` at preparation | leader-verified at preparation (`ceph status`/`ceph df` in `rook-ceph-tools`) |
| Storage (in use) | profile sizes | destination PVC 80 Gi (`__LARGE_DISK_SIZE__` for RHEL 9, large-odf variant); the run's preflight refuses to start without 500 GiB of logical headroom | `manifests/full-backup-large-odf.yaml`, `scripts/common.sh` |
| Storage (source) | RHEL 9 DataSource | `rhel9` in namespace `openshift-virtualization-os-images`, ready `Bound` source PVC (exact PVC name/UID re-captured by the run) | leader-verified at preparation |
| Namespace | `vm-cbt-demo` | UID `4d35b0b5-f317-41f3-9078-4a4ada417972`; no storage/PVC quotas; contains other runs' VMs/trackers/backups that are excluded and must not be touched | leader-verified at preparation |
| Guest | workload profile | 1000 baseline files, 15–20 MiB each (≈17 GiB), CBT enabled, 1 vCPU / 2 GiB as rendered by `manifests/vm-large-odf.yaml`; the run sets these explicitly on every `make` command line so they cannot drift from the approved parameters | `.env` and the bundle's effective parameters |
| Guest key | mode on the execution host | resolved by the bundle as `existing-pair` (public-half SHA-256 only) or `setup-managed`; the real value is an approval input emitted by `--preflight` | `guest-key-approval.sh` |
| Restore helper | `RESTORE_HELPER_IMAGE` | **not digest-pinned at preparation** (`…cbt-restore-helper:latest-kmod-20261015`, a tag). The bundle refuses a non-digest reference, **so the Lead must pin the digest in `.env` before approval**; `.env` is part of the hashed manifest | `.env` on the execution host |
| Chaos tooling | krknctl | v0.14.2-beta installed; `list available` + `describe kubevirt-outage` verified: no installed scenario deletes a named custom resource on a condition | leader-verified at preparation; the run re-records the metadata |
| Timing reference | a recent successful full backup at this profile | CR created 03:37:17Z, `Done=True` 03:38:34Z (≈77 s end to end; the copy window inside it is roughly the last 55–70 s) | leader-verified at preparation (lifecycle `20261017033303-happy-tiger-4d5a`) |

**Load-bearing rows.** The 15 s post-copy-start dwell only fits if the copy is still running at that moment, which is why the bundle re-validates the live state in the same instant as the delete rather than trusting a timer. The two-replica controller population is why the log window follows the label rather than a single pod name.

## Reproducibility

- **Classification:** not established for this bundle. The 2026-10-14 attempt of this experiment wedged on its single observation (one data point, earlier bundle, different storage profile).
- **Attempts:** this bundle has never been executed; it is being prepared for one attempt (plus at most one approved repair if the independent Analyst finds the injection invalid).
- **Preconditions:** a fresh, unused lifecycle identity; the entrypoint owns the whole sequence; a readable, approved execution host configuration with a digest-pinned restore image; the copy still active at delete time; the tracker under test present with the exact UID and no checkpoint yet.
- **Stability (from the lead only, not a prediction):** the 2026-10-14 record describes an exact, reproducible-in-that-run sequence — tracker 404 at the copy +15 s, a backup that never became terminal, a controller requeue on the missing tracker, and a wedged CR that only cleared after the tracker was recreated. Timings in that record varied (retry counts and windows), not the outcome.
- **Second entry path:** the same final consequence has been documented from a corrupted per-disk checkpoint bitmap (`CBT-EXP-06`). This ticket exercises the API-side entry; a defect reachable two ways is usually not an artefact of one test.
- **What breaks the repro:** a copy that has already finished (`Done=True` at the delete instant) is a harness-invalid window and stops the attempt (exit 4) with the evidence preserved; a tracker whose `GET` does not become 404 is likewise not a valid injection of this experiment and stops the attempt before any recovery leg.

## Chaos Injection

Exact target chain: approved lifecycle → run-owned VM `vm-<lifecycle>` (UID captured at setup) → its sole Ready `virt-launcher` pod (UID) → the run's `VirtualMachineBackupTracker` `vm-tracker-<lifecycle>`, asserted by name **and** the run's `virt-cbt-lab/run-id` label **and** `spec.source.kind=VirtualMachine` with `spec.source.name` = the run's VM, then the object's live `metadata.uid` is used as the `DeleteOptions.preconditions.uid` of the single DELETE. The destination PVC and the in-flight backup are *observations*, not targets.

Excluded from the fault: every other VM, tracker, backup and PVC in the namespace (compared as name→UID maps before and after, with this attempt's own names excluded), the read-only control VM `vm-cbt-demo`, and anything cluster-scoped. The recovery leg's only additional mutation beyond the approved tracker delete is one UID-guarded delete of the run's own wedged backup CR (the documented way to clear a non-terminal pass), one re-application of the run's own tracker manifest when the tracker is absent, and one fresh destination PVC plus one fresh-named backup.

## Injection Timing

After the run's own full-backup stage has created the tracker, the destination PVC and the backup CR, and once the active-copy compound condition holds — backup `Progressing=True` ∧ `Done≠True` ∧ no `deletionTimestamp` ∧ run-scoped labels/source/pvc ∧ the launcher's `Backup started` line for that backup name ∧ a live QMP `query-block-jobs` backup job with `0 < offset < len` ∧ `VMI` `Running` on the same UID ∧ the tracker present with the exact UID, source = this VM and no checkpoint yet — the run holds **15 s**, then re-validates the backup (same UID, still not `Done`, not deleting, still run-scoped) **and** the tracker (same UID, checkpoint still unset, not deleting) in the same instant as the action. Only then is the single DELETE issued. `Done=True` at that instant is a harness-invalid window (exit 4) with the evidence preserved; the fault is never retried silently.

## Steps to reproduce (exact commands and timing)

These are the approved-bundle command shapes and are **unexecuted**. They need a dedicated cluster, a new run-scoped lifecycle and whole-bundle approval. Placeholders: `<lifecycle>` (a fresh run id), `<chaos-id>` (the attempt id), `<ns>` (the test namespace), `<kubeconfig>` (the approved host-local kubeconfig path — never committed).

**Concrete objects used in this report.** No object was created: this ticket describes a prepared, unexecuted attempt. The names below are the *planned* run-scoped names for lifecycle `<lifecycle>`; none of them existed when this ticket was written, and none carries a recorded UID or timestamp.

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine | `vm-<lifecycle>` | captured at setup | — | created by `make vm-setup` |
| DataVolume (root disk) | `vm-disk-<lifecycle>` | — | — | created by `make vm-setup` |
| Service (SSH) | `vm-ssh-<lifecycle>` | — | — | created by `make vm-setup` |
| VirtualMachineBackupTracker | `vm-tracker-<lifecycle>` | captured before the action | — | created by `make vm-backup`, **deleted by this experiment**, re-applied only if absent |
| VirtualMachineBackup (full) | `vm-backup-<lifecycle>` | captured before the action | — | created by `make vm-backup`; kept (possibly wedged) |
| PersistentVolumeClaim (destination) | `vm-backup-pvc-<lifecycle>` | — | — | created by `make vm-backup`; kept as evidence |
| VirtualMachineBackup (recovery) | `vm-recovery-full-<lifecycle>-r001` | — | — | created by the recovery leg only |
| PersistentVolumeClaim (recovery) | `vm-recovery-pvc-<lifecycle>-r001` | — | — | created by the recovery leg only |

**Step 1 — Rehearse and approve (no cluster mutation).** Resolve the exact planned VM name first, then allocate the descriptive attempt id with `cbt-chaos/run-id.sh vm-<lifecycle> tracker-delete 1`. Rehearse and inspect:

```bash
export LIFECYCLE_ID='<lifecycle>'
export CHAOS_RUN_ID='<chaos-id>'
bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --plan
bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --manifest
bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --preflight   # read-only; emits approval-candidate.json
```

The Lead then records explicit approval (complete file hashes + effective parameters + cluster UID) as `approval.json` in the scenario directory and pre-creates the matching run root with a `run.json` carrying `scenario_id=CBT-EXP-08`, the exact `run_id`/`lifecycle_id`/`vm_name`, `phase=started` and `verdict=null`. Only after that:

```bash
bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --execute
```

**Step 2 — One entrypoint owns the sequence.** `run.sh` alone runs `make vm-setup`, arms scoped read-only watches, starts `make vm-backup` as a background child, waits for the active-copy window, performs the fault action, samples the backup and the tracker to terminal or the 900 s bound, pulls the controller log window, probes the aftermath, joins the child, runs the recovery leg and finally `make run-summary`. No stage is launched by hand, and `make vm-cbt-verify`, `make vm-cbt-recover` and `make vm-cbt-restore-test` are deliberately **not** used (see Additional feedback).

**Step 3 — The product action (single, UID-guarded).** The entrypoint starts an owned local proxy (`oc proxy --address=127.0.0.1 --port=<free>`), waits for `GET /version` = 200, and issues the deletion with the live tracker UID as a precondition:

```bash
curl --noproxy '*' -sS -X DELETE -H 'Content-Type: application/json' \
  --data-binary @<delete-options.json> -o <response.json> -w '%{http_code}\n' \
  "http://127.0.0.1:<port>/apis/backup.kubevirt.io/v1alpha1/namespaces/<ns>/virtualmachinebackuptrackers/vm-tracker-<lifecycle>"
```

where `delete-options.json` is `{"apiVersion":"v1","kind":"DeleteOptions","gracePeriodSeconds":0,"preconditions":{"uid":"<live-tracker-uid>"}}`. **What you must see:** HTTP 200 (or 202) for that UID; a `409` means the precondition failed and the run stops without a mutation. An unguarded delete-by-name is not acceptable: the same-instant UID revalidation is mandatory.

**Step 4 — Fail-closed postcondition and observation (read-only).** Immediately after the DELETE, and then once per second inside a bounded window, `GET` the same path and require **HTTP 404**:

```bash
curl --noproxy '*' -sS -o <get-body.json> -w '%{http_code}\n' \
  "http://127.0.0.1:<port>/apis/backup.kubevirt.io/v1alpha1/namespaces/<ns>/virtualmachinebackuptrackers/vm-tracker-<lifecycle>"
```

**What you must see:** `404`. Anything else (for example `200` with a `deletionTimestamp`) is recorded as an unconfirmed injection postcondition, and the attempt stops with the raw evidence preserved rather than claiming the tracker was removed. Then, for up to 900 s, sample every 15 s: the backup CR (`status.conditions`, `Done` reason, `deletionTimestamp`, `finalizers`, `status.type`, `checkpointName`), the tracker (present/absent, UID, `latestCheckpoint`), plus the VMI's `status.volumeStatus` hot-plug entry, `virsh domblklist` / QMP `query-block-jobs` / `checkpoint-list` through the same launcher, and `oc logs -n openshift-cnv <replica> --all-containers=true --timestamps=true --since-time=<delete instant>` for **every** pod labelled `kubevirt.io=virt-controller`.

**Step 5 — Recover without repairing the abort.** If and only if the backup is still not terminal at the bound, the entrypoint issues one UID-guarded DELETE for the wedged backup CR (never forced, never with finalizer edits) and records whether it clears. Then it re-applies the tracker manifest shape (same `spec.source` VM) **when the tracker is absent**, observes whether the wedged CR clears once the tracker exists again, then creates a fresh-named destination PVC with the retained destination's storage profile and a fresh `VirtualMachineBackup` named `vm-recovery-full-<lifecycle>-r001` with `forceFullBackup: true`, waits (bounded) for `Done=True`, and validates type/reason/checkpoint/included volumes/PVC phase/tracker advance. Nothing is deleted: the destination PVC, the recovery PVC, the recovery backup and every wedged object remain for analysis. A rejection of the fresh backup (`spec.source: VirtualMachineBackup "…" in progress for source`) is recorded verbatim as a product observation, not retried.

## Current behaviour (observed)

Not recorded for this bundle: it has never been executed, and no historical observation is substituted for it.

Closest existing record (a **lead**, from a different, earlier bundle and a different storage profile): `artifacts/CBT-EXP-08/runs/20261014-exp08-r01/` — tracker deleted 15 s after observed copy start with the deletion verified, the backup never terminal, the controller logging `BackupTracker vm-tracker-… does not exist` at backup cancellation time (`controller-window.log`), the CR then sticking with a `deletionTimestamp` and a retained `backup.kubevirt.io/vmbackup-protection` finalizer (`backup-deletion-stuck.yaml`), the VM rejecting new backups with `in progress for source`, and the wedged CR clearing only after the tracker was recreated. That record is an **independent artifact observation** of that earlier attempt; the causal chain it implies for this bundle is an **inference** until this attempt's raw evidence exists.

## Expected behaviour (contract) and pass/fail criteria

- **Contract under test:** deleting the tracker of an in-flight backup must not be able to strand the backup. The backup must reach a terminal condition within a bounded time (or report a bounded, honest failure on the backup object itself), must not keep the destination volume attached or the guest frozen, must not silently advance the chain from an unconfirmed copy, and must leave the VM able to produce a verified new full backup.
- **Acceptance check:** with the raw artifacts of one run, a reviewer can (a) see the active-copy condition and the same-instant re-validation of both the backup UID/ownership and the tracker UID/checkpoint immediately before the action, (b) confirm the delete was accepted for that exact tracker UID and that the tracker `GET` then returned 404, (c) classify the backup as terminal or non-terminal at the 900 s bound from the raw samples and the controller log window from both replicas, (d) confirm the VMI was never `Paused` and see whether the destination volume stayed hot-plugged or in the guest's device list, (e) see the tracker's post-state (recreated by the product, still absent, or absent until the bundle re-applied it) and the wedged CR's release outcome, and (f) confirm the recovery backup's `Done=True` success reason, `type=Full`, checkpoint and `includedVolumes`, plus the tracker advancing to that checkpoint.
- **Pre-registered classification (scenario §5):** **STUCK** = no terminal state at the bound plus requeue/tracker-404 evidence in `controller-window.log`; **COMPLETED** = the backup reached `Done`. **PASS (resilient)** = the backup terminal either way with a clean recovery; **FAIL** = the wedge reproduced from this API-side path.
- **Pass/fail criteria in one table:**

| Criterion | Pass condition | How the run records it |
|---|---|---|
| Injection validity | mid-copy window proven; delete accepted for the exact tracker UID; tracker `GET` 404 inside the bound | `condition.json`, `inject-result.txt`/`.json`, `execution/tracker-get-codes.log` |
| Backup outcome | any terminal state (`Done=True` with a non-failure reason, or an explicit failure) | `backup-samples.json`, `backup-final.yaml` |
| Wedge check | no terminal state at the bound is recorded, never auto-repaired | `tracker-deletion.json`, `backup-samples.json` |
| Mechanism evidence | the controller log window from both replicas covers the delete instant | `controller-window.log`, `controller-window.json` |
| Guest effect | VMI not `Paused`; destination attachment recorded | `vmi-after-fault.yaml`, `execution/guest-*` |
| Recovery | fresh backup `Done=True`, `type=Full`, non-empty reason/checkpoint, new PVC `Bound`, tracker advanced | `recovery-operand-checks.json`, `recovery-backup.yaml`, `runs/<lifecycle>/run.json` |
| Blast radius | every other namespace object keeps the same name→UID mapping | `execution/blast-radius.json` |

- Missing mandatory evidence for any of those is an INCONCLUSIVE/UNKNOWN element for the independent Analyst, never a silent PASS. The 900 s (and every other) bound is an approved test window, not a documented product SLA.

## Impact, workaround and data safety

- **Functions lost if the risk set is real:** backup coverage for the affected VM (a backup that never terminates holds the one-backup-per-source guard, and its destination volume stays attached), plus the operator time needed to guess a repair order. Not cluster-wide, and other VMs' trackers/backups are outside the fault scope.
- **Blast radius:** one VM, one tracker (deliberately deleted), one destination PVC per attempt; the recovery leg deletes at most one wedged CR and adds one re-applied tracker, one PVC and one backup on the same VM.
- **Data safety:** no data path is at risk. The copy is read-only with respect to the guest's own disk, the guest keeps running, and only disposable run-owned data is involved. The harm modelled is loss of *backup coverage*, not corruption.
- **Workaround / operator runbook:** none is proposed here. If the lead behaviour reproduces, the practical advice from that record is to recreate the tracker first (which unblocks the abort) rather than deleting the wedged backup CR on its own — but this ticket does not assert that until its own attempt's evidence exists.
- **Unknowns this ticket deliberately does not claim:** whether any host-level mount or node pin is released (no host-level probe is authorized in this bundle's read scope; the destination PVC/PV/CSI-handle/VolumeAttachment correlation is recorded at API level and host release stays UNKNOWN), whether partial images on the retained destination PVC are expected, and whether a container restart inside a `virt-controller` pod mid-window would lose log lines (the replica pods had zero restarts at preparation; the window follows the label and re-lists pods at both ends).

## Execution and Approval

The Lead owns approval, the pre-armed run root and its `run.json`, execution, monitoring, lifecycle state, reports and the verified pull. Approval binds the complete file hash list (`bundle-files.txt`), the effective parameter object emitted by `--preflight`, the execution host and cluster/context fingerprints, the cluster UID, the guest-key mode/fingerprint, the digest-pinned restore image, the exact lifecycle and attempt ids, the effective blast radius and every observation window. Changing any file, parameter or scope requires fresh approval; the bundle author never approves or grades their own bundle. `--preflight` is read-only and needs no approval; `--execute` re-verifies the approval, its file hashes and its required identities before doing anything, and records every child process's own status. At most one approved repair is allowed if the independent Analyst rules the injection invalid, and only after the first attempt has been closed and reported.

## Evidence

Planned per-attempt evidence root: `cbt-chaos/scenarios_v2/CBT-EXP-08/runs/<attempt-id>/` with `trigger.log`, `condition.json`, `inject-result.txt`, `inject-result.json`, `backup-pre-delete.yaml`, `tracker-pre-delete.yaml`, `backup-samples.json`, `tracker-samples.json`, `tracker-deletion.json`, `backup-final.yaml`, `tracker-final.yaml`, `controller-window.log`, `controller-window.json`, `wedged-deletion.json`, `tracker-recreation.json`, `recovery-backup.yaml`, `recovery-operand-checks.json`, and `injection-confirmation.json` authored as machine observations with `verdict: null`. Per-stage statuses, raw sample snapshots, raw per-replica controller logs, watch streams, the blast-radius comparison and the storage-identity correlation live under `execution/`. Lifecycle evidence stays in `runs/<lifecycle-id>/` and is referenced, never copied. The independent Analyst writes `analysis.json`.

## Negative results and what would falsify this ticket

- **Falsifier:** one clean attempt in which the backup reaches a terminal condition either way inside the bound and the VM then produces a verified fresh full backup through a tracker that is present again — with no stuck finalizer, no `Paused` condition, no leaked attachment and no unexplained rejection of the fresh backup.
- The pre-registered risk set is also weakened (not falsified) by a `COMPLETED` outcome: that would show the API-side entry does *not* wedge, leaving the sibling checkpoint-corruption entry as a different problem.
- This ticket is **not** falsified by partial-image residue on the destination PVC, by a non-failure warning in the `Done` reason, or by an `In Progress`/`Deleting` transition name — those are recorded as evidence, not scored as defects.
- Unknown-and-recorded outcomes (a bucket with UNKNOWN exit status): a host-level release check that this bundle does not perform, or a window whose controller log could not be read.

## Additional feedback (reporter's notes)

- **Harness facts that shaped this bundle:** `make vm-cbt-recover` refuses an aborted or deleted mid-copy backup (its `original_full_done_failed` precondition needs a `Done=True` failure on the retained CR) and `make vm-cbt-verify` needs the original full backup recorded in the lifecycle state, so this experiment implements its own recovery oracle and never runs those targets. No restore test is part of this bundle because the scenario's recovery criterion is a fresh backup plus tracker recreation; a restore pod would need separate approval.
- **Review of the earlier attempt's harness:** its trigger process died mid-recovery (a lost SSH session), so the 2026-10-14 record is partly reconstructed; its recovery backup also hit an environmental `No space left on device` on the storage pool, which the *product* faithfully reported as a terminal failure (`Done=True`, reason `Backup has failed: No space left on device`). This bundle therefore checks pool health before starting and uses the independent ODF profile whose pool has >27 TiB free.
- **Preparation findings about the reference bundle** (reported to the Lead, out of this ticket's scope): `CBT-EXP-02/run.sh --plan` does not compile with jq ≥1.6 (bare identifiers and concatenations as object values are not valid jq) and its post-abort probe helper used `local a="$1" b="$a.json"`, which in bash expands `$a` empty in the same `local` statement. Both classes of defect were fixed in this bundle and are worth fixing there.
- **Triage questions this ticket does not answer:** whether the tracker is *supposed* to be recreated automatically by the controller; whether a non-terminal backup should be allowed to hold the one-backup-per-source guard indefinitely; and whether the abort path is *supposed* to require the tracker at all.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys
- [x] No private hostnames or absolute host paths
- [x] No broad selectors (exact run-scoped names/labels only)
- [x] No destructive commands other than the single approved, UID-guarded tracker deletion (plus the documented, bounded recovery actions)
- [x] Commands shown are the ones prepared and rehearsed offline (mechanism rehearsal performed read-only; the deletion itself was never executed)
