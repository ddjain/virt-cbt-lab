# CBT-F-05 — Leaked hotplug attachment after virt-handler restart during CBT backup unplug

## What this is, in one paragraph

Deleting the node agent that plugs a backup disk into a running VM (the `virt-handler` pod on the VM's
node) while a backup is copying leaves that backup volume attached to the node permanently. The backup
finishes and reports success, but the disk is never unmapped, so nothing on any other node can read it:
a restore or verification pod sits in `Pending` with a "Multi-Attach" error, and the only cure found is
an operator deleting the leftover attachment record and restarting the agent pod by hand. This file is
the long-form evidence narrative for the third run behind that bug — it identifies which process was
holding the disk, shows the Ceph-side lock that never cleared, and records the recovery sequence that
was verified live.

**When → then → expected**

- **When** the product is taking a full changed-block-tracking backup of a running VM — CBT: the
  backup mode driven by per-disk change tracking — and the destination volume is **hotplugged** into
  the VM for the copy (the destination disk is attached to the running node and handed to the guest's
  QEMU while the VM keeps running), then unplugged when the copy ends.
- **And** the disruption `CBT-F-05` (a CBT chaos scenario; its spec names the krkn primitive
  `pod-scenarios`, but the recorded runs executed a direct `oc delete` of the resolved pod — a
  pre-scoped chaos tool cannot name a pod that only exists after setup, which the run report states)
  is applied: **delete the single Ready `virt-handler` pod on the VM's node inside the copy→unplug
  window.** Run `20261012-cbtf05-r01`: copy signal 19:20:21.821Z, pod `virt-handler-655mx`
  (UID 184db2c1-8107-4cbe-b27f-f78e5a056960) deleted during the 68-second copy, backup terminal
  19:21:27Z, unplug attempted 19:21:27.355Z. **The window opens at the copy-start signal and closes at
  the unplug attempt.**
- **Then (current behaviour):** the replacement agent hits "device or resource busy" removing the
  hotplug directory, marks the volume unmounted anyway, and stops; the disk stays mapped inside its own
  hotplug path, the attachment record is never deleted, and the volume stays pinned to that node. A
  reader pod on another node is `Pending` with `Multi-Attach error` for ~53 minutes, and the workflow's
  restore verification fails.
- **Expected behaviour:** the replacement agent retries (or the controller reconciles) the unplug until
  the device is unmapped and the attachment record is removed, so a reader pod on any other node can
  attach the backup volume with no manual intervention.

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
> **Companion ticket.** The behaviour in this file is the same behaviour family as
> `bug-backup-volume-attachment-leak.md` in this folder, which carries the two 2026-10-11 run labels
> (RHEL 9 + Windows Server 2022). This file is the longer evidence narrative for the third run label
> (2026-10-12): it is the only one with the **holder identification** (which process kept the device
> mounted), the **RBD-side evidence** (exclusive-lock watcher, `rbd unmap` EBUSY loop), and a
> **live-verified recovery procedure**. The two files are deliberately not merged: one is the filed
> defect with independent reproductions, the other is the mechanism/runbook narrative.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Bug** — established contract violated: after the backup reached terminal success, the backup destination volume's hotplug unplug and CSI detach never completed, so the volume could not be attached by any other node without operator intervention. |
| Priority (proposed) | **High** — backup volume unusable for restore until manual intervention; silent (every backup object reports success). |
| Severity class | resource leak (leaked storage attachment / never-unmapped block device), with an availability consequence for readers and an observability gap: the defect is invisible in the backup objects' status. |
| Owning component (suspected) | **suspected** virt-handler hotplug unplug retry semantics (`vm.go:1493` `failed to remove hotplug disk directory` and `vm.go:500` `Marking volume … as unmounted`), plus the CSI `NodeUnstageVolume` path when the staging path is still held by the restarting consumer. |
| Component(s) proven involved | virt-handler on the VM's node (it logged the EBUSY, then marked the volume unmounted and stopped retrying; the **replacement** handler pod's process was later found holding the mapped device), the Ceph RBD CSI node plugin (`rbd unmap` retrying and failing EBUSY; exclusive-lock watcher persisting), and the external-attacher/attach-detach path (the `VolumeAttachment` object survives with its finalizer and no `deletionTimestamp`, so the reader can never attach). |
| Reproducibility | `single observation` — one run label, one injection (run `20261012-cbtf05-r01`, 2026-10-12). The same behaviour family was independently reproduced on two further run labels on 2026-10-11 (the companion ticket's runs, RHEL 9 + Windows guests: 3 run labels / 3 in the family). This ticket does not count those as its own attempts. |
| Status / confidence | **Confirmed behaviour on this run label** (artifacts below), with the *mechanism sequence* the run report states (unplug raced with the handler replacement) recorded as that report's claim. Which retry/terminal-state logic actually drops the detach is **unproven**; the CSI-side and handler-side observations are independent of each other. |
| Blast radius | the one backup PVC/volume, and through it any reader scheduled on another node. Other nodes' handlers and other backups were not affected (the `oc delete` was scoped to the single pod on the VM's node, and only this volume leaked). |
| Data at risk? | **No** — data loss: none. Both the full and the incremental restores matched their manifests (17/17 checks) once the leak was cleared; the loss is availability of the volume for readers, plus the operator time to clear it. |
| Related scenario / execution | CBT-F-05 (restart the node virtualization backup handler during a full CBT copy), run `20261012-cbtf05-r01`, 2026-10-12 UTC. Companion ticket runs (same family, earlier day): `20261011064508-fuzzy-wolf-6cb9` (RHEL 9) and `20261011-win-f05-r01` (Windows), both 2026-10-11 UTC. |
| Affected versions | OpenShift 4.22.15; OpenShift Virtualization 4.22.12; backup destination on Ceph RBD (`openshift-storage.rbd.csi.ceph.com`), pool `ocs-storagecluster-cephblockpool`; guest RHEL 9. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

**What the feature does.** A CBT full backup writes the VM's disk into a dedicated destination PVC.
To let QEMU write into that PVC while the VM keeps running, KubeVirt **hotplugs** the destination
volume into the VM: the node agent (`virt-handler`) asks the CSI driver to attach the disk to the
node, mounts it inside its own `hotplug-disks` path, and exposes it to the launcher. When the copy
finishes, the same handler must *unplug* it — remove the hotplug disk directory, mark the volume
unmounted so it can be detached, and let the external-attacher/CSI complete the detach by deleting the
`VolumeAttachment`.

**Where the failure sits.** Restarting the `virt-handler` pod during the window between copy
completion and unplug leaves the backup volume permanently attached to the VM's node. The backup PVC
becomes unusable by any other node (restore/verification workloads hang in `Pending` with Multi-Attach
errors) until an operator manually deletes the orphaned `VolumeAttachment` and restarts the
replacement handler pod. Backup data itself remains valid.

**Observed surface vs. origin.** The surface is the restore workload stuck in `Pending` (and the
CSI-node-plugin log loop); the origin is the handler's unplug path on the VM's node; the object that
stays wrong is the `storage.k8s.io/v1` `VolumeAttachment` (plus the RBD image's exclusive-lock
watcher). The backup CR reports success throughout — it never mentions the leaked attachment.

**Why it matters.** The backup cannot be read back from anywhere except the one node that still holds
the device, and nothing in the product's own status says so. Recovery requires two manual actions
(delete the `VolumeAttachment`, restart the handler pod), i.e. an automation that expects a
terminal-successful backup to be immediately usable will silently lose its restore path.

## Environment (measured, not assumed)

The per-ticket table below reflects **this** run's storage: the **ODF/Ceph RBD destination volume is
the defect's subject** (in use), and the HostPathProvisioner pool is listed separately because this
run's report records it provisioning the VM's **root disk** — it is not the defect path. Rows are
provenance-tagged: `run` = captured by this run's own artifacts; `cluster 2026-10-16` = measured on
the same cluster four days later because this run's pack did not capture the layer; `not recorded`
where nothing captured it. Node names are genericised as `<vm-node>` / `<reader-node>`.

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | 4.22.15 | run report environment table | `run` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` |
| Platform | OpenShift update channel | `not recorded` — not captured by this run | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | `not recorded` |
| Platform | `oc`/`kubectl` plugin versions | `not recorded` — only the `oc` server/client version is known | `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow) | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | kernel | 5.14.0-687.48.1.el9_8.x86_64 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | container runtime | cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / node in scope | one worker `<vm-node>` ran the CBT VM and the single handler pod that was deleted; the reader pod was scheduled to a different worker `<reader-node>`; an unrelated cluster daemon-set run showed 28 virt-handler pods before the injection | run's `handlers.jsonl`, `pods-final.txt`, run report | `run` |
| Virtualization | CNV / HCO CSV | `kubevirt-hyperconverged-operator.v4.22.12` (OpenShift Virtualization 4.22.12) | run report environment table (`oc get csv -A`) | `run` |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` = virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | `cluster 2026-10-16` |
| Virtualization | virt-handler image digest (deleted pod **and** its replacement) | `registry.redhat.io/container-native-virtualization/virt-handler-rhel9@sha256:9b3aa0c6b2786ea3d5bfd25e79546b30563e54e739aef7b21cfa8b4dfc66e83b` | pod specs in the run's `observer/handlers.jsonl` (`virt-handler-655mx`, UID 184db2c1-8107-4cbe-b27f-f78e5a056960, and replacement `virt-handler-pg5dw`, UID d903d69d-03d7-481d-aae7-2eac3831869b) | `run` |
| Virtualization | virt-launcher image digest | `registry.redhat.io/container-native-virtualization/virt-launcher-rhel9@sha256:2131d3d24616971b92d7e986635673b6dc731da3d43cae46540882993d36596f` | run's `observer/launcher.jsonl` (`virt-launcher-vm-20261012-cbtf05-r01-cmj2j`) | `run` |
| Virtualization | virt-controller image digest | `not recorded` — not captured by this run | `oc get deploy virt-controller -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | libvirt 11.10.0, QEMU 10.1.0, QEMU API 11.10.0 | `virsh version` in the launcher's `compute` container | `cluster 2026-10-16` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` | watched backup objects in this run's pack | `run` |
| Storage (**in use** — the defect's subject) | StorageClass + provisioner + pool (backup destination) | Ceph RBD via `openshift-storage.rbd.csi.ceph.com`; RBD pool `ocs-storagecluster-cephblockpool`, image `csi-vol-53263947-89a8-4179-a000-cb25cf25394c`; destination PVC `vm-backup-pvc-20261012-cbtf05-r01` → PV `pvc-111336f6…`; the volume is attached to the node and hotplug-mounted in **Filesystem** mode inside the handler's `hotplug-disks` path (ext4 rw) | run report environment table; `investigation/leaked-va.json` (`spec.attacher`); `investigation/rbd7-holder.txt` | `run` |
| Storage (**in use** — the defect's subject) | CSI driver image + version | `not recorded` — this run captured the driver identity (`openshift-storage.rbd.csi.ceph.com`) but not its image digest | `oc get ds` in the CSI namespace (not run) | `not recorded` |
| Storage (**in use** — the defect's subject) | backing device / free space at the time | `not recorded` for capacity — Ceph free space was not captured; what **was** captured on the RBD side is the exclusive-lock watcher (`100.64.0.14`, CSI node plugin, host-network) persisting until cleanup, and `Watchers: none` after the handler restart | `rbd status` in the CSI node plugin context | `run` (watcher evidence) / `not recorded` (capacity) |
| Storage (**in use**, adjacent) | ODF/OCS operators, Ceph image, health | `4.22.5-rhodf` operators (`odf-operator`, `ocs-operator`, `rook-ceph-operator`, `cephcsi-operator`, `mcg-operator`, `odf-csi-addons-operator`, external-snapshotter); RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`; cluster health `HEALTH_OK` | `oc get csv -n openshift-storage`, `oc get cephcluster -n openshift-storage -o jsonpath=…` | `cluster 2026-10-16` |
| Storage (**present; root disk only — NOT the defect path**) | HostPathProvisioner / hostpath CSI | this run's report records the HostPath provisioner storage class for the **VM root disk**, while the backup destination PVCs are Ceph RBD; on the cluster this is StorageClass `cbt-demo-hpp` (provisioner `kubevirt.io.hostpath-provisioner`, pool `cbt-demo-pool`, DaemonSet `hostpath-provisioner-csi` in ns `openshift-cnv`, image `…/hostpath-csi-driver-rhel9@sha256:72cdfd4ab6621148bf2a70485394d335d9ccc5045ab0aa82018e72472444bf6b`, `VERSION=v4.22`, data dir `/var/hpvolumes/csi` on its own filesystem). **No hostpath row is in the leak's path** — stated so triage does not chase a hostpath hypothesis | run report environment table ("HostPath provisioner storage class for the root disk"); cluster reads as in the `cluster 2026-10-16` column | `run` (which pool the root disk used) / `cluster 2026-10-16` (pool details) |
| Storage (**present but NOT exercised**) | local-storage-operator | `local-storage-operator.v4.22.0-202609291750` — installed on the cluster, not exercised by this run | `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release | RHEL 9 (`VM_OS=rhel9`; "created a RHEL 9 VM") | run `trigger.log`, run report | `run` |
| Guest | kernel | `not recorded` — no `uname -r` capture in this run (the kernel in the cluster rows above belongs to the nodes, not the guest) | `cat /etc/redhat-release`, `uname -r` in the guest (not run) | `not recorded` |
| Guest | guest agent package version | `not recorded` — not captured by this run | `rpm -q qemu-guest-agent` (not run) | `not recorded` |
| Guest | vCPU / memory | `not recorded` — neither the VM spec nor in-guest values were captured | VM spec vs `nproc` / `free` (not run) | `not recorded` |
| Guest | workload used (context, not a version) | 1000 files × 15–20 MiB baseline; incremental 4 new files + 1 modified baseline file (the trigger's 8 × 1 GiB profile was overridden by the host `.env` — recorded by the run as a harness finding) | run report environment table + findings | `run` |
| Harness (internal only) | workflow version / trigger checksum | `virt-cbt-lab` workflow, direct `oc delete` of the dynamically resolved handler pod; the trigger checksum is `not recorded` in this pack (and CBT-EXP-06's checksum must not be reused) | run pack | `not recorded` |

**Load-bearing versions.** The virt-handler digest matters: the unplug logic around `vm.go:1493` /
`vm.go:500` and its retry semantics are handler code, and both the deleted pod and its replacement ran
the same image (so this is not an upgrade-skew artifact). The storage mode matters: the destination is
hotplugged in Filesystem mode, which is why a CSI `globalmount` staging path — and the handler holding
it — is in play at all.

## Reproducibility

- **Classification**: `single observation` — 1 injection on 1 run label (`20261012-cbtf05-r01`,
  2026-10-12). The family total is 3 run labels / 3 (this run plus the companion ticket's two runs on
  2026-10-11, different guest OSes); those two are recorded in the companion ticket, not counted here.
- **Attempts**: 1 injection, by the CBT-F-05 workflow, with an independent read-only monitor
  (authenticated watches on the backup, tracker, VM, launcher pods and all virt-handler pods;
  readiness recorded at 19:17:57Z, DaemonSet 28/28).
- **Stability — exact**: the event/log sequence (EBUSY on the hotplug disk directory, then "Marking
  volume … as unmounted" with **no** detach ever requested), the retained `VolumeAttachment` with its
  finalizer and no `deletionTimestamp`, the RBD watcher persisting, the `rbd unmap` EBUSY loop, and
  the reader's Multi-Attach block. **Varies / unknown**: exact sub-second ordering of the unplug
  attempt vs the backup's terminal transition (both second-granularity), and whether the window can be
  missed entirely (e.g. the injection landing too early or too late).
- **Preconditions**: a full CBT backup whose destination PVC is hotplugged into the running VM, and the
  `virt-handler` pod on the VM's node deleted **between copy completion and the unplug**. In this run
  the deletion landed inside the 68 s copy (signal 19:20:21.821Z, terminal 19:21:27Z), and the unplug
  attempt happened at copy end.
- **Second entry path**: not established for *this* ticket. Note for whoever chases it: the companion
  tickets' two runs reached the same leaked state with the injection inside the copy window as well,
  so both observations are one fault path (handler restart during copy/unplug), not two.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261012-cbtf05-r01`** (namespace `vm-cbt-demo`),
> so each command can be compared with this ticket's evidence. For a fresh reproduction pick your own
> run-scoped names. Every command is scoped to one named object. Repository helper for this scenario
> (optional accelerator, never required): `cbt-chaos/scenarios_v2/CBT-F-05/chaos-trigger.sh`.

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine / VMI | `vm-20261012-cbtf05-r01` | `not recorded` (VMI UID not captured) | 2026-10-12 ~19:18Z | kept; Running/Ready, CBT `Enabled` throughout |
| Pod (launcher) | `virt-launcher-vm-20261012-cbtf05-r01-cmj2j` | d56a4def-3a08-4a13-9bc9-ddfb5bf08e2e (the pod UID in the hotplug path) | ~19:18Z | kept; 0 restarts |
| Pod (disruption target) | `virt-handler-655mx`, ns `openshift-cnv`, node `<vm-node>` | 184db2c1-8107-4cbe-b27f-f78e5a056960 | `not recorded` | **deleted by the scenario** inside the 68 s copy; DaemonSet recreated `virt-handler-pg5dw` (UID d903d69d-03d7-481d-aae7-2eac3831869b) |
| Pod (replacement handler — **the process that held the disk**) | `virt-handler-pg5dw`, ns `openshift-cnv` | d903d69d-03d7-481d-aae7-2eac3831869b | ~19:20Z | restarted by the operator during recovery (~21:20–21:35Z), which released the stale mount |
| VirtualMachineBackupTracker | `vm-tracker-20261012-cbtf05-r01` | 6dd2ebc6-f29c-494b-b15f-0ee8a02ac7a9 | `not recorded` | kept; advanced once per backup |
| VirtualMachineBackup (full) | `vm-backup-20261012-cbtf05-r01` | `not recorded` | 19:20:19Z (VA creation second) | kept; `Done=True` 19:21:27Z, 68 s |
| Checkpoint (full) | `vm-backup-20261012-cbtf05-r01-2026-10-12_19-20-19` | — (libvirt checkpoint) | 19:20:19Z | kept |
| PVC (full destination) | `vm-backup-pvc-20261012-cbtf05-r01` → PV `pvc-111336f6-74e3-447d-999c-c27f53cf38e1` | `not recorded` (PVC UID not captured) | 19:20:19Z | kept, `Bound` — **this is the leaked volume** |
| VolumeAttachment (leaked) | `csi-43bd21aa6b4f7f57d6fcad54cfd247dd77117dabac69d5ed13c01675575762cf` | 64787ddf-e59f-465a-b0b4-7b25c7b058d6 | 19:20:19Z | **deleted by the operator in recovery** (~21:20Z); object retained in the pack as `investigation/leaked-va.json` |
| RBD image (the mapped disk) | `ocs-storagecluster-cephblockpool/csi-vol-53263947-89a8-4179-a000-cb25cf25394c`, device `/dev/rbd7` in the handler | — | 19:20:19Z | unmapped during recovery (`Watchers: none` afterwards) |
| VirtualMachineBackup (incremental) | `vm-incremental-20261012-cbtf05-r01-p01` | `not recorded` | ~19:23:28Z | kept; `Done=True`, 22 s, distinct checkpoint; **clean unplug** (the control) |
| PVC (incremental destination) | `vm-incremental-pvc-20261012-cbtf05-r01-p01` → PV `pvc-…` | `not recorded` | ~19:23:28Z | kept, `Bound` |
| Pod (attachment, full backup) | `hp-volume-j2j5l` | `not recorded` | ~19:20Z | killed at unplug (19:21:27Z) |
| Pod (reader / restore verification) | `vm-restore-verify-20261012-cbtf05-r01` (name per the run report's shorthand; exact name `not recorded`) | `not recorded` | 19:23:57Z onward | first attempt left `Pending` ~53 min (never ran); re-run after recovery passed 17/17 checks |

### Steps

**Step 1 — Setup: CBT-enabled VM with an observable copy window, plus the destination PVC.** When: before any backup.
```bash
oc get vmi vm-20261012-cbtf05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.nodeName}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get ds virt-handler -n openshift-cnv      # baseline: 28/28 desired and ready
oc get pvc vm-backup-pvc-20261012-cbtf05-r01 -n vm-cbt-demo -o jsonpath='{.status.phase}{"\n"}'
```
What you must see: VMI `Running` with `changedBlockTracking.state` = `Enabled`; the handler DaemonSet at
full strength; the destination PVC `Bound`. (Recorded workload: 1,000 files × 15–20 MiB — the copy took
68 s, which is the window you inject into.)

**Step 2 — Start the full backup: this opens the window.** When: immediately before step 3.
```bash
oc get virtualmachinebackuptracker vm-tracker-20261012-cbtf05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-20261012-cbtf05-r01
  namespace: vm-cbt-demo
spec:
  pvcName: vm-backup-pvc-20261012-cbtf05-r01
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261012-cbtf05-r01
YAML
oc logs virt-launcher-vm-20261012-cbtf05-r01-cmj2j -n vm-cbt-demo -c compute | grep -F 'Backup started'
```
**Window: opens at the `"msg":"Backup started"` line naming this backup (recorded 19:20:21.821431061Z)
and closes at the unplug attempt when the copy ends (recorded 19:21:27.355Z) — 68 seconds here.** What
you must see: `Backup started` in the launcher log and the backup still non-terminal.

**Step 3 — (Injection) Delete the single handler pod on the VM's node: fail-closed pre-check first.**
When: inside the window above.
```bash
NODE=$(oc get vmi vm-20261012-cbtf05-r01 -n vm-cbt-demo -o jsonpath='{.status.nodeName}')
oc get pods -n openshift-cnv --field-selector "spec.nodeName=${NODE}" -l kubevirt.io=virt-handler \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,READY:.status.conditions[?(@.type=="Ready")].status
# fail closed unless exactly one Ready pod is returned; then (the recorded command form):
oc delete pod virt-handler-655mx -n openshift-cnv --wait=false
oc get ds virt-handler -n openshift-cnv
```
What you must see: a `Killing`/`DELETED` event for that UID and a replacement handler Ready on the same
node, with the DaemonSet back at 28/28.

**Step 4 — Let the backup finish: the defect appears at the unplug.** When: no action; wait.
```bash
oc get vmbackup vm-backup-20261012-cbtf05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}{" "}{.status.conditions[?(@.type=="Done")].reason}{"\n"}'
# the handler's own account of the unplug (recorded capture: investigation/handler-unplug-ebusy.log)
oc logs virt-handler-pg5dw -n openshift-cnv --tail=200 | grep -E 'hotplug disk directory|Marking volume'
```
What you must see: `True Successfully completed VirtualMachineBackup` — **the backup reports success** —
and, at the same second, `failed to remove hotplug disk directory …: device or resource busy` followed
by `Marking volume vm-backup-20261012-cbtf05-r01-backup-target-pvc as unmounted from pod, it can now be
detached`, with **no detach ever requested**.

**Step 5 — Read-only demonstration of the defect.**
```bash
# 5a. the attachment is still there: attached, no deletion timestamp, finalizer intact
oc get volumeattachment -o json \
  | jq '.items[] | select(.spec.source.persistentVolumeName=="pvc-111336f6-74e3-447d-999c-c27f53cf38e1")
        | {name:.metadata.name, node:.spec.nodeName, attached:.status.attached,
           deletionTimestamp:.metadata.deletionTimestamp, finalizers:.metadata.finalizers}'
# 5b. who is holding the mapped device (the replacement handler, inside its own hotplug path)
oc debug node/<vm-node> -- chroot /host bash -c \
  'grep -l rbd7 /proc/*/mountinfo 2>/dev/null; ls -l /dev/rbd* 2>/dev/null'
# 5c. the Ceph-side lock that never clears, and the unmap loop
oc logs -n openshift-storage <csi-rbdplugin-pod-on-the-VM-node> --tail=200 | grep -i 'rbd unmap'
# 5d. a reader pod on another node cannot attach the volume
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp | grep FailedAttachVolume
oc get pods -n vm-cbt-demo -o wide | grep restore-verify
```
What you must see: `attached: true`, `deletionTimestamp: null`, finalizer
`external-attacher/openshift-storage-rbd-csi-ceph-com`; a virt-handler process holding `/dev/rbd7`
mounted under its own `hotplug-disks` path (recorded: PID 2151233, cgroup for `virt-handler-pg5dw`);
a repeating `rbd unmap` `Device or resource busy` (238 occurrences over ~2 h in the recorded run) and a
persistent watcher on the RBD image; and the reader pod `Pending` with
`Multi-Attach error for volume "pvc-111336f6-…" Volume is already exclusively attached to one node`.
Declare it stuck only after the reader's own deadline (recorded: ~53 min).

**Step 6 — Recovery: this is the sequence verified live in this run.** When: after capturing 5a–5d; only for
the run's own objects.
```bash
oc delete volumeattachment csi-43bd21aa6b4f7f57d6fcad54cfd247dd77117dabac69d5ed13c01675575762cf
oc delete pod virt-handler-pg5dw -n openshift-cnv --wait=false   # a fresh handler does not re-establish the stale mount
oc get volumeattachment -o json | jq '.items[] | select(.spec.source.persistentVolumeName=="pvc-111336f6-74e3-447d-999c-c27f53cf38e1")'
```
What you must see: the attachment is gone, the device is unmapped (`/dev/rbd7` gone) and the Ceph
watcher is cleared (`Watchers: none`), so the backup PVC can be attached again — the re-run restore
verification then passed 17/17 checks (3m57s, ~21:39Z). What this does **not** restore: the reader that
already timed out must be re-created, the ~53-minute window is lost, and nothing here fixes the defect —
it only unblocks this instance. Keep the backup object: its data was valid and restore-verified.

## Current behaviour (observed)

- **Backup path stays correct.** Full backup `vm-backup-20261012-cbtf05-r01`: `Done=True`, reason
  `Successfully completed VirtualMachineBackup`, type Full, checkpoint
  `vm-backup-20261012-cbtf05-r01-2026-10-12_19-20-19`, tracker advanced once (19:21:27Z, 68 s).
  Same-VM incremental `vm-incremental-20261012-cbtf05-r01-p01`: `Done=True`, same success reason,
  distinct child checkpoint `…p01-2026-10-12_19-23-28`, tracker advanced once (22 s). Both are
  independent artifact observations from the backup/tracker watches. *(The full and incremental
  backups complete successfully; tracker/checkpoint chain is correct.)*
- **At unplug time (copy end) the replacement handler logs** (verbatim, from
  `investigation/handler-unplug-ebusy.log`, an independent raw capture):
  - `failed to remove hotplug disk directory …: device or resource busy` (`pos` `vm.go:1493`, 19:21:27Z)
  - `Marking volume vm-backup-20261012-cbtf05-r01-backup-target-pvc as unmounted from pod, it can now be detached` (`pos` `vm.go:500`, 19:21:27.359614Z)
  - and re-enqueues the VMI with the same `failed to remove hotplug disk directory root: /, relative: /var/lib/kubelet/pods/…/volumes/kubernetes.io~empty-dir/hotplug-disks/…`
- **The `VolumeAttachment` for the backup PV is never deleted.** `investigation/leaked-va.json`
  (raw): attachment `csi-43bd21aa6b4f7f57d6fcad54cfd247dd77117dabac69d5ed13c01675575762cf`,
  `uid 64787ddf-e59f-465a-b0b4-7b25c7b058d6`, `creationTimestamp` 2026-10-12T19:20:19Z,
  `spec.nodeName` `<vm-node>`, `spec.source.persistentVolumeName` `pvc-111336f6…` (PVC
  `vm-backup-pvc-20261012-cbtf05-r01`), finalizer `external-attacher/openshift-storage-rbd-csi-ceph-com`,
  no `deletionTimestamp`; it stayed until manual deletion ~21:20Z. *(The draft's summary rendered the
  finalizer as `external-attacher/openshift-storage.rbd-csi-ceph-com`; the artifact's exact spelling
  is the one quoted above.)*
- **The replacement handler keeps the block device mounted at its own hotplug-disks path.**
  `investigation/rbd7-holder.txt` (raw host process scan): PID 2151233 = `virt-handler (replacement
  pod, node <vm-node>)` with `/dev/rbd7 -> /pods/<vmi-uid>/volumes/kubernetes.io~empty-dir/hotplug-disks/vm-backup-20261012-cbtf05-r01-backup-target-pvc (ext4 rw)`,
  cgroup `kubepods-burstable-pod…slice (virt-handler-pg5dw)`, RBD image
  `ocs-storagecluster-cephblockpool/csi-vol-53263947-89a8-4179-a000-cb25cf25394c`, watcher
  `100.64.0.14 (node <other-node> host-network — CSI node plugin krbd) client.930017`.
  Also raw: `investigation/launcher-hotplug-dir.txt` shows the hotplug dir still containing the
  full backup's directory plus zero-byte `…-backup-target-pvc.img` files, and
  `investigation/virsh-domblklist.txt` shows the running domain holds only `vda`/`vdb` (the leaked
  attachment was never a guest-visible disk).
- **The Ceph RBD image retains an exclusive-lock watcher; `rbd unmap` retries fail EBUSY
  indefinitely** — 238 occurrences in the CSI node plugin logs on the VM's node during the ~2 h the
  leak was left in place (run report `Leak diagnosis` row, 20:20–21:15Z).
- **Any pod mounting the backup PVC on another node stays Pending**: `Multi-Attach error for volume
  "pvc-111336f6…" Volume is already exclusively attached to one node` from 19:23:57Z; the workflow's
  restore-verification pod stayed Pending 53+ minutes and the lifecycle ended FAIL (34m48s).
- **After the documented cleanup**: stale mount released, `/dev/rbd7` gone, `Watchers: none`, and the
  re-run restore verification passed 17/17 checks (3m57s) — i.e. the backup data was correct
  throughout; only the volume's availability was lost.

## Expected behaviour (contract)

The hotplug unplug and CSI detach complete after the handler is replaced: the `VolumeAttachment` is
removed, the device is unmapped, and the backup PVC can be attached by restore workloads on any node
without operator intervention.

**Acceptance check.** After a handler restart inside the copy→unplug window and the backup's terminal
success, `oc get volumeattachment` for the backup PV shows no lingering `attached: true` entry (within
a bounded reconciliation window), `rbd status` on the image shows no leftover exclusive-lock watcher
once no consumer holds it, and a reader pod on a different node mounts the backup PVC successfully
without any manual object deletion or handler restart.

## Impact, workaround and data safety

- **Functions lost / how an operator notices.** Restore and verification of the affected backup are
  unavailable from any node except the one holding the attachment, and the workflow that runs them
  fails. Nothing in the backup CR, tracker, checkpoint chain or VM status reports the problem — the
  operator sees only a Pending restore pod, a `Multi-Attach` event, and an EBUSY loop in the CSI node
  plugin log. **Frequency**: deterministic given the precondition (unplug racing a handler
  replacement), and the precondition is a narrow chaos/maintenance window (node maintenance, agent
  crash, rolling update), not routine operation.
- **Blast radius.** The affected volume only — but any reader scheduled elsewhere. Here: the one full
  backup's destination volume; the incremental's destination PVC unplugged cleanly in the same run
  (raw handler log: `Marking volume vm-incremental-20261012-cbtf05-r01-p01-backup-target-pvc as
  unmounted from pod, it can now be detached` at 19:23:50.542987Z, with no EBUSY). No other node's
  handler was touched, and `oc delete` was scoped to the single pod on the VM's node.
- **Data safety.** No data loss and no corruption: the full-only and cumulative-chain restores both
  matched their manifests (17/17 checks) after cleanup; the VM stayed Running/Ready with CBT Enabled
  throughout. What is *not* available while the leak persists is the ability to read the backup at all
  from another node — which is precisely when a backup is needed.
- **Workaround / operator runbook (live-verified in this run).** 1. Detect: a leftover
  `VolumeAttachment` on the backup PV (finalizer present, no `deletionTimestamp`) plus a
  `Device or resource busy` unmap loop in the CSI node plugin log on the VM's node. 2. Delete the
  orphaned `VolumeAttachment` object. 3. Restart the replacement `virt-handler` pod on that node.
  4. Re-run the reader/restore verification. Cost: two manual actions plus the reader's re-run; it
  does **not** fix the underlying unplug path, and it must not be applied blindly to a volume that is
  still legitimately in use by a *running* backup.
- **Unknowns this ticket deliberately does not claim.** Whether the handler's "marked unmounted"
  state is meant to be terminal or retried; whether the detach is also missed when the handler restarts
  *after* a successful unplug (not observed); whether any automatic reconciliation exists on a longer
  timescale (the leak was cleaned manually after ~2 h, so no natural recovery was observed); the
  measured storage capacity/Ceph free space at run time.

## Evidence

**Artifact index** (repository-relative; all under
`cbt-chaos/scenarios_v2/CBT-F-05/runs/20261012-cbtf05-r01/`; "raw" = verbatim API/log capture,
"derived" = report written by the run):

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `investigation/leaked-va.json` | the leaked `VolumeAttachment` object verbatim (name, uid, `spec.nodeName`, `spec.source.persistentVolumeName`, `spec.attacher`, finalizer list, `creationTimestamp` 19:20:19Z) | captured after the run | raw |
| `investigation/handler-unplug-ebusy.log` | the 5 decisive handler log lines: `failed to remove hotplug disk directory … device or resource busy` (vm.go:1493), `Marking volume … as unmounted …` (vm.go:500), and the incremental's clean unplug pair for contrast | 19:21:27Z, 19:23:35Z, 19:23:50Z | raw |
| `investigation/rbd7-holder.txt` | who held the device: PID/pod/cgroup of the replacement virt-handler, the mount (`/dev/rbd7` → hotplug-disks path), the RBD image, the watcher IP + node | captured during triage (~20:20–21:15Z) | raw |
| `investigation/launcher-hotplug-dir.txt` | launcher hotplug-dir listing: the leaked volume's directory + zero-byte `…-backup-target-pvc.img` entries | 19:23Z | raw |
| `investigation/virsh-domblklist.txt` | the running domain's block list (`vda`, `vdb` only) — the leaked attachment was never guest-visible | post-run | raw |
| `investigation/node-volumes.json`, `investigation/pods-final.txt`, `investigation/events-final.json` | node volume inventory, final pod placement (28 handlers; the VM's launcher on `<vm-node>`), and the full event dump (Multi-Attach, unplug-failure, delete events) | 19:17–21:4xZ | raw |
| `observer/vmbackup.jsonl`, `observer/tracker.jsonl`, `observer/vm.jsonl`, `observer/launcher.jsonl` | backup terminals + reasons, tracker advancements (one per backup), VM/VMI state, launcher identity/image | 19:17–20:0xZ | raw |
| `observer/handlers.jsonl` (+ `.baseline.json`) | the handler pods: baseline count, the deleted pod `virt-handler-655mx` (UID 184db2c1-…), replacement `virt-handler-pg5dw` (UID d903d69d-…), and their image digests | 19:17–20:0xZ | raw |
| `observer/events-virt-handler.jsonl`, `observer/events-all.jsonl` | the scoped and cluster-wide event streams backing the timeline | run window | raw |
| `test-run-report.md`, `test-run-result.md` | run verdict (FAIL), acceptance table (hotplug unplug FAIL; follow-up restore FAIL), timeline, findings, evidence summary, environment table | run window | derived |
| `trigger.log` | the workflow's own stage log (`VM_OS=rhel9`, workload profile, deletions, verification results) | run window | raw |

**Draft wording preserved verbatim from the reporter draft** (so this ticket's evidence index still
matches the original record): the handler lines written in abbreviated form as
`Marking volume … as unmounted from pod, it can now be detached` (vm.go:500) and, in the draft's
investigation list, `vm.go:1493` (`failed to remove hotplug disk directory`) / `vm.go:500`
(`Marking volume … unmounted`); the reader error as
`Multi-Attach error for volume … Volume is already exclusively attached to one node`; the attachment as
VolumeAttachment `csi-43bd21aa…` for PV `pvc-111336f6…` (PVC `vm-backup-pvc-20261012-cbtf05-r01`); the
RBD image as `csi-vol-53263947…`; the recovery result as `rbd status` → `Watchers: none` with
`/dev/rbdX` gone; the holder's mount path as
`/pods/<vmi-uid>/volumes/kubernetes.io~empty-dir/hotplug-disks/<backup-pvc>`; and the placeholder
injection command `oc delete pod virt-handler-<pod> -n openshift-cnv --wait=false` (this ticket's steps
use the same commands with the run's concrete names substituted).

**UTC timeline** (setup → precondition → injection → effect → failure → recovery):

| # | Time (UTC), 2026-10-12 | Event | Source |
|---|---|---|---|
| 1 | 19:17:57Z | Monitor armed; DaemonSet 28/28; baseline captured | report timeline; `handlers.jsonl.baseline.json` |
| 2 | ~19:19–19:20Z | Full backup requested into the run-scoped destination PVC; `VolumeAttachment` created attached to `<vm-node>` | `leaked-va.json` (`creationTimestamp` 19:20:19Z) |
| 3 | 19:20:21.821Z | Copy-start signal `Backup started` for the exact backup name (sub-second launcher timestamp) | report; launcher compute log |
| 4 | during the 68 s copy | **Injection**: `virt-handler-655mx` (UID 184db2c1-8107-4cbe-b27f-f78e5a056960) deleted on `<vm-node>`; replacement `virt-handler-pg5dw` Ready on the same node | report; `handlers.jsonl` |
| 5 | 19:21:27Z | Full backup terminal `Done=True` `Successfully completed VirtualMachineBackup` (68 s); tracker advanced once | backup/tracker watches; report |
| 6 | 19:21:27.355Z | **Effect**: `failed to remove hotplug disk directory … device or resource busy` (vm.go:1493) + `Marking volume … as unmounted` (vm.go:500); attachment pod `hp-volume-j2j5l` killed; **no detach ever requested** | `handler-unplug-ebusy.log`; report |
| 7 | ~19:23:50Z | Same-VM incremental terminal `Done=True` (22 s), distinct checkpoint, clean unplug — the flow works when no restart is in the window | report; handler log (19:23:50.542987Z) |
| 8 | 19:23:57Z onward | **Failure**: reader pod Pending on `Multi-Attach error` for the backup PV, ~53 min, until the workflow gave up (E2E FAIL, 34m48s) | report timeline; `events-final.json` |
| 9 | ~20:20–21:15Z | Leak diagnosis: stuck `VolumeAttachment` (finalizer, no `deletionTimestamp`); RBD watcher `100.64.0.14`; `rbd unmap` EBUSY ×238; holder = replacement handler PID 2151233 with `/dev/rbd7` mounted | report; `rbd7-holder.txt` |
| 10 | ~21:20–21:35Z | **Recovery**: orphaned `VolumeAttachment` deleted; replacement handler restarted → stale mount released, `/dev/rbd7` gone, `Watchers: none` | report timeline |
| 11 | ~21:39Z | Restore verification re-run: 17/17 checks PASS (3m57s) — data was correct all along | report; `test-run-result.md` |

**Retained state.** The run's objects were preserved for triage: the full and incremental backup CRs
(both `Done=True`), the tracker at the incremental's child checkpoint, both destination PVCs `Bound`,
the VM/VMI Running with CBT Enabled, and the raw watch streams plus the `investigation/` captures. The
only deletions were the deliberate ones of this ticket: the injected handler pod (recreated by the
DaemonSet), and — as part of the documented recovery — the orphaned `VolumeAttachment`, which is why
the object survives in the pack only as the captured `investigation/leaked-va.json` rather than as a
live object. The reader pod's first attempt was left as a failed attempt and re-run after cleanup.

## Negative results and what would falsify this ticket

- **Refuted: "any backup leaves a leftover attachment."** The draft's recorded control observation is
  that control runs (no handler disruption) show no leftover `VolumeAttachment` on backup PVCs; this
  run corroborates it on the artifact level — the incremental pass, which ran with a healthy replacement
  handler, unplugged cleanly (19:23:50.542987Z) and its volume attached elsewhere with no leak.
- **Refuted: "the backups failed."** Full and incremental both terminal-succeeded with correct
  checkpoints and one tracker advancement each; the same-VM incremental ran the whole chain cleanly.
  The defect is in volume cleanup, not in the copy, chain, or tracker.
- **Refuted: "the unplug always fails."** The **incremental's** destination volume unplugged cleanly
  in the same run minutes later (`Marking volume vm-incremental-…-backup-target-pvc as unmounted from
  pod, it can now be detached`, 19:23:50.542987Z, no EBUSY) — so the failure tracks the restarted
  handler holding the mount, not the storage class, the volume type, or a general detach defect.
- **Refuted: "the guest or the VM is involved."** `virsh domblklist` shows the running domain holds
  only `vda`/`vdb`; the leaked attachment was never a guest-visible disk, and the VM stayed
  Running/Ready with CBT Enabled throughout.
- **Refuted: "the reader pod's failure is a scheduling or node problem."** It failed with
  `Multi-Attach error` on the backup PV — an attachment-specific error that names the exclusivity —
  while the same node could attach other volumes.
- **Refuted (for this ticket's evidence): "the block device is simply still needed."** The volume's
  backup was terminal, the attachment pod had been killed, and no process other than the stuck handler
  held it; the documented cleanup released it immediately.
- **Not tested here (so not claimed):** natural recovery on a longer timescale (cleanup was manual
  after ~2 h); a handler restart *after* a completed unplug; the same behaviour with a different CSI
  driver (all F-05 evidence is Ceph RBD); whether a pre-scoped chaos tool can inject this reliably
  (the pod name only exists after setup).
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. Keeping a completed backup's destination volume attached to the VM's node while the source VM
     runs is the *intended* contract (then the defect is the undocumented release condition and the
     missing reader path, not the retention) — a triage/API-contract answer.
  2. The attachment is shown to be released automatically if simply left alone for a documented
     reconciliation window (this run's 2 h observation says otherwise, but it is a single sample).
  3. The RBD EBUSY loop and the retained `VolumeAttachment` are shown to be caused by something other
     than the restarted handler holding the mount (e.g. a stale CSI node-plugin state independent of
     the handler) — that would move the fix site entirely.

## Additional feedback (reporter's notes)

- **Open triage question that decides the fix site.** Is the handler's "Marking volume … as unmounted"
  state meant to be terminal, or should the EBUSY be retried to completion? Alternative: should a
  terminal backup trigger an independent detach reconciliation in the backup controller instead of
  relying on the (possibly replaced) handler? The run's own recommendation was both: fix the retry
  semantics around `vm.go:1493`/`vm.go:500`, **and** make CSI `NodeUnstageVolume` idempotent when the
  staging path is still held by a restarting consumer (the consumer holding the device open is the
  handler itself). The draft's third investigation area is also open: the **external-attacher detach
  flow when the `VolumeAttachment` outlives all pods referencing the volume** — nothing in the
  observed evidence shows any detach being requested at all for the leaked volume.
- **Smallest experiments that would settle the open points.** (a) Repeat the injection but restart the
  handler a *second* time after the unplug attempt and observe whether the detach is then requested —
  separates "retry missing" from "state marked terminal". (b) Take one run with no injection and
  confirm the normal detach latency (control), to bound the reconciliation window an operator should
  wait before intervening. (c) Watch the CSI node plugin for whether any `NodeUnstageVolume` call is
  ever made for the leaked volume (the run's logs suggest none was).
- **Cross-references.**
  - Companion ticket in this folder: `bug-backup-volume-attachment-leak.md` — same behaviour family
    with two independent run labels (2026-10-11, RHEL 9 + Windows), the side-by-side comparison, and
    the event-level evidence. Together the two files cover three run labels; neither duplicates the
    other's artifacts.
  - Separate observation (not this ticket): this run's own analysis recorded the recurring
    "`Backup has failed: VMI backup status was lost`" warning event on successful backups — the same
    event-masking class that masks a real ENOSPC in `CBT-EXP-07/bugs/backup-reports-success-with-no-data-on-target-enospc.md`.
    It degrades failure semantics but is a different component and a different ticket.
  - Harness/tooling gap (clearly separate, **not** part of this ticket): the run's report records that
    the trigger's 8 × 1 GiB workload profile was overridden by the host `.env` (the run used the
    1000-file 15–20 MiB profile instead) — copy/unplug semantics were unaffected, but the workload
    discrepancy is a harness issue for the Scenario Improver's lane, not a product defect.
- **Environment-specific notes for the next reproducer.** (a) The deletion must land **after** the
  copy-start signal and **before** the unplug; this run's window was only 68 s. (b) The reader must be
  scheduled to a different node or the leak is invisible. (c) The event and object timestamps are
  second-granularity; use the launcher and handler logs (sub-second) for ordering. (d) Detection on a
  live cluster: a `VolumeAttachment` for a backup PV with the external-attacher finalizer and no
  `deletionTimestamp` is the cheapest signal; the EBUSY unmap loop in the CSI node plugin log on the
  VM's node is the corroborating one. (e) Keep the leaked objects for triage before cleaning up —
  the recovery deletes an object that is itself the evidence.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted; only run-scoped
      object names, UIDs and image digests.
- [x] No private hostnames or absolute host paths — cluster node names are genericised as
      `<vm-node>` / `<other-node>` / `<reader-node>`; path-like strings are kept only inside verbatim
      product log fragments (`failed to remove hotplug disk directory root: /, relative:
      /var/lib/kubelet/pods/…`, `lstat /proc/1/root/…`) and container-internal pod paths, all
      abbreviated and sanitised as quotes. Host paths that name the storage pool are in the
      Environment table as measured identifiers, not as customer data.
- [x] No broad selectors (names or run-scoped labels only) — every read is scoped by the run's exact
      object names, the VM's node, or the backup PV; there is no cluster-wide delete or label-wide
      selector.
- [x] No destructive commands other than the documented, scoped workaround — the injection deletes one
      named handler pod; the recovery (delete the orphaned `VolumeAttachment`, restart the replacement
      handler) is scoped to the run's own objects and is explicitly marked as the live-verified
      procedure for this state.
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the injection and
      inspection commands are the ones this run used; the note above the steps says which command
      shapes are re-creations.
