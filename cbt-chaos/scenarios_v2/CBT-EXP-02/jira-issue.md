# Improvement: Validate push-mode abort cleanup when a full-backup CustomResource is deleted mid-copy

> **Experiment / validation contract; unfiled; no Jira key.** Provenance: `cbt-chaos/scenarios_v2/CBT-EXP-02/scenario-spec.md` (EXP-2, adaptive experiment, ranked #2 new-defect candidate by the campaign Judge). Structure follows `cbt-chaos/template/engineering-jira-issue-template.md`. This ticket specifies an experiment and pre-registers **no** expected product outcome: it does not import a verdict from any earlier attempt, and no lifecycle or fault was executed for the prepared bundle described here.
>
> Chosen issue type is **Improvement** (contract validation), not Bug: no current product defect is demonstrated. A prior attempt of this same experiment (`artifacts/CBT-EXP-02/runs/20261014-exp02-r01/`, 2026-10-14, different workload profile) graded PASS on every product criterion with one documented **harness** evidence gap (its residue listing captured only a debug-pod banner). That record is a lead for coverage, not a predicted result for this attempt.

## What this is, in one paragraph

Changed-block-tracking (CBT) push-mode backup writes a running virtual machine's disks into a separate destination PVC (persistent volume claim) that is hot-plugged to the VM only for the duration of the copy. An operator can delete the backup's own Kubernetes custom resource (CR) while that copy is in flight. Deleting the object mid-copy must trigger the controller's cancel/abort path: the destination volume must be detached again, the VM (a "guest") must not be left paused or frozen, the tracker object that records the chain's latest checkpoint must not advance from an unconfirmed backup, and the same VM must still be able to produce a verified full backup with a hash-identical restore. This ticket defines how that behaviour is measured and what evidence closes it.

**When → then → expected**

- **When** a fresh RHEL 9 VM with CBT enabled has no backup yet, a full `VirtualMachineBackup` of that VM is in its active copy phase (its `Progressing` condition is true, its `Done` condition is not, the launcher has logged `Backup started` for this backup name, and QMP `query-block-jobs` on the running VM shows a running backup job with a nonzero offset below its length), and the tracker has no checkpoint yet.
- **And** the disruption **CBT-EXP-02** is applied by `cbt-chaos/scenarios_v2/CBT-EXP-02/run.sh`: 20 seconds into that copy the run issues one UID-preconditioned `DELETE` for the exact `VirtualMachineBackup` object through an owned local `oc proxy` using a Kubernetes `DeleteOptions` body (`preconditions.uid`). This is **not** a krknctl scenario: inspected `krknctl` v0.14.2-beta metadata (`list available`; `describe`/`run --help` for `pod-scenarios` and `kubevirt-outage`) offers pod/container/VMI-level faults only, and no installed scenario deletes a named custom resource on a condition. It is a documented read-only-condition + `oc`/`kubectl` fault-action (Pattern C).
- **Then (current behaviour):** not recorded in this bundle. The abort path is unproven here; the pre-registered risk set is a stuck finalizer (`backup.kubevirt.io/vmbackup-protection` retained past the 300-second observation window), a leaked hot-plug attachment, a paused/frozen VM, a tracker advanced from the aborted backup, or a same-VM recovery backup that cannot complete or restore.
- **Expected behaviour:** the finalizer is removed and the object disappears promptly; the VM stays `Running` with no `Paused` condition; the destination volume is detached from the VMI (`status.volumeStatus` no longer hot-plugged) and absent from the guest's device list; the tracker's `latestCheckpoint` never references the aborted backup; and a fresh-named forced full backup on the same VM reaches `Done=True` with a success reason whose restore matches the recorded baseline (file count, byte count, SHA-256 manifest). Partial-image residue on the retained destination PVC is recorded as an observation, not scored as a defect.

## At a glance

| Field | Value |
|---|---|
| Issue type | Improvement / validation contract, not a demonstrated Bug |
| Priority | Unassigned pending triage |
| Severity class | Data-protection chain integrity, resource release and status truthfulness (hypothesis) |
| Owning component (suspected) | KubeVirt CBT backup abort/detach path, **suspected** |
| Component(s) proven involved | not established by this bundle (no run yet); the path exercised is the `backup.kubevirt.io/v1alpha1` API plus the virt-launcher/guest QMP and hot-plug surfaces |
| Reproducibility | Not established here. One prior attempt of this experiment (2026-10-14, different workload profile) was deterministic for the window (single observation) and graded PASS; this bundle is a fresh, evidence-complete re-validation |
| Status / confidence | Test intent fixed by the scenario; product outcome unproven |
| Blast radius | One run-owned VM, one backup CR (deliberately deleted), one destination PVC (retained as evidence); the recovery leg creates one more PVC and one more backup on the same VM. No shared-resource fault, no other VM/tracker touched |
| Data at risk | Disposable run-owned guest data only; the source image and unrelated namespaces are excluded |
| Related scenario / execution | `CBT-EXP-02`; no execution claimed by this ticket |
| Affected versions | Measured at preparation (see Environment); load-bearing only as recorded context |

## Context

- **What the feature does** — a `VirtualMachineBackupTracker` remembers the chain's latest checkpoint; each `VirtualMachineBackup` creates a checkpoint (the named disk set later backups measure changed blocks against) and copies the disks into a destination PVC. A full backup copies the whole disk; at the configured profile the copy is roughly a minute, which is the window this experiment acts inside.
- **Where the failure sits** — the object/status surfaces a user or operator observes: the backup CR's `status.conditions` (`Progressing`, `Done` + `reason`), `metadata.finalizers`/`deletionTimestamp`, the VMI's `status.conditions` (`Paused`) and `status.volumeStatus` (hot-plug attachment), the VM's `status.changedBlockTracking.backupStatus`, the tracker's `status.latestCheckpoint`, and events on the VM/backup.
- **Observed surface vs. origin** — abort-path effects are reported on several objects that are not the deleted CR (VMI volume status and events, tracker status, libvirt checkpoint tree inside the guest). A clean-looking CR removal alone is therefore not evidence of a clean abort; this experiment captures the other surfaces explicitly.
- **Why it matters** — a leaked hot-plug attachment, a paused guest or a tracker that advances from a canceled copy would silently reduce or break a VM's backup coverage. The tracker and checkpoint surfaces are what later incremental backups depend on.

## Environment (measured, not assumed)

Measured read-only at preparation on the intended execution host; the run's own preflight re-captures these and is authoritative for the attempt.

| Layer | Component | Version / identifier | How obtained |
|---|---|---|---|
| Platform | OpenShift Container Platform (server) | 4.22.15 | `oc get clusterversion version` |
| Platform | Kubernetes API server | v1.35.6 | `oc get --raw=/version` |
| Platform | `oc` client | 4.22.15 | `oc version --client` |
| Nodes | OS image / kernel / runtime (first worker) | RHEL CoreOS 9.8.20260915-0, kernel 5.14.0-687.48.1.el9_8, cri-o 1.35.8 | `oc get node -o jsonpath=...status.nodeInfo` |
| Virtualization | CNV / HCO CSV | kubevirt-hyperconverged-operator.v4.22.12 (Succeeded) | `oc get csv -A` |
| Virtualization | KubeVirt observed version | `sha256:2f654df4…a29293` | `oc get kubevirt -A -o jsonpath=...observedKubeVirtVersion` |
| Virtualization | virt-launcher image digest (probe VM) | `…virt-launcher-rhel9@sha256:2131d3d2…d36596f` | `oc get pod <launcher> -o jsonpath=...image` |
| Virtualization | libvirt / QEMU in the launcher | libvirt 11.10.0 API, QEMU 10.1.0 | `virsh version` in the launcher's `compute` container |
| Backup API | CRD | `backup.kubevirt.io/v1alpha1`, resource `virtualmachinebackups` | `oc get crd virtualmachinebackups.backup.kubevirt.io` |
| Backup API | CR deletion finalizer | `backup.kubevirt.io/vmbackup-protection` | `oc get vmbackup -n vm-cbt-demo -o custom-columns=...:metadata.finalizers` |
| Storage (in use) | StorageClass / provisioner / pool | `ocs-storagecluster-ceph-rbd` / `openshift-storage.rbd.csi.ceph.com` / `ocs-storagecluster-cephblockpool` | `oc get storageclass ocs-storagecluster-ceph-rbd -o jsonpath=...` |
| Storage (in use) | pool logical headroom | `max_avail` = 30,992,528,048,128 bytes (≈28.1 TiB) | `ceph df --format json` in `rook-ceph-tools` |
| Storage (source) | RHEL 9 DataSource source PVC | `rhel9-7005186c23b8`, UID `3cec59a9-ae1f-437d-92ea-e108faf26f53`, `Bound` (HostPath class) | `oc get datasource rhel9 -o jsonpath=...`, `oc get pvc … -o json` |
| Guest key | guest SSH key mode on the execution host | existing pair, public SHA-256 `1f578f1a…9c0952` | `guest-key-approval.sh` fingerprint of the public half |
| Restore helper | image reference | digest-pinned `quay.io/rh-ee-darjain/cbt-restore-helper@sha256:95c59329…269e1f` | approved host configuration; the run rejects a non-digest reference |
| Chaos tooling | krknctl | v0.14.2-beta installed; no scenario deletes a named custom resource | `krknctl list available`, `describe`/`run --help` |

Not load-bearing here: no node placement pin exists for this manifest profile (verified: `manifests/vm-large-odf.yaml` carries no `nodeSelector`/`nodeAffinity`, and existing VMs in the namespace run on several different workers), so the node is resolved live from the VMI and its identity is recorded before and after the fault.

## Reproducibility

- **Classification:** not established for this bundle. The one prior attempt of this experiment reached the window deterministically (1/1) and passed; that record used a different workload profile (1000 files, HostPath variant) and its residue capture was incomplete.
- **Attempts:** this bundle has never been executed.
- **Preconditions:** a fresh, unused lifecycle identity; the entrypoint owns the whole sequence; a readable and approved execution host configuration; a copy window that has not already reached `Done=True` at the deletion instant. A window miss is recorded as an invalid injection (exit 4), never silently retried.
- **Second entry path:** a mid-copy deletion can also be reached by canceling from an external operator; this experiment only exercises the CR-deletion path.

## Chaos Injection

Exact target chain: approved lifecycle → run-owned VM `vm-<lifecycle>` (UID captured at setup) → its sole Ready launcher pod (UID) → the run's `VirtualMachineBackup` `vm-backup-<lifecycle>`, asserted by name **and** `virt-cbt-lab/run-id` label, `spec.source.name` = the run's tracker, and `spec.pvcName` = the run's destination PVC; the action carries the object's live `metadata.uid`. Excluded: every other VM, tracker, backup and PVC in the namespace (compared as name→UID maps before and after), and the read-only probe VM `vm-cbt-demo`.

## Injection Timing

After the run's own full-backup stage has created the CR and the active-copy compound condition holds (`Progressing=True` ∧ `Done≠True` ∧ no `deletionTimestamp` ∧ launcher `Backup started` line for this backup name ∧ live QMP `query-block-jobs` backup job with `0 < offset < len` ∧ `VMI Running` on the same UID ∧ tracker checkpoint still unset), then a 20-second mid-copy dwell, then a same-instant re-validation (same UID, still not `Done`, still not deleting). `Done=True` at the deletion instant is a harness-invalid window (exit 4) with the evidence preserved.

## Steps to reproduce (exact commands and timing)

These are the approved-bundle command shapes. They are **unexecuted**; use only fresh run-scoped names and obtain whole-bundle approval first. Placeholders: `<lifecycle>`, `<chaos-id>`, `<ns>`.

**Step 1 — Rehearse and approve.** Resolve the exact planned VM name first, then allocate the descriptive attempt ID with `cbt-chaos/run-id.sh vm-<lifecycle> cr-delete 1`. Rehearse and inspect:

```bash
export LIFECYCLE_ID='<lifecycle>'
export CHAOS_RUN_ID='<chaos-id>'
bash cbt-chaos/scenarios_v2/CBT-EXP-02/run.sh --plan
bash cbt-chaos/scenarios_v2/CBT-EXP-02/run.sh --manifest
bash cbt-chaos/scenarios_v2/CBT-EXP-02/run.sh --preflight   # read-only; emits approval-candidate.json
```

The Lead then records explicit approval (complete file hashes + effective parameters + cluster UID) as `approval.json` in the scenario directory and creates the matching run root and `run.json` (`scenario_id`, `run_id`, `lifecycle_id`, `vm_name`, `phase` = `started`, `verdict` = null). Only after that:

```bash
bash cbt-chaos/scenarios_v2/CBT-EXP-02/run.sh --execute
```

**Step 2 — One entrypoint owns the sequence.** `run.sh` alone runs `make vm-setup`, arms scoped read-only watches, starts `make vm-backup` in the background, waits for the active-copy window, performs the fault action, measures the abort, then runs the recovery leg (forces a fresh-named full backup through the same tracker and calls `scripts/vm-cbt-restore-test.sh --recovery-attempt r001`). No duplicate stage is launched by hand; do not run `make vm-cbt-verify` or `make vm-cbt-recover` around it (they cannot model a canceled-and-deleted backup; see Additional feedback). `make monitor` is not part of the sequence (read-only, and not needed for the evidence contract).

**Step 3 — The product action (single, UID-guarded).** The entrypoint starts an owned local proxy (`oc proxy --address=127.0.0.1 --port=<free>`), waits for `GET /version` = 200, then issues the deletion with the live UID as a precondition:

```bash
curl --noproxy '*' -sS -X DELETE -H 'Content-Type: application/json' \
  --data-binary @<delete-options.json> -o <response.json> -w '%{http_code}\n' \
  "http://127.0.0.1:<port>/apis/backup.kubevirt.io/v1alpha1/namespaces/<ns>/virtualmachinebackups/vm-backup-<lifecycle>"
```

where `delete-options.json` is `{"apiVersion":"v1","kind":"DeleteOptions","gracePeriodSeconds":0,"preconditions":{"uid":"<live-backup-uid>"}}`. A `409` means the precondition failed (the object changed): the run stops without a mutation. An unguarded delete-by-name is not acceptable: the same-instant UID revalidation is mandatory.

**Step 4 — Observe (all read-only).** Immediately and again at +5 s and after the observation bound: the CR's disappearance/`deletionTimestamp`/`finalizers`, the VMI's phase and `Paused` condition, the VMI's `status.volumeStatus` entry for the destination PVC, `virsh domblklist`/`query-block-jobs`/`checkpoint-list` through the same launcher (the guest's own view), the VM's `status.changedBlockTracking.backupStatus`, the tracker's `latestCheckpoint`, UID-scoped events for the VM and the backup, and the destination PVC/PV/CSI-handle plus any `VolumeAttachment` node pin.

**Step 5 — Recover without repairing the abort.** The entrypoint creates a fresh PVC with the retained destination volume's storage profile and a fresh `VirtualMachineBackup` named `vm-recovery-full-<lifecycle>-r001` with `forceFullBackup: true` through the existing tracker, waits for `Done=True` (bounded), validates type/reason/checkpoint/PVC/included volumes/tracker advance, records the attempt in `runs/<lifecycle>/run.json` as `backup_verified`, then runs the repository restore test in recovery mode and preserves its exit status. Nothing is deleted: the aborted destination PVC, the recovery PVC and the recovery backup remain for analysis.

## Current behaviour (observed)

Not recorded for this bundle. No raw condition, action or abort-path capture exists for it, and no historical observation is substituted. Existing comparable evidence is limited to `artifacts/CBT-EXP-02/runs/20261014-exp02-r01/` (different profile, harness residue gap) and is used only to shape coverage.

## Expected behaviour (contract)

- Contract under test: a user-initiated deletion of an in-flight push-mode backup CR is a supported operation whose abort path releases the destination attachment, does not disturb the running guest, does not advance the tracker from an unconfirmed backup, and leaves the VM able to produce a verified backup.
- **Acceptance check:** with the raw artifacts from one run, a reviewer can (a) see the active-copy condition and the same-instant UID revalidation immediately before the action, (b) confirm the delete was accepted for that exact UID, (c) measure request→object-gone against the 300-second bound, (d) confirm the VMI was never `Paused` and the destination volume is no longer hot-plugged or present in the guest's device list, (e) confirm the tracker's `latestCheckpoint` never names the aborted backup's checkpoint and the aborted checkpoint does not become the parent of the recovery checkpoint, and (f) confirm the recovery full backup's `Done=True` success reason and a byte-identical restore of the recorded baseline.
- Missing mandatory evidence for any of those is an INCONCLUSIVE/UNKNOWN element for the independent Analyst, never a silent PASS. The 300-second (and any other) bound is an approved test window, not a documented product SLA.

## Impact, workaround and data safety

- **Functions lost if the risk set is real:** backup coverage for the affected VM (a tracker advanced from a canceled copy, or a leaked attachment that blocks the next backup), and guest availability in the freeze case.
- **Blast radius:** one VM, one CR, one destination PVC per attempt; the recovery leg adds one PVC and one backup on the same VM. No shared storage fault, no other VM/namespace.
- **Data safety:** only disposable run-owned guest data is at risk; the source image and other namespaces are untouched. The abort path is API-supported and is the documented way to cancel a backup.
- **Workaround / operator runbook:** none is proposed here; retain the aborted destination PVC and the recovery artifacts for diagnosis, and do not hand-detach, unmount or delete in-flight resources while investigating.
- **Unknowns this ticket does not claim:** whether any host-level mount or node pin is released (no host-level probe is authorized in this bundle's read scope; the retained PVC/PV/CSI-handle correlation is recorded, host release stays UNKNOWN), and whether residue on the destination PVC is expected to be cleaned at abort (the source says partial files are cleaned only when the copy fails to start).

## Execution and Approval

The Lead owns approval, the matching pre-armed run root/`run.json`, execution, monitoring, lifecycle state, reports and the verified pull. Approval binds the complete file hash list (`bundle-files.txt`), the effective parameter object emitted by `--preflight`, the execution host and cluster/context fingerprints, the cluster UID, the guest-key mode/fingerprint, the digest-pinned restore image, the exact lifecycle and attempt IDs, the effective blast radius and the observation windows. Changing any file, parameter or scope requires fresh approval; the bundle author never approves or grades its own bundle. `--preflight` is read-only and needs no approval; `--execute` re-verifies the approval and its required identities before doing anything, and records every child process's exit status separately from any product meaning.

## Evidence

Planned per-attempt evidence root: `cbt-chaos/scenarios_v2/CBT-EXP-02/runs/<attempt-id>/` with `trigger.log`, `condition.json`, `backup-pre-delete.yaml`, `deletion-velocity.json`, `vmi-after-abort.yaml`, `tracker-after-abort.yaml`, `target-pvc-residue.txt`, `backups-after-recovery.txt`, `backup-stuck.yaml` (only when the 300-second bound expires with the CR present), watch streams and per-step status files under `execution/`, and `injection-confirmation.json` authored as machine observations with `verdict: null`. Lifecycle evidence stays in `runs/<lifecycle-id>/` and is referenced, never copied. The independent Analyst writes `analysis.json`.

## Negative results and what would falsify this ticket

- The pre-registered risk set is falsified by one clean attempt: prompt finalizer removal, no `Paused` condition, no hot-plug attachment after abort, tracker never advancing from the aborted backup, and a verified recovery full backup with a byte-identical restore. Two prior sibling scenarios already produced attachment-leak findings on other paths (`cbt-chaos/scenarios_v2/CBT-F-05/bugs/backup-destination-volume-remains-mounted-after-terminal-success.md`, and the expired-checkpoint retention family in `artifacts/cloud05/scenarios_v2/CBT-F-04/bugs/`), which is why those surfaces are measured here even though they are not expected to reproduce.
- This ticket is not falsified by residue alone (the source expects partial files to survive an aborted copy) and not by the cosmetic terminal reason wording discussed below.

## Additional feedback (reporter's notes)

- A user-initiated cancellation is reported with the terminal reason prefix `Backup has failed: …` (observed in the earlier attempt of this experiment). If a stuck CR is captured here, its `Done` reason should be read as part of the evidence rather than treated as an error string.
- Harness facts that shaped this bundle, and that a reproducer without this repository must work around: `make vm-cbt-recover` refuses an aborted-and-deleted backup (its `original_full_done_failed` precondition cannot be satisfied), and `make vm-cbt-verify` needs the original full backup recorded in the lifecycle state. The experiment therefore implements the scenario's own recovery oracle and never runs those two targets.
- An unflagged same-VM recovery can land as an `Incremental` when the tracker already advanced; this bundle always sets `forceFullBackup: true` and validates `status.type == "Full"`.
- No inspector/debug pod is authorized: residue is captured only through pods that already mount the destination PVC, and "no consumer exposes `qemu-img`" is recorded as unavailable rather than inferred.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys
- [x] No private hostnames or absolute host paths
- [x] No broad selectors (exact run-scoped names/labels only)
- [x] No destructive commands other than the single approved, UID-guarded CR deletion
- [x] Commands shown are the ones validated (mechanism rehearsed read-only; the deletion itself was never executed)
