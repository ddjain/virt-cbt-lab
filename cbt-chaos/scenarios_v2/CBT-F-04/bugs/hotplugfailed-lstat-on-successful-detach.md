# [Improvement]: `HotplugFailed` event with `lstat disk.img` message fires on the detach path of every successful backup-target hotplug volume

## What this is, in one paragraph

Every time a CBT backup finishes successfully, the node agent emits a **failure** event on the VMI: it
says it "failed to mount filesystem hotplug volume" because a path it looked up no longer exists —
`disk.img: no such file or directory`. The cleanup it is part of actually completes (the attachment pod
is deleted, the volume is unmounted, the PVC stays bound), so nothing is broken except the signal: an
operator who alerts on that event reason gets paged for every successful backup, and a *real* hotplug
failure on the same path becomes impossible to tell apart from this noise. The recorded run showed it on
a chaos pass **and** on a later pass with no chaos at all, and later run labels repeated it.

**When → then → expected**

- **When** the product is detaching the destination volume of a finished CBT backup — CBT: the
  change-tracking backup mode — where that destination volume was **hotplugged** into the running VM
  (attached to the running node and handed to the guest's QEMU for the copy, then unplugged at the end).
- **And** the disruption `CBT-F-04` is applied (a CBT chaos scenario; its spec calls for krkn's
  `pod-scenarios` primitive, and the recorded runs executed it as a scoped `oc delete` of the current
  controller Lease-holder pod inside the copy window): **delete the `virt-controller` pod that holds the
  leader lease while the copy is progressing.** Recorded: copy signal 15:55:39.288849Z, Lease-holder
  `virt-controller-6f7bc6b44c-mrspr` killed 15:55:58Z, new leader elected 15:56:15.657868Z, copy
  completed 15:56:43.685594Z, backup terminal 15:57:09Z. **Here the disruption is not required**: the
  same event fires on the ordinary successful detach path — the recorded run's incremental pass, run
  23 minutes after failover with no chaos active, emitted it identically.
- **Then (current behaviour):** the VMI receives `HotplugFailed` (twice: the event's count doubles from
  1 to 2 inside the same second) with a *mount*-worded message during the *detach* phase, while in that
  same second the attachment pod and hotplug volume are deleted and the volume is unmounted.
- **Expected behaviour:** a successful backup's detach emits no failure-reasoned event — or the event
  and its message should be documented as non-actionable and made distinguishable from a real hotplug
  failure. Cleanup invariants must stay as they are today (pod deleted, volume unmounted, PVC `Bound`).

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
> `cbt-chaos/scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r02-product-flow.md` §3 ("Engineering-ticket
> draft (single reproduction — do not file as confirmed defect)"), re-rendered onto this template with
> every claim, quoted string, artifact path and UTC preserved; it keeps the draft's original
> reproduction class. Paths given without a prefix are relative to `cbt-chaos/scenarios_v2/CBT-F-04/`.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Improvement (candidate Bug pending second reproduction)** — the functional outcome is correct in every observed pass (cleanup and data outcomes fully correct); what is wrong is a failure-signal event on a successful path, plus the mount-worded message on a detach phase. |
| Priority (proposed) | Unassigned pending triage (proposed **low functional / medium observability**: a false failure-signal fires on every successful backup detach of this shape). |
| Severity class | observability (false failure signal), with a contract/message-correctness component |
| Owning component (suspected) | **suspected** KubeVirt/OpenShift Virtualization hotplug detach path (`virt-handler` on the VM's node; backup-target volume attachment lifecycle). |
| Component(s) proven involved | virt-handler on the VM's node (it is the event's source; the message quotes a `lstat` on a CSI `globalmount` path), the CSI node-stage teardown (the path it stats is already gone), and the volume-attachment lifecycle, which nevertheless completes (attachment pod deleted, volume unmounted, PVC Bound). |
| Reproducibility | `single observation` — this is the class the draft carries ("single reproduction — do not file as confirmed defect": run `20261015-cbtf04-r02` only, 2026-10-15, though the pattern fired twice inside that run). **Later run labels did re-observe it** and their analyses recorded that the two-run-label bar was met (`r03` §5, `r04` §3.3) — those observations are listed under **Reproducibility → Attempts** and are left out of this field so the class stays exactly as drafted, for triage to reclassify. |
| Status / confidence | **Confirmed observed behaviour in one run** (both the chaos full pass and a no-chaos incremental pass); **mechanism unknown**; explicitly **not** attributable to the controller disruption (the identical pattern fired on the no-chaos pass). |
| Blast radius | one VMI's event stream per successful backup-target detach — and, by extension, any alert rule or automation cluster-wide that keys on the `HotplugFailed` reason code for CBT backups of this shape. |
| Data at risk? | **No** — no data loss, no cleanup failure, no restore impact was observed in any pass; the only defect is the emitted failure signal. |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r02`, 2026-10-15 (UTC) — the drafted, sole observation. Repeated (see Reproducibility) on `20261015-cbtf04-r03` (2026-10-15, incl. an unrelated same-cluster VM) and `20261015-cbtf04-r04` (2026-10-15). |
| Affected versions | OpenShift Virtualization 4.22.12 (virt-controller pod label `app.kubernetes.io/version=4.22.12`); storage ODF / Ceph RBD (`ocs-storagecluster-ceph-rbd`, CSI driver `openshift-storage.rbd.csi.ceph.com`); OpenShift cluster version not recorded in r02; guest RHEL 9. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — a CBT backup writes into a dedicated destination PVC. To let QEMU write
  it while the VM runs, the volume is **hotplugged**: the node agent (`virt-handler`) attaches it via
  CSI (a `globalmount` staging path under the plugin's directory), mounts it in the pod's
  `hotplug-disks` directory, and exposes it to the launcher. When the backup becomes terminal, the
  controller/handler **detach** it: stop the attachment pod's `hotplug-disk` container, remove the
  hotplug directory, unmount, delete the hotplug volume, and let the `VolumeAttachment` go away.
- **Where the failure sits** — the VMI's event stream. On the *detach* phase, virt-handler emits
  `HotplugFailed` whose message says it failed to **mount** a filesystem hotplug volume because
  `lstat …/disk.img: no such file or directory` — i.e. it is re-checking a source path that the CSI
  teardown has already removed, while the lifecycle being executed is removal, not attachment.
- **Observed surface vs. origin** — the event lands on the **VMI** (`source: virt-handler` on the VM's
  node), but the condition it describes belongs to the backup-target volume's attachment lifecycle; the
  operations that follow in the same second (`SuccessfulDelete` of the attachment pod and hotplug
  volume, `VolumeUnMountedFromPod`, PVC `Bound`) show the cleanup actually completed.
- **Why it matters** — an operator alerting on `HotplugFailed` (a reasonable reading of the reason
  code) gets a failure page on every successful backup detach, and real hotplug failures on the same
  path become indistinguishable from this noise. It also degrades failure semantics for anyone
  building on the event surface.

## Environment (measured, not assumed)

Per-run provenance is called out in the last column: `r02` is the drafted observation; `r03`/`r04`
supply the repeated observations and are also what makes some layers measurable. `not recorded` means
nothing captured it (never inferred). Node names are genericised as `<node>`.

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | `not recorded` for r02/r03 — those runs captured no cluster version. r04 (same cluster, same day) captured **4.22.15** via the krkn live capture in its `trigger.log`; the same cluster measured on 2026-10-16 reports 4.22.15 server+client with kustomize v5.7.1 | `trigger/trigger.log` (r04 `cluster_version`); `oc version`, `oc get clusterversion version` | r04 + `cluster 2026-10-16` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` |
| Platform | OpenShift update channel | `not recorded` — never captured | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | `not recorded` |
| Platform | `oc`/`kubectl` plugin versions | `not recorded` — never captured | `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow) | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | kernel | 5.14.0-687.48.1.el9_8.x86_64 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | container runtime | cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / node in scope | r02: the VMI ran on `<node>` (the same node names the `virt-handler` event source); the CBT demo namespace held several other VMs, which is why an unrelated VM could be observed repeating the pattern | r02 report/analyses (`observer/watches/*`, VMI snapshots) | r02/r03 |
| Virtualization | CNV / HCO / virt-controller version | r02: OpenShift Virtualization 4.22.12 (virt-controller pod label `app.kubernetes.io/version=4.22.12`; r04 records ODF **4.22.5** in its preflight); CSV name `kubevirt-hyperconverged-operator.v4.22.12` per the cluster measurement | pod labels in the run packs; `oc get csv -A` | r02 (label) + `cluster 2026-10-16` (CSV) |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` = virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | `cluster 2026-10-16` |
| Virtualization | virt-handler image digest (**load-bearing**: this is the component that emits the event) | `not recorded` for these runs — not captured in the r02/r03/r04 packs | `oc get ds virt-handler -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | virt-launcher image digest | `not recorded` for these runs | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | `not recorded` for these runs; the cluster's launcher images report libvirt 11.10.0 / QEMU 10.1.0 / QEMU API 11.10.0 | `virsh version` in the launcher's `compute` container | `not recorded` (runs) / `cluster 2026-10-16` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` (the API version of the watched backup objects) | run packs' backup watches (`observer/watches/vmbackup*`) | r02/r03/r04 |
| Storage (**in use**) | StorageClass + provisioner + pool | ODF / Ceph RBD: `ocs-storagecluster-ceph-rbd` used by r02 (CSI driver `openshift-storage.rbd.csi.ceph.com`, named in the event message's path); r03/r04 destination volumes are on the RBD block pool `ocs-storagecluster-cephblockpool` | r02 analysis §3 (draft's affected-versions line); r03/r04 analyses (pool `ocs-storagecluster-cephblockpool`) | r02/r03/r04 |
| Storage (**in use**) | CSI driver image + version | `not recorded` — the runs name the driver, not its image digest | `oc get ds` in the CSI namespace (not run) | `not recorded` |
| Storage (**in use**) | backing device / filesystem / free space | `not recorded` for these runs (destination sizing is discussed in the sibling sizing ticket; r04's incremental destination was a 100 Gi block volume absorbed at ~61 % utilisation) | `rbd du` / provider tools | r04 (utilisation) |
| Storage (**in use**, adjacent) | ODF/OCS operators, Ceph image, health | `4.22.5-rhodf` operators (`odf-operator`, `ocs-operator`, `rook-ceph-operator`, `cephcsi-operator`, `mcg-operator`, `odf-csi-addons-operator`, external-snapshotter); RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`; cluster health `HEALTH_OK` (r04 preflight records the ODF 4.22.5 stack) | `oc get csv -n openshift-storage`, `oc get cephcluster` | `cluster 2026-10-16` (r04 preflight: ODF 4.22.5) |
| Storage (**present but NOT exercised**) | HostPathProvisioner / hostpath CSI | StorageClass `cbt-demo-hpp`, provisioner `kubevirt.io.hostpath-provisioner`, pool `cbt-demo-pool`, DaemonSet `hostpath-provisioner-csi` (ns `openshift-cnv`), image `…/hostpath-csi-driver-rhel9@sha256:72cdfd4ab6621148bf2a70485394d335d9ccc5045ab0aa82018e72472444bf6b`, `VERSION=v4.22`, data dir `/var/hpvolumes/csi` — installed on this cluster, **not exercised by this scenario** (every CBT-F-04 volume is ODF/Ceph RBD; stated so triage does not chase a hostpath hypothesis) | `oc get sc`, `oc get ds hostpath-provisioner-csi -n openshift-cnv` | `cluster 2026-10-16` |
| Storage (**present but NOT exercised**) | local-storage-operator | `local-storage-operator.v4.22.0-202609291750` — installed, not exercised | `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release | RHEL 9 (all three run labels; r02's draft records "guest RHEL 9") | run reports/analyses | r02/r03/r04 |
| Guest | kernel | `not recorded` for these runs (no in-guest `uname -r` capture); the guest kernel `5.14.0-687.5.1.el9_8.x86_64` in the cluster notes was measured on a later, different guest | `uname -r` in the guest (not run) | `not recorded` |
| Guest | guest agent package version | `not recorded` for these runs | `rpm -q qemu-guest-agent` (not run) | `not recorded` |
| Guest | vCPU / memory | `not recorded` — not captured | VM spec vs `nproc` / `free` (not run) | `not recorded` |
| Guest | workload used (context) | r02: a 1,000-file deterministic workload with a same-VM incremental pass (r02's incremental carried 1,000 files / ~18.28 GiB payload); r04: 8 files / 8 GiB baseline plus deliberate churn | run analyses/reports | r02/r04 |
| Harness (internal only) | workflow + trigger checksum | `virt-cbt-lab`; per-run trigger sha256 from each run's own pack: r02 `not recorded` (its preflight carries no checksum), r03 `a214796df0d0395833f23d9de07ef9d5a7888d5d1fcbef7bb4779926488d837b`, r04 `92f7bf6a3dcb21b570008e7f9a79b41d1afad074497ef819916ea3116e8417` (r04's preflight also records the krknctl injection shape) | `runs/<label>/preflight.json` | r03/r04 (checksums), r02 (`not recorded`) |

**Load-bearing rows.** The **virt-handler image digest is `not recorded`** for these runs, and that is
the component that emits the event — anyone re-testing must capture it first, because the event's
wording and the retry behaviour live in that binary. The CNV/virt-controller version (4.22.12) is the
only version the runs themselves pinned.

## Reproducibility

- **Classification**: `single observation` — carried exactly as the draft states it ("single
  reproduction — do not file as confirmed defect"): one run label, `20261015-cbtf04-r02`, 2026-10-15.
  A second reproducing run label is what the draft requires before Bug classification.
- **Attempts** (all on 2026-10-15, one cluster/build; observed by the runs' read-only watchers, not by
  the reporter's exit status):
  - `20261015-cbtf04-r02` — the drafted observation, and it fired **twice inside that run**: the chaos
    full pass at 06:49:55Z and the **no-chaos** incremental pass at 07:12:34Z (`runs/20261015-cbtf04-r02/observer/watches/events-20261015-cbtf04-r02.jsonl`). The draft does not count those two passes
    as independent reproductions (same run, same cluster, same version).
  - `20261015-cbtf04-r03` — the same pattern on this run's VM at 09:15:14Z (count 1→2 within the
    second, during teardown of the full backup's target volume) **and** on an unrelated same-cluster VM
    (`vm-20261015091633-silent-wolf-4eb4`) at 09:19:39Z and 09:21:51Z, on full and incremental passes
    (`analysis/20261015-cbtf04-r03-product-flow.md` §5).
  - `20261015-cbtf04-r04` — fired on **both** successful detach paths: full teardown 15:56:43Z
    (count 1→2) and incremental teardown 16:29:43Z (count 1→2), each followed within the same second
    by successful unmount + attachment-pod deletion (`analysis/20261015-cbtf04-r04-product-flow.md`
    §3.3).
  - The r03 and r04 analyses each state that this reaches the two-run-label bar and is eligible for
    `bugs/` — recorded here for triage visibility, **not** folded into the classification field above,
    which stays as the draft wrote it.
- **Stability — exact every time**: the reason code `HotplugFailed`, the message shape
  (`failed to mount filesystem hotplug volume <backup-target-pvc>: lstat … disk.img: no such file or directory`),
  the count doubling 1→2 within a second, and the fact that it is followed in the same second by
  successful delete/unmount records. **Varies**: which pass (full vs incremental) and which VM — the
  pattern appears on every successful detach observed, including passes under no chaos at all.
- **Preconditions**: a successful backup-target hotplug volume whose detach is executed on this
  version/storage combination (ODF/Ceph RBD, filesystem-mode hotplug). No disruption is required; the
  pattern was observed with no chaos active.
- **Second entry path**: not applicable in the sense of an alternative fault path — this is not a fault
  at all in the observed passes. What *is* worth noting is the opposite: the same reason code is the
  one a real hotplug failure would use, which is the triage question below.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261015-cbtf04-r02`** (namespace `vm-cbt-demo`), so
> each command can be compared with this ticket's evidence. For a fresh reproduction pick your own
> run-scoped names. Every command is scoped to one named object. Repository helper for this scenario
> (optional accelerator, never required): `cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh`. **There is
> no injection required** for this ticket: run a backup, watch the events at its end.

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine | `vm-20261015-cbtf04-r02` | `not recorded` | 2026-10-15 ~06:4xZ | kept |
| VirtualMachineInstance | `vm-20261015-cbtf04-r02` | 9f3d823f-c3e2-4071-b1cd-0e438d0b9377 | ~06:4xZ | kept; Running on `<node>`, CBT `Enabled` throughout |
| Pod (launcher, **the VMI the event lands on**) | `virt-launcher-vm-20261015-cbtf04-r02-jl5lt` | `not recorded` | ~06:4xZ | kept; 0 restarts, never Failed |
| Pod (scenario injection target, only for the optional full-shape step) | `virt-controller-6f7bc6b44c-5h4hs` (Lease holder at arm) | `not recorded` | `not recorded` | **deleted by the scenario** 06:49:07.697Z; replacement `virt-controller-6f7bc6b44c-mrspr` Ready; new Lease holder `kgtth` 06:49:24Z |
| VirtualMachineBackupTracker | name `not recorded` — the run's tracker watch stream is `observer/watches/tracker-20261015-cbtf04-r02.jsonl`; it advanced exactly once per pass | — | — | kept |
| VirtualMachineBackup (full) | `vm-backup-20261015-cbtf04-r02` | eb1e4bb2-cef5-4de6-b404-d0c5eb85ec69 | ~06:48:48Z | kept; `Done=True` `Successfully completed VirtualMachineBackup` 06:49:5xZ |
| Checkpoint (full) | `vm-backup-20261015-cbtf04-r02-2026-10-15_06-48-48` | — (libvirt checkpoint) | 06:48:48Z | kept |
| PVC (full destination) | `vm-backup-pvc-20261015-cbtf04-r02` (80 GiB) | `not recorded` | ~06:48:48Z | kept, `Bound` |
| Pod (attachment, full — the pod whose teardown carries the event) | `hp-volume-bn45q` | `not recorded` | ~06:48:50Z | deleted at detach (recorded `SuccessfulDelete` in the same second as the event) |
| VirtualMachineBackup (incremental) | `vm-incremental-20261015-cbtf04-r02-p01` | `not recorded` | ~07:12:14Z | kept; `Done=True`, distinct child checkpoint; **emitted the same event with no chaos active** |
| PVC (incremental destination) | `vm-incremental-pvc-20261015-cbtf04-r02-p01` (30 GiB) | `not recorded` | ~07:12:14Z | kept, `Bound` |
| Pod (attachment, incremental) | `hp-volume-fc4cn` | `not recorded` | ~07:12:14Z | deleted at detach |
| Hotplug volume names in the event message | `vm-backup-20261015-cbtf04-r02-backup-target-pvc`, `vm-incremental-20261015-cbtf04-r02-p01-backup-target-pvc` | — | — | deleted at detach (successfully) |

### Steps

**Step 1 — Setup: CBT-enabled VM with a workload large enough to copy, and a destination PVC.** When: before any backup.
```bash
oc get vmi vm-20261015-cbtf04-r02 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.nodeName}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get pvc vm-backup-pvc-20261015-cbtf04-r02 -n vm-cbt-demo -o jsonpath='{.status.phase}{"\n"}'
```
What you must see: VMI `Running`, `changedBlockTracking.state` = `Enabled`, PVC `Bound`.

**Step 2 — Start the full backup: copy its launcher pod name, which is where you will read the events later.**
When: before the (optional) injection.
```bash
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-20261015-cbtf04-r02
  namespace: vm-cbt-demo
spec:
  pvcName: vm-backup-pvc-20261015-cbtf04-r02
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261015-cbtf04-r02
YAML
# the copy-start signal (recorded 06:48:50.467875Z); substitute your launcher pod name
oc logs virt-launcher-vm-20261015-cbtf04-r02-jl5lt -n vm-cbt-demo -c compute | grep -F 'Backup started'
# start capturing events before the detach happens — the defect is a single-second burst
oc get events -n vm-cbt-demo --watch --output-watch-events > /tmp/r02-events.jsonl &
```
What you must see: `Backup started` for this exact backup name, and your event capture running.

**Step 3 — (Optional injection: not required for this defect)** Delete the controller pod holding the leader
lease while the copy is progressing. When: inside the copy window (recorded: 19 s into it).
```bash
oc get lease -n openshift-cnv -o jsonpath='{.items[*].spec.holderIdentity}{"\n"}'   # the current leader
# fail closed unless exactly one holder is returned; then, with the pod name that corresponds to it:
oc delete pod virt-controller-6f7bc6b44c-mrspr -n openshift-cnv --wait=false
```
What you must see (recorded): a new leader elected ~17 s later, the launcher never restarting, and the
copy finishing normally. **Skip this step and the event still fires** — that is the finding.

**Step 4 — Let the backup finish and read the events at the detach.** When: immediately after terminal.
```bash
oc get vmbackup vm-backup-20261015-cbtf04-r02 -n vm-cbt-demo \
  -o jsonpath='{.status.type}{" "}{.status.conditions[?(@.type=="Done")].status}{" "}{.status.conditions[?(@.type=="Done")].reason}{"\n"}'
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp | tail -20
```
What you must see: type `Full`, `True Successfully completed VirtualMachineBackup` — **and, in the same
second as the completion**, `HotplugFailed` on the VMI with the message
`failed to mount filesystem hotplug volume vm-backup-20261015-cbtf04-r02-backup-target-pvc: lstat …/disk.img: no such file or directory`,
source `virt-handler` on the VM's node, count 1 doubling to 2 within that second. In the same second you
should also see `Killing` on the attachment pod (`hp-volume-*`, "Stopping container hotplug-disk"),
`SuccessfulDelete` for the attachment pod and the hotplug volume, and `VolumeUnMountedFromPod`.

**Step 5 — Read-only demonstration that the pass is nevertheless correct (this is the ticket's whole point).**
```bash
oc get pvc vm-backup-pvc-20261015-cbtf04-r02 -n vm-cbt-demo -o jsonpath='{.status.phase}{"\n"}'
oc get pods -n vm-cbt-demo -o wide | grep hp-volume        # expect no leftover attachment pod
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r02 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'      # advanced exactly once
oc get vmbackup -n vm-cbt-demo -o custom-columns=NAME:.metadata.name,REASON:.status.conditions[?(@.type=="Done")].reason
```
What you must see: PVC `Bound`, no leftover `hp-volume-*` pod, the tracker advanced exactly once, and
**warning-free** backups. Wait a few minutes and re-read: the event does not repeat for the same
detach — it is instantaneous, not a stuck condition. (Nothing needs to be declared "stuck" here.)

**Step 6 — Recovery: nothing to recover.** When: never, for this defect.
```bash
# Do NOT delete volumes, and do NOT restart handlers in response to these events.
# If you want the repeat observation: run the incremental pass on the same VM and watch the events again.
```
What you must see (recorded): the **incremental** pass — no chaos active — emits the identical pattern
(`hp-volume-fc4cn`, `vm-incremental-20261015-cbtf04-r02-p01-backup-target-pvc`, 07:12:34Z, count 1→2)
with the same clean outcome. That is the control that makes this ticket an observability issue rather
than a cleanup bug.

## Current behaviour (observed)

Event sequence from `runs/20261015-cbtf04-r02/observer/watches/events-20261015-cbtf04-r02.jsonl` —
full pass, all events timestamped **06:49:55Z** (second granularity; stream order within the second as
recorded):

1. `VirtualMachineBackupCompletedSuccessfully` on `vm-backup-20261015-cbtf04-r02` (the backup is
   already terminal-successful).
2. `Killing` on pod `hp-volume-bn45q` — "Stopping container hotplug-disk" (attachment pod teardown
   begins).
3. `HotplugFailed` on VMI `vm-20261015-cbtf04-r02`, source `virt-handler` on node `<node>`, ADDED
   count=1, message verbatim (abbreviated at the CSI handle):
   `failed to mount filesystem hotplug volume vm-backup-20261015-cbtf04-r02-backup-target-pvc: lstat /proc/1/root/var/lib/kubelet/plugins/kubernetes.io/csi/openshift-storage.rbd.csi.ceph.com/f1994c9a…/globalmount/0001-0011-…-41afed24…/disk.img: no such file or directory`
4. The same event MODIFIED to count=2 within the same second.
5. `SuccessfulDelete` (VMI) — attachment pod deleted; `SuccessfulDelete` — hotplug volume deleted.
6. `VolumeUnMountedFromPod` — backup-target volume unmounted from the launcher.

**Incremental pass** (07:12:34Z, **no chaos active**): byte-for-byte the same pattern against
`hp-volume-fc4cn` / `vm-incremental-20261015-cbtf04-r02-p01-backup-target-pvc` (CSI handle
`a9658af1…`, volume-id `967e60aa…`), including the identical count 1→2 doubling.

**What succeeded despite the events.** Both passes ended fully correct: `Done=True` with reason
`Successfully completed VirtualMachineBackup`; attachment pods deleted; hotplug volumes deleted and
unmounted; destination PVCs `Bound`; tracker advanced exactly once per pass; checkpoint chain
full → child verified in libvirt; both restore points hash-verified with zero failures. The anomaly is
therefore **not** a functional failure of backup, cleanup, chain, or restore — it is a
failure-signature event emitted on an otherwise fully successful path. (All of the above: independent
artifact observations from the run's event/backup/tracker watch streams.)

**Key observations sharpening the question.**

- The identical pattern fired in the incremental pass, which ran under **no chaos** (23 min after the
  controller kill, on a settled cluster) — the anomaly is therefore **not attributable to the
  controller disruption**; it is ordinary detach-path behaviour in this setup (OpenShift
  Virtualization 4.22.12, ODF/Ceph RBD CSI, filesystem-mode hotplug).
- The event message says "failed to **mount** filesystem hotplug volume" while the lifecycle phase is
  **unmount/detach** (the attachment pod's container is stopping). A mount attempt (or mount-path
  validation) against a CSI `globalmount` path that is already being torn down (`disk.img` gone)
  suggests a stale reconcile or a teardown-path check that re-reads the source path — **[INFERENCE]**
  the mechanism is unestablished (hypotheses in Additional feedback).
- The event doubled (count 1→2) within one second, consistent with a retry loop that then gave up
  silently because the volume was already removed. **[INFERENCE]**
- **Remaining question (the draft's, preserved):** is this (a) benign event noise from a
  racy-but-harmless validation/retry path, or (b) a real cleanup race in the hotplug detach logic that
  happens to be masked by the volume's eventual deletion? Either way it degrades failure semantics:
  consumers alerting on `HotplugFailed` will fire on every successful backup of this shape — a "loud
  failure event on a correct path" monitoring hazard, even if functionally benign.

## Expected behaviour (contract)

A successful backup whose hotplug detach completes cleanly should not emit a failure-reasoned event on
the VMI, or the event semantics should be clarified (what `HotplugFailed` with a mount message during
detach obligates consumers to do).

**Acceptance check.** After the fix/clarification, the detach of a successfully-completed backup's
target volume emits no `HotplugFailed` event (or a documented, distinguishable informational signal),
with cleanup still completing (attachment pod gone, volume unmounted, PVC `Bound`).

**Acceptance criteria (from the reporter draft, preserved):**

- Post-backup detach of the backup-target hotplug volume on a successful backup emits no
  `HotplugFailed` (or the reason/message accurately reflects the phase and is documented as
  non-actionable).
- Cleanup invariants hold after the change: attachment pod deleted, volume unmounted, destination PVC
  `Bound`, tracker advanced exactly once.
- Regression check: full + incremental backup-then-detach cycle on ODF/Ceph RBD with filesystem-mode
  hotplug, asserting the namespace event stream contains no failure-reasoned hotplug events on
  successful passes.

## Impact, workaround and data safety

- **Functions lost / how an operator notices.** Nothing is lost functionally: both passes completed
  `Done=True` with success reasons, cleanup finished, the tracker advanced exactly once per backup, and
  both restore points hash-verified. What the operator notices is the inverse problem — a failure page
  for a successful backup, and (worse) an inability to tell a genuine hotplug failure from this noise
  because both use the same reason code.
- **Blast radius.** The affected VMI's event stream per successful detach; any cluster-wide alert rule
  keyed on the reason code inherits the false positives for every VM with CBT backups of this shape.
  No object state is left wrong, so the blast radius is monitoring/automation rather than the data
  path.
- **Data safety.** **Not at risk** — no data path, cleanup step, or restore was affected in any
  observed pass; this ticket claims nothing about data.
- **Workaround / operator runbook.** No customer mitigation was identified from this run (nothing
  needed fixing). The practical mitigation, if an operator must alert on this reason code, is to scope
  the rule to terminal backup failures instead of `HotplugFailed` events — a workaround for the
  *noise*, not a fix. Nothing was live-verified as a fix; no product-side suppression was attempted.
- **Frequency.** Every successful backup-target detach observed on this setup (both passes of the
  drafted run, plus later run labels), including no-chaos passes — i.e. for CBT backups of this shape
  it is not rare but routine.
- **Unknowns this ticket deliberately does not claim.** The mechanism (stale reconcile vs
  teardown re-check vs an intentional retry); whether a real hotplug failure ever occurs on this path
  (none was observed); whether the volume deletion is what makes the failed attempt moot (unproven);
  the virt-handler code revision (image digest `not recorded`).

## Evidence

**Artifact index.** Paths are as the drafts/analyses record them, relative to
`cbt-chaos/scenarios_v2/CBT-F-04/`. The run packs' full roots are sha-pinned in each run's
`evidence-index.json` (r02: 47 files; r03: 68; r04: 64 — `generated_utc` 2026-10-15T07:34:34Z /
12:15:37Z / 17:49:49Z); this checkout carries the pack metadata and reports, with the raw
`observer/`/`recovery/` captures in the run root.

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `runs/20261015-cbtf04-r02/observer/watches/events-20261015-cbtf04-r02.jsonl` | the `HotplugFailed` ADDED/MODIFIED pair (count 1→2) with the full `lstat … disk.img` message at 06:49:55Z and 07:12:34Z, source `virt-handler`/`<node>` | 06:49:55Z, 07:12:34Z | raw |
| `runs/20261015-cbtf04-r02/observer/finding.md` | observer finding: contradiction #2, criterion 5 "anomaly: HotplugFailed x2" | run window | raw (observer) |
| `runs/20261015-cbtf04-r02/reports/test-run-report.md`, `test-run-result.md` | run findings section; the run's own recording of the anomaly and of the fully correct outcomes | run window | derived |
| `runs/20261015-cbtf04-r02/observer/watches/*.jsonl` (tracker, pods, lease, vmbackup, pvc) + `observer/evidence-terminal/*` | the positive controls for this ticket: backup terminal `Done=True` success, tracker advanced once, attachment pod deleted, hotplug volume unmounted, PVC `Bound` | run window | raw |
| `analysis/20261015-cbtf04-r02-product-flow.md` §2–§3 | the analysis that classified the anomaly (contradiction vs functional failure) and carries the original draft (now this file's source) | 2026-10-15 | derived (analysis) |
| `analysis/20261015-cbtf04-r03-product-flow.md` §5 | the repeated observation: same pattern at 09:15:14Z on the r03 VM and on an unrelated VM (`vm-20261015091633-silent-wolf-4eb4`, 09:19:39Z / 09:21:51Z) | 2026-10-15 | derived (analysis) |
| `analysis/20261015-cbtf04-r04-product-flow.md` §3.3 | the repeated observation: both detach paths in r04, 15:56:43Z and 16:29:43Z, count 1→2, cleanup completing in the same second | 2026-10-15 | derived (analysis) |
| `runs/20261015-cbtf04-r04/preflight.json`, `runs/20261015-cbtf04-r03/preflight.json` | per-run GO decisions and trigger sha256 (`92f7bf6a…` r04, `a214796d…` r03) — the pack-level provenance for the repeated observations | 15:43:35Z, 09:04:06Z | raw |

**Draft-cited artifacts and command forms, preserved verbatim from the reporter draft** (so this
ticket's evidence index still matches the original record): `runs/20261015-cbtf04-r02/observer/watches/events-20261015-cbtf04-r02.jsonl`
(the event watch), `runs/20261015-cbtf04-r02/observer/finding.md` (contradiction #2, criterion 5
"anomaly: HotplugFailed x2"), `runs/20261015-cbtf04-r02/reports/test-run-report.md` and
`test-run-result.md`; the incremental's attachment details as written there — `hp-volume-fc4cn`,
`vm-incremental-20261015-cbtf04-r02-p01-backup-target-pvc`, CSI handle
`a9658af1b692c6eafd6379b72085a0dfbd1326c746a4e051f4e4263cab760b0a`, volume-id
`…-967e60aa-a654-4dab-b8c0-29a7848fa9ea`; and the draft's read-only inspection forms
`oc get events -n <namespace> --sort-by=.lastTimestamp` and
`oc get virtualmachinebackup <backup> -n <namespace> -o jsonpath='{.status.conditions}'`. This ticket's
steps use the same commands with the run's concrete names substituted.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery):

| # | Time (UTC), 2026-10-15 | Event | Source |
|---|---|---|---|
| 1 | 06:48:48–06:48:50.467875Z | Setup/precondition: full backup object created, copy begins (`Backup started`) | r02 analysis §1 row 1 |
| 2 | 06:49:07.697Z | (Scenario injection, not a prerequisite here) controller leader `virt-controller-6f7bc6b44c-5h4hs` deleted; failover complete at 06:49:24Z | r02 analysis §1 row 2 |
| 3 | 06:49:5xZ | Backup copy completes; backup settles terminal `Done=True` (`Successfully completed VirtualMachineBackup`) 17 s after the kill | r02 analysis §1 rows 1–3 |
| 4 | 06:49:55Z | **Effect**: `VirtualMachineBackupCompletedSuccessfully`, then `Killing` of `hp-volume-bn45q`, then `HotplugFailed` (count 1→2) with the `lstat … disk.img` message, then `SuccessfulDelete` ×2 and `VolumeUnMountedFromPod` | `observer/watches/events-20261015-cbtf04-r02.jsonl` |
| 5 | 07:12:34Z | **Same effect on a no-chaos pass**: incremental detach reproduces it byte-for-byte (`hp-volume-fc4cn`), chaos ruled out as the cause | same artifact; r02 analysis §2 |
| 6 | 07:20:28Z (final snapshot) | **No failure to report**: tracker advanced once per pass, checkpoint chain verified, restore points hash-verified (0 failures), PVCs `Bound` | r02 analysis §1 rows 3–8 |
| 7 | 09:15:14Z / 15:56:43Z / 16:29:43Z | Repeats on later run labels (r03, incl. an unrelated VM; r04 full and incremental) | r03 §5, r04 §3.3 |
| 8 | — | **Recovery**: not applicable — no functional failure occurred; nothing was cleaned up or worked around for this observation | r02 analysis §5 (customer recommendation: none) |

**Retained state.** The runs' objects were preserved as evidence: the backup CRs (both `Done=True`
with success reasons), the trackers (advanced exactly once per pass), the destination PVCs `Bound`, and
the raw watch streams (sha-pinned in each run's `evidence-index.json`). Nothing was deleted to
investigate this ticket, and no workaround was applied, because no functional failure occurred. The
live cluster objects still existed at each run's final snapshot (r02 final snapshot 07:20:28Z); whether
the demonstration VMs were later torn down by the campaign is outside this ticket's evidence.

## Negative results and what would falsify this ticket

- **Refuted (ruled out by experiment): causation by the controller disruption.** The identical pattern
  fired on the **no-chaos** incremental pass 23 minutes after failover, on a settled control plane
  (r02) — the disruption cannot be the trigger. Later labels repeat it on passes with no chaos at all.
- **Refuted: "the cleanup failed."** In every observed pass the cleanup completed in the same second as
  the event: attachment pod deleted, hotplug volume deleted, `VolumeUnMountedFromPod`, destination PVC
  `Bound` (r02 `observer/watches/*`, `pvc-list-run.txt`).
- **Refuted: "the backup or chain suffered for it."** `Done=True` with the success reason, tracker
  advanced exactly once per pass, checkpoint chain full → child verified, both restore points
  hash-verified with zero failures.
- **Refuted: "it is specific to one guest or one pass type."** Observed on full and incremental passes,
  and (in later labels) on another VM in the same namespace with the same result.
- **Limits of this evidence (stated, not refuted).** One run label for the drafted observation;
  second-granularity event timestamps (sub-second ordering within the detach burst is not established);
  the count doubling comes from one event object's watch updates; the OpenShift cluster version was not
  recorded in r02/r03; no `qemu-img` allocation map exists in r02, so data correctness there rests on
  guest-level file/byte/manifest-hash checks; the mechanism inside virt-handler is unproven and its
  image digest is `not recorded`.
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. `HotplugFailed` on a *successful* detach is the intended, documented signal for a benign retry —
     then the ticket reduces to a documentation/message-correctness request (still worth filing, but
     not a defect).
  2. A real hotplug failure on this path is shown to use a **different, distinguishable** reason code —
     that would remove the alerting hazard and the main impact claimed here.
  3. A future run shows a **wedged** attachment correlated with the event (no unmount, attachment pod
     stuck, PVC unusable) — that would escalate this from observability noise to a real cleanup race
     (the draft's option (b)) and change the issue type to Bug.
  4. The event is shown to be emitted by something other than the hotplug detach path (e.g. a status
     reconciler reading stale VMI state), which would move the fix site.

## Additional feedback (reporter's notes)

- **Preserved hypotheses (labelled — not established mechanisms).**
  - **HYPOTHESIS (teardown re-check race):** virt-handler's filesystem-hotplug logic re-validates the
    mount source path during volume removal; by then the CSI node-stage globalmount path
    (`…/globalmount/<volume-id>/disk.img`) is already deleted, so the `lstat` fails and is reported
    through the generic `HotplugFailed` reason. Consistent with the message appearing during detach and
    with the count doubling (one retry, then the volume is gone).
  - **HYPOTHESIS (stale reconcile):** the VMI status still references the hotplug volume while the
    attachment pod is being deleted; a virt-handler reconcile loop attempts a (re)mount from stale
    state and fails on the vanished path, emitting the event before the final successful
    delete/unmount records.
  - **HYPOTHESIS (observability-only impact):** the event is purely noisy and has no functional
    consequence on this version/storage combination; the mask is the eventual volume deletion making
    the failed retry moot. Would be **supported** if further runs reproduce the event pattern with the
    same clean outcomes (r03 and r04 did); **contradicted** if any run shows a wedged attachment
    correlated with the event.
  - **NON-hypothesis (ruled out):** causation by the controller kill — see Negative results.
- **Preserved triage questions.** (a) Is the `HotplugFailed` event emitted by a mount-path
  validation/retry that races the CSI globalmount teardown, or by a stale VMI-status reconcile after
  the volume is already removed? (This determines Bug vs Improvement and the fix site.) (b) Is the
  "failed to mount" message during a detach phase a wrong-message bug independent of whether the event
  should fire at all? (c) Do real hotplug failures on this path use the same reason code, making the
  signal indistinguishable for alerting consumers?
- **Smallest experiments that would settle the open points.** (1) Induce a genuine hotplug failure on
  the same path and compare the emitted reason/message with this one — settles (c) and the alerting
  hazard. (2) Capture the virt-handler image digest and the handler's log around a successful detach
  with debug verbosity, to see whether the `lstat` comes from a mount attempt or a validation read —
  settles (a) and (b). (3) Re-run the detach while blocking the CSI teardown (e.g. holding the mount)
  to see whether the event then correlates with a *real* wedge — settles the hypothesis split in
  Negative results.
- **Cross-references.**
  - Same folder: `failed-backup-terminates-done-true-with-failure-reason.md` — the complementary
    failure-semantics question (a *real* failure recorded as `Done=True`), from the same run labels;
    the two together are the reason consumers cannot parse this product's backup outcome reliably.
  - Same folder: `cbt-incremental-copy-size-is-peak-dirty-volume.md` — the separate sizing contract gap
    (its evidence also comes from these runs; no interdependency).
  - Source analyses (unchanged apart from the pointer at their head):
    `analysis/20261015-cbtf04-r02-product-flow.md` §2–§3 (this draft's origin),
    `analysis/20261015-cbtf04-r03-product-flow.md` §5,
    `analysis/20261015-cbtf04-r04-product-flow.md` §3.3.
  - **Separately and clearly labelled — harness/tooling, not this ticket:** the r02 run's trigger
    aborted once on a trigger env-leak and `run.json` had to be repaired (a harness-lane issue that
    bounded evidence confidence; it is why `recovery/summary.json` records the full backup's status as
    PENDING while the live object was `Done=True`). No harness ticket is filed by this ticket.
- **Environment-specific notes for the next reproducer.** (a) Read the event stream of the *VMI*, not
  of the backup CR: the event lands on the VMI with `source: virt-handler`. (b) Event timestamps are
  second-granularity — the detach burst's internal ordering must come from the stream order, not
  timestamps. (c) Capture the virt-handler image digest before/after; it is `not recorded` for every
  run behind this ticket. (d) Do not "fix" anything in response to these events: treat them as
  observations until triage decides the contract.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted.
- [x] No private hostnames or absolute host paths — cluster node names are genericised as `<node>`;
      the only path-like strings are inside verbatim product messages
      (`lstat /proc/1/root/var/lib/kubelet/plugins/kubernetes.io/csi/…`) and container-internal CSI
      handle paths, abbreviated with `…`.
- [x] No broad selectors (names or run-scoped labels only) — every command is scoped by the run's exact
      VMI/backup/PVC names or by the single Lease-holder pod at the moment of the kill.
- [x] No destructive commands other than the documented, scoped workaround — there is no recovery
      command in this ticket (nothing needs fixing); the only delete mentioned is the scenario's own
      scoped `virt-controller` Lease-holder kill in the optional injection, labelled as not required.
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the draft labels its
      steps illustrative; the injection shape and windows are the recorded ones, and the observation
      commands are the read-only ones the runs used.
