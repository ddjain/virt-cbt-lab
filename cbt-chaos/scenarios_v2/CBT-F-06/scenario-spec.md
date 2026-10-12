# Scenario: Restart the HostPath CSI node plugin before the full-backup destination binds

- **Jira:** CBT-F-06 — Restart storage access before the backup destination is attached
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Operation start

## 1. Jira objective and hypothesis

The issue asks whether a transient loss of the storage-access component (the HostPath CSI node plugin) while a full backup's destination PVC is still being provisioned/bound is safe. Delete the single HostPath CSI node-plugin pod while the full backup's destination PVC exists but has not yet reached `Bound`. Destination provisioning/hotplugging should pause while the plugin restarts; once it returns, the destination should bind and attach normally and the backup should continue to a clean terminal state, or fail cleanly if the delay exceeds controller tolerance — it must never report a false `Done=True` over a broken/partial destination.

The issue fields are: workflow **Full backup**; target **HostPath storage CSI node plugin**; action **delete the CSI node plugin pod**; timing **after the backup starts but before the destination volume is bound and attached**; signal **backup is progressing and destination PVC is not yet bound**; duration **immediate**; recovery **automatic CSI plugin restart**; verification **CSI recovery, destination PVC binding, successful volume attachment, final backup state, and tracker consistency**; expected outcome **shows whether the storage attachment path recovers cleanly from a transient outage**.

## 2. Evidence and live target resolution (conflict found and resolved)

**Key conflict:** the active `Makefile`/`scripts/common.sh` default `MANIFEST_VARIANT=large-odf`, which backs the VM disk and the full-backup destination PVC with `ocs-storagecluster-ceph-rbd(-virtualization)` (Ceph RBD CSI), not HostPath. Running the default `make e2e` would never exercise the HostPath CSI node plugin this issue targets. `scripts/common.sh`'s `manifest_path()` resolves `MANIFEST_VARIANT=default` and `MANIFEST_VARIANT=large` to the same `cbt-demo-hpp` storage class on every supported `VM_OS` (for `rhel9` — the default profile — both `default` and `large` map internally to the `large` HPP manifests `manifests/vm-large.yaml` / `manifests/full-backup-large.yaml`, confirmed `storageClassName: cbt-demo-hpp` in both). `chaos-trigger.sh` therefore pins `MANIFEST_VARIANT=default` (overridable to `large`) and explicitly refuses `odf`/`large-odf`.

Read-only inspection of the live cluster (via the approved execution host, using its configured cluster kubeconfig) confirmed:

- Storage class `cbt-demo-hpp`: provisioner `kubevirt.io.hostpath-provisioner`, `VOLUMEBINDINGMODE=WaitForFirstConsumer`. A PVC on this class stays `Pending` until a consumer (the hotplug attachment pod) appears — **measured live (run `20261012-cbtf06-r01`) to resolve to `Bound` within the same one-second API timestamp as creation**, i.e. a sub-poll-interval window. `status.phase == Pending` is therefore not a usable external trigger condition here; see §5 for the corrected signal (`VirtualMachineBackup` CR existence).
- The HostPath CSI node plugin runs as exactly one pod cluster-wide: `hostpath-provisioner-csi-jpjbm` in namespace `openshift-cnv`, owned by DaemonSet `hostpath-provisioner-csi`, containers `hostpath-provisioner`, `node-driver-registrar`, `liveness-probe`, `csi-provisioner`. This matches the single-HPP-pool/single-worker topology recorded in `docs/cbt/11-cloud05-audit.md`. **Label caveat confirmed live:** `k8s-app=hostpath-provisioner` also matches an unrelated pod, `hpp-pool-cbt-demo-pool-<node>-*` (the HPP backing storage-pool pod, owned by a `ReplicaSet`, not the CSI `DaemonSet`). Only pod names matching `^hostpath-provisioner-csi-` are the actual CSI node plugin; the trigger selects by that name pattern, not the shared label.
- The `vm-cbt-demo` namespace holds many prior/parallel triage runs (`vm-20261010-cbt-f-01*`, `vm-20261011-*`, etc.). The new run uses a fresh, unique `RUN_ID`; the trigger refuses to start if any existing resource name already contains it.

The destination PVC and `VirtualMachineBackup` names are fully deterministic from `RUN_ID` before the workflow starts (`scripts/run-id.sh`'s `set_resource_names`): `vm-backup-pvc-${RUN_ID}` and `vm-backup-${RUN_ID}`. This lets the trigger use Krkn's **native** `--trigger-k8s-*` condition (no custom host-side observer needed), satisfying the triage timing rule that krknctl's own trigger absorb its startup latency ahead of the short injection window.

## 3. Workflow and prerequisites

`scripts/e2e-stage.sh` (invoked by `make e2e`) supports `TYPE=full`, `TYPE=incremental`, `TYPE=recover`, `TYPE=extend`, and `TYPE=verify` on the currently checked-out Makefile. This is a **Full backup** issue, so the trigger uses:

```sh
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS=rhel9 MANIFEST_VARIANT=default \
  NAMESPACE=vm-cbt-demo GUEST_BASE_FILE_COUNT=8 \
  GUEST_INCREMENTAL_FILE_COUNT=4 GUEST_INCREMENTAL_PASSES=1 \
  GUEST_FILE_SIZE_MIN_MIB=4 GUEST_FILE_SIZE_MAX_MIB=12 \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

`TYPE=full` creates a fresh managed VM/workload and takes one Full backup; it records `incremental_passes_total` in `runs/$RUN_ID/run.json` even though only the full stage runs here. No sustained copy window is required for this scenario — the injection targets the pre-bind provisioning window, which is governed by `WaitForFirstConsumer` scheduling latency, not guest payload size — so the repository's small/default guest sizing is used.

## 4. Target and validated disruption

**Primary (krknctl, native trigger):**

```sh
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --name-pattern '^hostpath-provisioner-csi-' \
  --disruption-count 1 \
  --trigger-k8s-api-version backup.kubevirt.io/v1alpha1 \
  --trigger-k8s-kind VirtualMachineBackup \
  --trigger-k8s-namespace vm-cbt-demo \
  --trigger-k8s-name "vm-backup-${RUN_ID}" \
  --trigger-k8s-condition "metadata.name == vm-backup-${RUN_ID}" \
  --triggers-timeout 1800 \
  --triggers-interval 2 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
```

Validated with `krknctl run pod-scenarios --dry-run ...` against the exact flags above (schema valid, all required fields present, values validated) on `cloud05` on 2026-10-12. `krknctl describe pod-scenarios` / `krknctl run pod-scenarios --help` confirm `--name-pattern`, `--disruption-count`, and the `TRIGGERS` flag group (`--trigger-k8s-*`) are real, supported flags for this krknctl build (`v0.14.2-beta`); the `--name-pattern` match was separately confirmed live to return exactly the one CSI pod (not the `hpp-pool-*` pod).

`chaos-trigger.sh` launches this command in the background **before** `make e2e TYPE=full`, per the triage timing rule: krknctl's own image-pull/startup latency must be absorbed before the condition exists.

**Measured and rejected first design:** the originally planned trigger (`PersistentVolumeClaim` `status.phase == Pending`) was tried live on run `20261012-cbtf06-r01` and never fired. The read-only observer's PVC watch recorded `ADDED(Pending) → MODIFIED(Pending)×3 → MODIFIED(Bound)` all at the identical one-second API timestamp `2026-10-12T13:00:19Z` — on `WaitForFirstConsumer`/`cbt-demo-hpp`, the PVC binds essentially the instant the hotplug consumer pod is scheduled, well under krknctl's 2-second poll interval, even though krknctl was already running and polling before the PVC was created. The condition was true for less time than one poll cycle, so it was never observed. The corrected design instead watches for the `VirtualMachineBackup` CR's own creation (a condition that is trivially true the moment the object exists, evaluated via a tautological `metadata.name` comparison since no explicit "exists" condition is documented), which fires on krknctl's very next poll after the backup CR is applied — still "after the backup starts" and strictly before the destination PVC can bind, satisfying the issue's intent even though it is earlier than the literal "PVC not yet bound" wording.

**Second measured issue, also fixed:** `krknctl`'s `--trigger-k8s-condition` grammar expects a bare, unquoted literal on the right-hand side (matching the documented example `status.phase == Running`), not a quoted string. An initial attempt using `metadata.name == 'vm-backup-${RUN_ID}'` (single-quoted) never satisfied even after the CR existed, because the quote characters became part of the literal compared against the unquoted actual field value. Confirmed live in isolation against an already-existing `VirtualMachineBackup`: the unquoted form `metadata.name == vm-backup-20261012-cbtf06-r02` satisfied immediately (`trigger condition satisfied`) and `krknctl` deleted `hostpath-provisioner-csi-jpjbm`, which the DaemonSet replaced within ~10s as `hostpath-provisioner-csi-twzkf` (different UID), confirming both the condition fix and the CSI recovery path work end-to-end. `chaos-trigger.sh` uses the unquoted form.

No `oc`/`kubectl` fallback is needed: the target and timing are both expressible with a single native Krkn trigger and selector.

## 5. Deterministic injection signal

**Condition:** the `VirtualMachineBackup` CR `vm-backup-${RUN_ID}` exists in `vm-cbt-demo`. This CR and the destination PVC are applied together from the same manifest in one `oc apply`, so CR existence is the earliest observable signal that "the backup is progressing" and is guaranteed to precede or coincide with PVC creation/binding. `--triggers-on-timeout fail` makes krknctl itself fail loudly (not silently skip) if the CR never appears within `--triggers-timeout` (1800s, covering VM setup plus backup-CR apply).

The resulting CSI-plugin outage (pod delete → DaemonSet recreate → new pod Ready) lasts several seconds to tens of seconds — long enough to realistically overlap the PVC bind/attach sequence that follows within that same window, even though it can no longer be proven to start strictly before `Bound` is reached for every reconcile. There is no arbitrary sleep substituting for this signal anywhere in the trigger.

**Chaos duration:** the pod-scenarios action is a single delete (default graceful, `--force` not set); recovery is the HostPath CSI DaemonSet's own controller reconciliation — no manual restart step.

## 6. Pass/fail criteria

A product **pass** requires all applicable checks below:

- The baseline and post-chaos HostPath CSI node-plugin pod identity (name/UID) are captured; the replacement pod is distinct (`uid` differs) and reaches `Running`/`Ready` without manual intervention, and the DaemonSet's desired/ready counts match afterward.
- `vm-backup-pvc-${RUN_ID}` eventually reaches `Bound` and the backup's attachment pod (`hp-volume-*`) reaches `VolumeMountedToPod`, **or** the full `VirtualMachineBackup` fails to a clear, non-`Done=True`-masking terminal reason within the controller's own timeout — never an indefinite `Progressing` hang.
- The full `VirtualMachineBackup` reaches a settled terminal state: a success must be `type=Full`, `Done=True` with a non-`failed` reason, a non-empty checkpoint, and the expected root-disk included volume; a failure must carry a clear reason and must not advance `vm-tracker-${RUN_ID}`'s latest checkpoint.
- The VM/VMI remain `Running`/`Ready` with CBT `Enabled` throughout (this scenario never touches `virt-launcher`/`virt-handler`/`virt-controller`), so no VM-side recovery step is expected — only the storage/attachment path is exercised.

**Post-chaos same-VM backup verification (required, per the issue's own "tracker consistency" check):**

- If the original full succeeds, run the same-VM planned incremental pass(es) (`make e2e TYPE=incremental VM="vm-${RUN_ID}"`) and the chain/restore verification that the final planned pass performs, confirming the tracker and checkpoint chain are unaffected by the earlier transient CSI outage.
- If the original full fails terminally, run `make e2e TYPE=recover VM="vm-${RUN_ID}"`, which creates a distinct `vm-recovery-full-${RUN_ID}-rNNN`/`vm-recovery-pvc-${RUN_ID}-rNNN` through the existing tracker and verifies a baseline restore, without reusing or deleting the original failed backup/PVC.
- Preserve the original (possibly partial) destination PVC/backup object; never retry by reusing a failed backup/destination name.

**Evidence commands:**

```sh
oc get pvc "vm-backup-pvc-${RUN_ID}" -n vm-cbt-demo -o yaml
oc get vmbackup "vm-backup-${RUN_ID}" -n vm-cbt-demo -o yaml
oc get vmbackuptracker "vm-tracker-${RUN_ID}" -n vm-cbt-demo -o yaml
oc get pods -n openshift-cnv -o wide | grep '^hostpath-provisioner-csi-'
oc get ds hostpath-provisioner-csi -n openshift-cnv -o wide
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp
oc get vm "vm-${RUN_ID}" -n vm-cbt-demo -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
```

A product **fail** includes a false successful backup over a broken/partial destination, tracker/checkpoint advancement from a failed or incomplete copy, an indefinite `Progressing` hang with no bound retry, unclear failure reason, CSI DaemonSet failing to self-heal, or an incorrect/blocked same-VM follow-up.

## 7. Blast radius, recovery, and conflicts

Only the single cluster-wide HostPath CSI node-plugin pod is targeted (`--disruption-count 1`, label-scoped, no node/namespace-wide selector). Because this is the only HPP pool/worker in the cluster, the brief outage can transiently affect any other HPP-backed PVC provisioning/binding in flight on other namespaces/VMs at the same moment; `chaos-trigger.sh` does not serialize against other users of `cbt-demo-hpp`, so avoid running this scenario concurrently with another HPP-provisioning-sensitive test. The DaemonSet owns recovery; no manual CSI restart is used. The trigger refuses to start if its chosen `RUN_ID` already has local or cluster-side resources. Never run `make clean-all`; preserve failed backup/PVC objects for inspection.

Unresolved/uncertain: the `VirtualMachineBackup`-existence trigger (§5) has not itself been proven live to still land the CSI deletion before the PVC reaches `Bound` on every run — it is earlier and safer than the disproven PVC-phase trigger, but PVC bind was measured to complete within the same one-second window as CR creation, so on a given run the delete may still land a moment after bind. Treat "destination provisioning/hotplugging paused by the outage" as the testable claim, not a guaranteed pre-bind delete; confirm the actual delete-vs-bind ordering from the observer's timeline on every run rather than assuming it from this design. Run `scripts/monitor.sh "$VM_NAME"` alongside the trigger to capture the real timeline.
