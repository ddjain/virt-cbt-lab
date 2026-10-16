# [Contract clarification]: failed backup terminates with condition Done=True carrying a failure reason

## What this is, in one paragraph

When a backup fails, the product still sets its "done" flag to true — the same flag it uses for a
successful backup — and puts the bad news only in a free-text reason string. So a backup that copied
nothing usable (in the recorded run: the destination filled up mid-copy) looks finished/successful to
anything that watches that boolean, and only a human reading the reason would notice. The run's own
end-to-end tooling had to special-case it ("reached Done=True but the backup actually failed"). The
failure was otherwise well behaved — the reason names the real error, and the chain bookkeeping (the
tracker, which remembers the latest checkpoint for the next incremental) correctly did not advance — so
the ask is a machine-readable success/failure signal, not a different outcome.

**When → then → expected**

- **When** the product is finishing a backup whose copy failed — CBT: the change-tracking backup mode,
  so the object is a `VirtualMachineBackup` (`.status.conditions`) whose copy wrote nothing usable.
- **And** the disruption is applied: **none is required.** The observed case came from a capacity
  failure, not from chaos: the incremental's destination volume was too small, so the copy hit ENOSPC
  ("no space left on device"). Recorded: backup `vm-incremental-20261015-cbtf04-r03-p01` on a 30 Gi
  destination, 29 GiB written, terminal at 10:35:56Z. (In the recorded run the failure occurred during
  the CBT-F-04 chaos scenario's recovery sequence, but with no chaos active at that moment and no causal
  link — the same object shape would appear from any failed copy.)
- **Then (current behaviour):** the CR settles with `Progressing=False` **and** `Done=True`, both
  carrying the reason `Backup has failed: No space left on device`. `Done=True` is exactly the signal a
  successful backup emits (with the reason `Successfully completed VirtualMachineBackup`), so consumers
  cannot tell the two apart without parsing the free-text reason.
- **Expected behaviour:** a consumer determines backup success/failure from structured status without
  string-matching — either `Done` means success and failure gets its own condition/state, or `Done` is
  documented as "the reconciler finished" with a machine-readable failure signal alongside it.

> **Standalone engineering ticket.** Write it so an engineer who has never seen this repository,
> this cluster, or this test harness can reproduce and triage it from the ticket alone.
>
> Fill rules:
> - Choose **Bug** only for a demonstrated violation of an established contract; choose
>   **Improvement** for an ambiguous contract, a requested behaviour, or a status/reporting gap.
> - Keep **product** defects and **test-harness** defects in separate tickets. Never mix them.
> - Every factual claim carries an evidence citation — a command output, an object field with its
>   UTC timestamp, or a sanitized short quote. Label anything beyond the artifacts as **inference**.
> - Never invent a Jira key or claim this was filed. Mark unproven causes as unproven.
> - Write `not recorded` (and say why) rather than guessing a value. Never fill a gap with a
>   plausible number.
> - Sanitize: no credentials, tokens, kubeconfig paths, private hostnames, absolute host paths,
>   broad selectors, or cluster-cleanup commands.
>
> Delete this preamble in the filed ticket; keep the structure below.
>
> **Extraction note.** This file is the ticket draft formerly embedded in
> `cbt-chaos/scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r03-product-flow.md` §4 ("Draft 2 —
> [Contract clarification]: failed backup terminates with condition Done=True carrying a failure
> reason"), re-rendered onto this template with every claim, quoted string, artifact path and UTC
> preserved; it keeps the draft's single-run reproduction class. Paths given without a prefix are
> relative to `cbt-chaos/scenarios_v2/CBT-F-04/`.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Contract clarification (failure semantics) — candidate Bug pending a second reproduction of a failed backup.** |
| Priority (proposed) | Unassigned pending triage (proposed **medium**: success and failure are indistinguishable on the boolean alone, so monitoring/orchestration can silently treat a failed backup as complete). |
| Severity class | status truthfulness (failure semantics), with an observability consequence |
| Owning component (suspected) | **suspected** KubeVirt/OpenShift Virtualization backup controller — the `VirtualMachineBackup` status conditions. |
| Component(s) proven involved | the backup controller's status writer (it published `Done=True` together with a failure reason on the same object and second) and the tracker update path, which behaved correctly by *not* advancing (so the writer of `Done` and the writer of the tracker disagree about "success"). |
| Reproducibility | `single observation` — this class is the draft's, and it is exact: **observed once** (r03, on the retry-3 incremental). r02 produced no failed backup object, so there is no second reproduction. Any failed copy (e.g. the capacity path below) is expected to produce the same condition pair. |
| Status / confidence | **Observed once (r03 retry-3); the failure itself was loud** — an explicit reason string and a tracker that did not advance. The question is **purely the meaning of `Done=True`**; no root cause is claimed, and none is needed to ask it. |
| Blast radius | per backup object: any consumer of `VirtualMachineBackup.status.conditions` (monitoring, orchestration, retry logic) — across all VMs if the consumer is cluster-wide. |
| Data at risk? | **No, not from this defect** — the failed copy produced no usable restore point, and the chain was left intact because the tracker did not advance (the retry on a larger destination succeeded). The risk this ticket names is a *consumer-side* risk: automation treating a failed backup as complete. |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r03`, 2026-10-15 (UTC) — single run. r02 had no failed backup object (not reproduced). |
| Affected versions | Same as the sibling sizing ticket: OpenShift/CNV versions `not recorded` for r03 (only the virt-controller image digest `sha256:23e9322e…` was captured); storage ODF / Ceph RBD (`ocs-storagecluster-cephblockpool`); guest RHEL 9. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — a `VirtualMachineBackup` writes the VM's changed blocks into a destination
  volume and reports progress and completion through `.status.conditions` (`Progressing`, `Done`). A
  `VirtualMachineBackupTracker` holds the chain's latest checkpoint so the next backup can be
  incremental.
- **Where the gap sits** — the `Done` condition: on success it is `True` with reason
  `Successfully completed VirtualMachineBackup`; on the observed failure it is **also** `True`, with
  reason `Backup has failed: No space left on device`. The `Progressing` condition carries the same
  failure reason with `False`.
- **Observed surface vs. origin** — the surface is the CR's condition set; the origin is the copy failure
  inside the launcher. The tracker (a different writer) already treats the pass as failed — it did not
  advance — so two product components answer "did this backup succeed?" differently.
- **Why it matters** — anything that keys on `Done=True` (the natural success signal, and the one the
  happy path uses) will act on a failed backup as if it were a good restore point. The run's own E2E
  tooling had to add a special case to avoid exactly that.

## Environment (measured, not assumed)

Only one run label (r03) is behind this ticket; provenance is tagged per row. `not recorded` means
nothing captured it (never inferred). Node names are genericised as `<node>`.

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | `not recorded` — this run captured no cluster version (the run's own report/analysis record that only the virt-controller digest was captured) | `oc version`, `oc get clusterversion version` | `not recorded` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` (same cluster, later) |
| Platform | OpenShift update channel | `not recorded` — never captured | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | `not recorded` |
| Platform | `oc`/`kubectl` plugin versions | `not recorded` — never captured | `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image / kernel / container runtime | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow); kernel 5.14.0-687.48.1.el9_8.x86_64; cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / node in scope | one worker ran the CBT VM and its launcher (`<node>`) | run VMI snapshots | r03 |
| Virtualization | CNV / HCO / virt-controller version (**load-bearing**: this component writes the condition) | virt-controller pod label `app.kubernetes.io/version=4.22.12`; image digest `registry.redhat.io/container-native-virtualization/virt-controller-rhel9@sha256:23e9322e…` (tag not captured) | pod label/digest recorded in the run analysis from the run's pod snapshot | r03 |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` = virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | `cluster 2026-10-16` |
| Virtualization | virt-launcher image digest | `not recorded` — not captured for this run (the launcher's log line `Backup has failed` is cited, but not its image) | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | virt-handler image digest | `not recorded` — not captured for this run | `oc get ds virt-handler -n openshift-cnv -o jsonpath=…` (not run) | `not recorded` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | `not recorded` for this run; the cluster's launcher images report libvirt 11.10.0 / QEMU 10.1.0 / QEMU API 11.10.0 | `virsh version` in the launcher's `compute` container | `not recorded` (r03) / `cluster 2026-10-16` |
| Backup API | CRD group / version (the surface at issue) | `backup.kubevirt.io/v1alpha1` — `VirtualMachineBackup.status.conditions` | the run's captured CR snapshot (`incremental-backup-post-retry3.yaml`) | r03 |
| Storage (**in use**) | StorageClass + provisioner + pool | ODF / Ceph RBD, block pool `ocs-storagecluster-cephblockpool`; the failed incremental's destination was a 30 Gi volume that filled to 29 GiB | run analysis; `recovery/rbd-du-backup-volumes.txt` | r03 |
| Storage (**in use**) | CSI driver image + version | `not recorded` — the run names the driver/pool, not its image digest | `oc get ds` in the CSI namespace (not run) | `not recorded` |
| Storage (**in use**) | destination usage at failure | 29 GiB written on the 30 Gi destination before ENOSPC; the retry used a 100 Gi destination | `recovery/rbd-du-backup-volumes.txt`, `recovery/rbd-du-retry5.txt` | r03 |
| Storage (**present but NOT exercised**) | ODF operator versions / Ceph image | ODF/OCS `4.22.5-rhodf` operator set; RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`; cluster health `HEALTH_OK` | `oc get csv -n openshift-storage`, `oc get cephcluster` | `cluster 2026-10-16` (stack identity only — the defect is in the CR's status, not storage) |
| Storage (**present but NOT exercised**) | HostPathProvisioner / hostpath CSI; local-storage-operator | StorageClass `cbt-demo-hpp` (+ hostpath CSI DaemonSet in ns `openshift-cnv`); `local-storage-operator.v4.22.0-202609291750` — both installed, neither in this ticket's path | `oc get sc`, `oc get ds`, `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release | RHEL 9 | run report/analysis | r03 |
| Guest | kernel | `not recorded` — no in-guest `uname -r` in this run | `uname -r` in the guest (not run) | `not recorded` |
| Guest | guest agent package version | `not recorded` — not captured | `rpm -q qemu-guest-agent` (not run) | `not recorded` |
| Guest | vCPU / memory | `not recorded` — not captured | VM spec vs `nproc` / `free` (not run) | `not recorded` |
| Guest | state at the failure | after the rigour attempt the guest was at 10 files (8 base + 2 incremental-01), 65G free (`done.json` retry3); the failed attempt's mutation had filled the guest earlier (`df`: 77G/77G) | `recovery/guest-state-post-failure.txt`, `done.json` | r03 |
| Harness (internal only) | workflow + trigger checksum | `virt-cbt-lab`; trigger sha256 `a214796df0d0395833f23d9de07ef9d5a7888d5d1fcbef7bb4779926488d837b` from this run's own pack | `runs/20261015-cbtf04-r03/preflight.json` | r03 |

## Reproducibility

- **Classification**: `single observation` — carried exactly as the draft states it: observed once, on
  **one** run label (`20261015-cbtf04-r03`), on that run's retry-3 incremental. r02 had no failed backup
  object at all, so no second reproduction exists.
- **Attempts**: 1 failure observed (r03 retry-3, 2026-10-15), by the scenario's own harness/operator on
  one cluster; the run's read-only watcher (`vmbackup-all-r03`) plus live reads captured the object.
- **Stability — exact**: the condition pair (`Progressing=False` and `Done=True`, both with the same
  failure reason), the reason string itself, and the tracker's unchanged state. **Unknown**: whether
  other failure classes (I/O error, device removal, job abort) produce the same pair — not attempted.
- **Preconditions**: any incremental backup whose copy fails after the object exists. The recorded case
  used the destination-capacity path (destination smaller than the copy — see the sibling sizing
  ticket), which is the easiest deterministic way to make a copy fail.
- **Second entry path**: not attempted. [INFERENCE] that the condition-shape is produced for any failed
  copy, because the reason string is written from the copy outcome rather than from a storage-specific
  branch — unproven, and a reason to try a second failure class first.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261015-cbtf04-r03`** (namespace `vm-cbt-demo`), so
> each command can be compared with this ticket's evidence. For a fresh reproduction pick your own
> run-scoped names. Every command is scoped to one named object. **No injection is needed**: make a copy
> fail (the destination-capacity path is the recorded one) and read the conditions. Repository helper
> (optional accelerator, never required): `cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh`.

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine / VMI | `vm-20261015-cbtf04-r03` | `not recorded` | 2026-10-15 ~09:1xZ | kept; Running, CBT `Enabled` (including after the failed pass) |
| Pod (launcher) | `virt-launcher-vm-20261015-cbtf04-r03-mqtfn` | bbaa5ed9-… (abbreviated in the analysis) | ~09:14Z | kept; `restartCount 0` across the window; its log carries `Backup has failed` |
| VirtualMachineBackupTracker | `vm-tracker-20261015-cbtf04-r03` | 4e362574-dee7-4fec-bb8d-1ba46f814f02 | `not recorded` | kept; **unchanged** at the full checkpoint after the failure (`tracker-post-retry3.yaml`), then advanced once on the retry |
| VirtualMachineBackup (full, the checkpoint base) | `vm-backup-20261015-cbtf04-r03`; checkpoint `vm-backup-20261015-cbtf04-r03-2026-10-15_09-14-05` | `not recorded` | 09:14:05Z | kept; `Done=True` `Successfully completed VirtualMachineBackup` 09:15:15Z |
| VirtualMachineBackup (failed incremental — the subject) | `vm-incremental-20261015-cbtf04-r03-p01`; checkpoint `vm-incremental-20261015-cbtf04-r03-p01-2026-10-15_10-35-19` | f71e404c-c817-489b-ac39-7e38a007aed8 | 10:34:53Z (checkpoint 10:35:19Z) | **deleted by the operator** ~10:41Z (Lead-approved) after its evidence was captured, so the name could be reused; retained as `recovery/incremental-backup-post-retry3.yaml` |
| PVC (failed destination) | the 30 Gi incremental destination of retry-3; exact name `not recorded` | `not recorded` | ~10:34Z | kept; holds the partial copy (29 GiB written) |
| PVC (retry destination) | 100 Gi incremental destination of retry-5; exact name `not recorded` | `not recorded` | ~10:48Z | kept; absorbed the successful retry |
| E2E tooling log (the special-case message) | `recovery/incremental-followup-retry3.log` | — | 10:35–10:5xZ | retained; contains the E2E special case "reached Done=True but the backup actually failed" |
| Preserved artifacts | `runs/20261015-cbtf04-r03/recovery/{incremental-backup-post-retry3.yaml, tracker-post-retry3.yaml, tracker-post-retry5.yaml, guest-state-post-failure.txt, done.json}` and the run's `evidence-index.json` (68 files, sha-pinned at run close) | — | run close | retained |

### Steps

**Step 1 — Setup: CBT-enabled VM with an existing checkpoint and a destination you can make too small.**
When: before creating the failing backup.
```bash
oc get vmi vm-20261015-cbtf04-r03 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r03 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
```
What you must see: VMI `Running` with CBT `Enabled`, and a tracker holding one checkpoint (r03:
`vm-backup-20261015-cbtf04-r03-2026-10-15_09-14-05`).

**Step 2 — Make the copy fail.** When: right before creating the incremental. The recorded way is a
destination too small for the data that must be copied (see the sibling sizing ticket for why that is
bigger than the logical change) — recorded: a 30 Gi destination for a copy that needed 68 GiB.
```bash
# create the undersized destination PVC for the incremental first, then start the backup against it
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-incremental-20261015-cbtf04-r03-p01
  namespace: vm-cbt-demo
spec:
  pvcName: <undersized-destination-pvc>
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261015-cbtf04-r03
YAML
oc logs virt-launcher-vm-20261015-cbtf04-r03-mqtfn -n vm-cbt-demo -c compute | grep -F 'Backup has failed'
```
What you must see: the launcher log line `Backup has failed` once the destination is full (recorded:
29 GiB written), and the backup object heading for a terminal state.

**Step 3 — Read the conditions (this is the whole defect).** When: once the backup is terminal.
```bash
oc get vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo -o yaml | grep -A12 '^status:'
oc get vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason}{"\n"}{end}'
```
What you must see (recorded, `incremental-backup-post-retry3.yaml`, captured 10:35:56Z):
`Progressing=False reason=Backup has failed: No space left on device` **and**
`Done=True reason=Backup has failed: No space left on device`; `status.type` = `Incremental`. **The
punchline: `Done=True` here is the same value a successful backup reports** — compare with the full
backup's `Done=True reason=Successfully completed VirtualMachineBackup`.

**Step 4 — Read-only check that the rest of the product already treats it as a failure.** When: right
after step 3.
```bash
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r03 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
oc get vmbackup -n vm-cbt-demo -o custom-columns=NAME:.metadata.name,TYPE:.status.type,DONE:.status.conditions[?(@.type=="Done")].status,REASON:.status.conditions[?(@.type=="Done")].reason
```
What you must see: the tracker is still at the **full** checkpoint (it did not advance to the failed
backup's checkpoint), while the failed CR says `Done=True`. That mismatch is the ticket.

**Step 5 — Recovery.** When: after capturing steps 3–4 (the failed CR's YAML is the evidence; capture it
before deleting).
```bash
oc get vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo -o yaml > /tmp/failed-incremental-r03.yaml
# the recorded run deleted the failed CR at ~10:41Z (Lead-approved) so the object name could be reused
oc delete vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo
# re-run the same backup on a correctly sized destination (recorded: 100 Gi -> Done=True 10:50:14Z)
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r03 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
```
What you must see: the retry reaches `Done=True` with `Successfully completed VirtualMachineBackup` and
the tracker advances exactly once (the failed pass never advanced it). What this does **not** fix: the
condition semantics — a consumer keying on `Done=True` still cannot tell the failed attempt from the
successful one (that is why the run's E2E tooling carries a hard-coded special case).

## Current behaviour (observed)

When an incremental backup fails mid-copy (destination ENOSPC), the CR settles with conditions
`{type: Progressing, status: False}` and `{type: Done, status: True}`, both with reason `Backup has
failed: No space left on device`. `Done=True` is the same terminal signal that accompanies successful
backups (`Done=True` + "Successfully completed…"). A consumer polling `Done=True` as completion-success
cannot distinguish the two without parsing the free-text reason. The run's own E2E tooling had to add a
special case ("reached Done=True but the backup actually failed").

Observed object (`incremental-backup-post-retry3.yaml`): `vm-incremental-20261015-cbtf04-r03-p01` at
10:35:56Z — `Done=True`, reason "Backup has failed: No space left on device", type `Incremental`,
checkpoint `…-10-35-19`; tracker unchanged at the full checkpoint (`tracker-post-retry3.yaml`); the
launcher log carries "Backup has failed"; captured by the `vmbackup-all-r03` watch and live reads.
*(All of the above: independent artifact observations; the interpretation that consumers must
string-match is an obvious consequence of the artifacts, and the E2E special case is itself an artifact
of the run's tooling.)*

## Expected behaviour (contract)

Clarify (or fix) the condition semantics: what `Done=True` with a failure reason obligates consumers to
do, or a machine-readable success/failure distinction (e.g. a `Failed` condition or `Done` reserved for
success).

**Acceptance check.** A consumer can determine backup success/failure from structured status without
parsing reason strings — e.g. `oc get vmbackup <name> -o jsonpath='{...}'` yields a distinct value (or
condition) for the failed case that no string-matching is needed to interpret.

**Acceptance criteria (from the reporter draft, preserved):** structured, machine-readable
success/failure in `VirtualMachineBackup` terminal status; documented semantics for `Done` with failure
reasons.

## Impact, workaround and data safety

- **Functions lost / how an operator notices.** Nothing is lost in the run: the tracker correctly did
  **not** advance, so the chain stayed intact and the retry succeeded. The operator-visible problem is
  interpretative — a healthy-looking `Done=True` on a backup that produced nothing usable. An operator
  notices only by reading the reason string (or by shipping an exception like the run's E2E tooling).
- **Blast radius.** Every consumer of `VirtualMachineBackup.status.conditions`: monitoring, retry
  automation, status dashboards. Per backup object; cluster-wide if the consumer is.
- **Data safety.** **No state corruption in-run** (tracker correctly not advanced; retry succeeded). The
  risk this ticket names is that monitoring/orchestration silently treats failed backups as complete —
  which becomes a data-protection risk downstream, because a "complete" backup that holds nothing is
  what a restore will later rely on.
- **Workaround / operator runbook.** Alert on `Done=True && reason != "Successfully completed…"` — which
  is brittle string matching and breaks on any reason-text change or localisation; that brittleness is
  the reason to fix the contract rather than document the workaround. Nothing was live-verified as a
  product-side fix (none was attempted).
- **Frequency.** Every failed copy. In the recorded run one failure occurred and one retry succeeded;
  failures are expected to be routine wherever destinations are sized by logical change (see the sibling
  ticket) or where storage errors occur.
- **Unknowns this ticket deliberately does not claim.** Whether `Done` is *intended* as "the reconciler
  finished" (a triage/API-contract answer, not an artifact question); whether other failure classes
  produce the same pair; whether any existing CNV convention already reserves `Done=True` for success.

## Evidence

**Artifact index.** Paths are as the analysis/draft records them, relative to
`cbt-chaos/scenarios_v2/CBT-F-04/`. The run's full root is sha-pinned in
`runs/20261015-cbtf04-r03/evidence-index.json` (68 files, generated 2026-10-15T12:15:37Z).

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `runs/20261015-cbtf04-r03/recovery/incremental-backup-post-retry3.yaml` | the decisive object: `Progressing=False` and `Done=True`, both `Backup has failed: No space left on device`; type `Incremental`; checkpoint `…-10-35-19` | 10:35:56Z | raw |
| `runs/20261015-cbtf04-r03/recovery/tracker-post-retry3.yaml` | tracker **unchanged** at the full checkpoint after the failure — the product's other answer to "did this succeed?" | 10:35–10:41Z | raw |
| `runs/20261015-cbtf04-r03/recovery/incremental-followup-retry3.log` | the E2E tooling's special case: "reached Done=True but the backup actually failed" | 10:35–10:5xZ | raw |
| `runs/20261015-cbtf04-r03/recovery/{rbd-du-backup-volumes.txt, rbd-du-retry5.txt}` | destination usage: 29 GiB written on the 30 Gi destination before ENOSPC; the retry's 100 Gi destination | 10:3x–10:50Z | raw |
| `runs/20261015-cbtf04-r03/recovery/{tracker-post-retry5.yaml, done.json}` | the retry: `Done=True` success, tracker advanced once, restore verified | 10:50Z | raw |
| `runs/20261015-cbtf04-r03/observer/watches/vmbackup-all-r03*` (supplementary watch) | the backup's transitions as observed live, including the failure and the CR's deletion | 10:34–10:41Z | raw |
| `runs/20261015-cbtf04-r03/reports/test-run-report.md`, `test-run-result.md` | the run's account of the failed pass, the retry, and the acceptance results | run window | derived |
| `analysis/20261015-cbtf04-r03-product-flow.md` §2 arrow 4, §4 Draft 2 | the analysis of the failure and the draft (this file's source) | 2026-10-15 | derived (analysis) |
| `runs/20261015-cbtf04-r03/preflight.json` | GO decision and trigger sha256 `a214796d…` | 09:04:06Z | raw |

**UTC timeline** (setup → precondition → injection → effect → failure → recovery):

| # | Time (UTC), 2026-10-15 | Event | Source |
|---|---|---|---|
| 1 | 09:14:05 → 09:15:15Z | Setup/precondition: full backup completes; checkpoint `…-09-14-05` becomes the chain head | run report; tracker watch |
| 2 | 10:34:53Z | The failing incremental is created; checkpoint `…-10-35-19` created at 10:35:19Z (no chaos active — this is the recovery sequence) | run analysis §2 |
| 3 | 10:35:19 → 10:35:56Z | **Effect/failure**: the copy fills the 30 Gi destination (29 GiB written) and fails; launcher logs `Backup has failed`; the CR settles at 10:35:56Z | `incremental-backup-post-retry3.yaml`; launcher log; `rbd-du-backup-volumes.txt` |
| 4 | 10:35:56Z | **The defect's surface**: `Done=True` with reason `Backup has failed: No space left on device` — identical boolean to a success — while the tracker stays at the full checkpoint | `incremental-backup-post-retry3.yaml`; `tracker-post-retry3.yaml` |
| 5 | ~10:41Z | The failed CR is deleted (Lead-approved) after evidence capture; the `vmbackup-protection` finalizer completes | run analysis §2, §3 |
| 6 | 10:48:40 → 10:50:14Z | **Recovery**: the same backup on a 100 Gi destination reaches `Done=True` `Successfully completed VirtualMachineBackup`; tracker advances once; chain restore 10 files / 10,737,418,240 B, 0 failures | `tracker-post-retry5.yaml`; `done.json`; run report |

**Retained state.** The decisive object survives as a raw capture (`incremental-backup-post-retry3.yaml`)
rather than a live object: the failed CR itself was deleted at ~10:41Z with Lead approval, after its
evidence was captured, so its name could be reused for the retry. Everything else was kept: the tracker
(before/after states), both destination PVCs, the guest-state capture, the recovery logs, and the run's
68-file sha-pinned evidence index. The VM stayed Running with CBT `Enabled` throughout, including after
the failed pass.

## Negative results and what would falsify this ticket

- **Refuted: "the tracker advanced anyway."** `tracker-post-retry3.yaml` shows it unchanged at the full
  checkpoint, and it advanced exactly once on the successful retry. So the chain was not corrupted by
  this pass.
- **Refuted: "the failure was silent."** It was **loud**: an explicit reason naming the real error
  ("No space left on device") appears on the object, and the launcher logged `Backup has failed`. This
  ticket is not about the message being missing — only about the boolean disagreeing with it.
- **Refuted: "the run's tooling handled it fine."** It had to add a special case
  ("reached Done=True but the backup actually failed"), i.e. even the run's own automation could not
  rely on the condition.
- **Refuted: "chaos caused it."** The failure occurred in the post-chaos recovery sequence with a settled
  control plane and no controller-availability dependency; the capacity mistake is what failed the copy.
- **Limits of this evidence (stated, not refuted).** A single run label and a single failed object;
  only one failure class (capacity) observed; CNV/OpenShift versions `not recorded` for the run; the
  failed CR was deleted after capture (so a live re-read is impossible).
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. The product documents `Done` as "the reconciler finished" and provides another structured field for
     success — then the ask reduces to documenting it (still a worthwhile doc change).
  2. A `Failed` condition (or similar) already exists on terminal failures and this run simply did not
     capture it — that would make the ticket a misread of the object.
  3. Reason strings are shown to be a supported, stable machine interface for this API (i.e. consumers
     are expected to string-match) — that would make the current shape the contract and the ticket a
     documentation request.

## Additional feedback (reporter's notes)

- **Preserved triage questions.** (a) Is `Done` intended as "reconciler finished" rather than "backup
  succeeded"? If so, document it; if not, is a `Failed=True` condition warranted? (b) Do CNV status
  conventions elsewhere reserve `Done=True` for success?
- **Smallest experiments that would settle the open points.** (1) Produce a second failed backup with a
  **different** failure class (I/O error, aborted job) and compare the condition pair — settles whether
  the shape is generic. (2) Enumerate the condition types reported by a successful, a failed and an
  aborted backup side by side — settles whether a `Failed` condition already exists elsewhere. (3) Ask
  the owner what `Done` means (a documentation answer, not an experiment).
- **Cross-references.**
  - Same folder: `cbt-incremental-copy-size-is-peak-dirty-volume.md` — the sizing gap that produced this
    failure (its r03 retry-3 evidence is the same object examined here). The two tickets are
    complementary: one is "the destination was too small", the other is "a failed backup does not say so
    in a machine-readable way".
  - Same folder: `hotplugfailed-lstat-on-successful-detach.md` — the mirror-image reporting problem
    (a *failure* signal emitted on a *successful* path). Together they show the surface's semantics are
    not reliable in either direction.
  - Source analysis (unchanged apart from the pointer at its head):
    `analysis/20261015-cbtf04-r03-product-flow.md` §2 (the failure) and §4 Draft 2 (this draft).
  - **Separately and clearly labelled — harness/tooling, not this ticket:** the run's E2E tooling's
    hard-coded special case is a workaround inside the harness; it is cited as evidence of the problem,
    not filed as a harness defect. The failed CR's deletion (~10:41Z, Lead-approved) was a run-management
    decision, not part of this ticket's remediation.
- **Environment-specific notes for the next reproducer.** (a) Read the conditions with
  `-o jsonpath='{range .status.conditions[*]}…'` — a plain `-o yaml` shows the pair but hides the point
  that `Done=True` is identical to the success case. (b) Capture a **successful** backup's conditions in
  the same session for side-by-side comparison; that comparison is the evidence. (c) Do not delete the
  failed CR until its YAML is captured — this run had to rely on the captured file. (d) The failed
  destination keeps the partial copy (29 GiB here); account for that space before retrying.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted.
- [x] No private hostnames or absolute host paths — cluster node names are genericised as `<node>`.
- [x] No broad selectors (names or run-scoped labels only) — every command is scoped by the run's exact
      backup/tracker/PVC names.
- [x] No destructive commands other than the documented, scoped workaround — the only deletion
      prescribed is the run's own failed backup CR, which must be captured to YAML first, is scoped to
      that single object, and is labelled as the recorded recovery action (the retry then runs on a
      correctly sized destination).
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the condition and
      usage reads are the read-only commands the run used; the note above the steps says which command
      shapes are re-creations and that no injection is required.
