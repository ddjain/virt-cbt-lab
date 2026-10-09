# Scenario: Fail over the backup controller during full-backup reconciliation

- **Jira:** CBT-F-03 — Restart the backup controller when a full backup is starting
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Operation start

## 1. Objective and hypothesis

The issue asks whether deleting the **current backup-controller leader pod** while a full backup request is progressing, but before it has a final result, causes the standby controller to become leader and resume reconciliation without duplicate backup/checkpoint state. The product hypothesis is that the full backup completes successfully, the tracker is advanced exactly once, and the resulting checkpoint and restored data remain valid. This scenario does not use `Progressing=True` as evidence that QEMU is actively copying disk blocks; active-copy timing is a separate launcher-log boundary.

The issue fields are: workflow **Full backup**; target **current backup controller leader**; action **delete the current controller leader pod**; timing **after the request is accepted and being reconciled, before completion**; signal **request progressing with no final result**; duration **immediate**; recovery **automatic controller leader election**; verification **new leader, both replicas ready, one checkpoint, one tracker update, and restore**.

## 2. Workflow and prerequisites

Local and remote active workflow sources were inspected at revision `111e3e0`; both Makefiles and staged `scripts/e2e-stage.sh` consume `TYPE`. `TYPE=full` runs read-only preflight, creates a new managed VM and workload, and creates exactly one full backup; it deliberately reports the lifecycle as incomplete because incremental passes are deferred. This is the minimum workflow matching the Jira injection point. Use a unique run ID and do not run another lifecycle concurrently:

```sh
RUN_ID=<unique-run-id> bash cbt-chaos/scenarios_v2/CBT-F-03/chaos-trigger.sh
```

The script invokes the supported full stage as:

```sh
make e2e TYPE=full NAME="$RUN_ID" KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

After the full stage has recovered and its full backup has a valid checkpoint, the script invokes the supported same-VM follow-up:

```sh
make e2e TYPE=incremental VM="vm-$RUN_ID" KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

That follow-up uses the saved `runs/<run-id>/run.json`, does not recreate the VM, creates the distinct pass-1 backup/PVC, and on the final planned pass runs repository checkpoint-chain and restore verification. The script preserves all run-scoped backup, tracker, and PVC objects; it never retries a failed name or cleans the namespace. `KUBECONFIG_PATH` must already be set to the approved execution-host path; its value is not stored here.

If the disrupted full request is terminally failed or has no valid full checkpoint, the active workflow exposes no backup-name/PVC override for a safe same-VM retry. In that outcome, the required same-VM follow-up is **BLOCKED**, not silently substituted with a reused full-backup name; preserve the failed objects and obtain an approved manual API request path before attempting recovery. A fresh lifecycle is supplemental only and cannot replace this check.

## 3. Live target and controller-election evidence

The live cluster's `openshift-cnv/virt-controller` Deployment has `spec.replicas=2` and `status.readyReplicas=2`. Both pods carry `kubevirt.io=virt-controller`; each is Ready and is owned by the same ReplicaSet. The Deployment's container readiness probe is HTTPS `/leader` on port 8443. The live `openshift-cnv/Lease` named `virt-controller` records the elected holder in `.spec.holderIdentity`, with a 15-second lease duration. Therefore the supported target resolution is performed immediately before disruption:

```sh
CONTROLLER_NAMESPACE=openshift-cnv
LEADER="$(oc -n "$CONTROLLER_NAMESPACE" get lease virt-controller \
  -o jsonpath='{.spec.holderIdentity}')"
oc -n "$CONTROLLER_NAMESPACE" get pod "$LEADER" -o json
```

The target must still have label `kubevirt.io=virt-controller` and Ready=True. The Deployment/Lease/readiness design supports leader election and standby takeover as an intended mechanism, but no pod was deleted during triage. Consequently, successful standby takeover after deleting the actual holder is an **unobserved hypothesis**, not a live-triage fact. The scenario must record the Lease holder before disruption, the holder transition after disruption, the pre-existing standby pod identity, and both Deployment replica readiness states.

**Narrow target selector:** the observer requires namespace `openshift-cnv`, label `kubevirt.io=virt-controller`, and the current Lease holder's Ready pod. The Krkn command uses only the exact holder-name regex (`^${LEADER}$`) because Krkn documents `--name-pattern` as applicable only when `--pod-label` is omitted. This selects one current leader rather than every controller pod. The target is cluster control-plane scope even though the selector is one pod: controller reconciliation for unrelated VM resources can be delayed during disruption.

## 4. Chaos mechanism and current Krkn metadata

The current execution host has `krknctl`, and `krknctl list available` includes `pod-scenarios`. `krknctl describe pod-scenarios` identifies Pod Failures and confirms `--namespace`, `--pod-label`, `--name-pattern`, `--disruption-count`, `--execution`, `--kill-timeout`, and `--expected-recovery-time`. `krknctl run pod-scenarios --help` additionally exposes the event trigger flags `--trigger-command`, `--trigger-k8s-api-version`, `--trigger-k8s-kind`, `--trigger-k8s-namespace`, `--trigger-k8s-name`, and `--trigger-k8s-condition`; a Krkn event-trigger interface therefore exists. The exact scenario tag is `pod-scenarios`, not an underscored alias.

The validated parameterized disruption invocation is:

```sh
krknctl run pod-scenarios \
  --dry-run \
  --namespace openshift-cnv \
  --name-pattern "^${LEADER}$" \
  --disruption-count 1 \
  --execution serial \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --kubeconfig "$KUBECONFIG_PATH" \
  --krkn-kubeconfig /home/krkn/.kube/config
```

`krknctl run pod-scenarios --dry-run` was executed with the live controller namespace, exact observed Lease-holder name regex, one disruption, and the execution-host kubeconfig configuration. It returned `Scenario schema valid`, `All required fields present`, and `Values validated`. This proves CLI schema/parameter acceptance only; it does not prove deletion, leader takeover, or recovery.

Although Krkn has a documented `--trigger-command`, the availability of `oc`/`kubectl` and the trigger command's kubeconfig mount inside the Krkn runtime was not established without starting a scenario. `chaos-trigger.sh` consequently uses a host-local, read-only observer for the exact backup condition and then invokes the same Krkn disruption command. This is an event-driven fallback, not a time-based substitute: it never mutates the cluster itself and does not use an arbitrary sleep to decide when to delete the pod.

## 5. Deterministic injection timing

**Signal:** the run-scoped `VirtualMachineBackup` named `vm-backup-$RUN_ID` exists in the workflow namespace with a `status.conditions` entry `{type: Progressing, status: True}`, and it has no `{type: Done, status: True}` condition. This is the requested accepted/reconciling/not-complete signal. It is intentionally not the launcher `Backup started` signal and must not be reported as proof of active disk copy.

The observer is armed before `make e2e TYPE=full`. It polls only that exact run-scoped backup object, captures the current Lease holder and its pod UID after the signal, verifies the label and Ready condition, then starts Krkn with an exact leader name selector. If the backup reaches a final result before the signal, the observer refuses to inject. If the signal or target cannot be observed before the bounded observer deadline, the scenario is inconclusive and no broad target is used.

## 6. Expected behavior and pass/fail criteria

**Pass only if all of the following are established:**

- Immediately before injection, the exact run backup is reconciling (`Progressing=True`) with no final `Done=True`; the pre-injection backup YAML, tracker state, Lease holder, leader pod UID, standby pod identity, and controller Deployment readiness are saved.
- The host observer verifies the holder's `kubevirt.io=virt-controller` label and Ready condition; Krkn receives its exact Lease-holder name pattern and disrupts only that pod. No standby or other controller pod is eligible.
- The surviving standby controller becomes the Lease holder, the Deployment returns to two Ready replicas, and the replacement for the deleted pod is Ready. Record the Lease holder transition and pod UID/owner transitions; do not infer election from Krkn exit status alone.
- The full `VirtualMachineBackup` settles as `Done=True`, `Progressing=False`, `status.type=Full`, with a non-empty checkpoint and a successful reason. A `Done=True` condition whose reason begins `Backup has failed` is not success.
- After original full-backup reconciliation and **before** the post-chaos incremental stage, exactly one valid full checkpoint exists and tracker `latestCheckpoint` equals that full checkpoint. The subsequent same-VM incremental stage must advance the tracker exactly once to its distinct child checkpoint. Preserve tracker snapshots, resource versions/events where available, controller logs, and the libvirt checkpoint tree across both stages.
- The VM/VMI remains or returns Running, its replacement launcher is Ready, and VM `.status.changedBlockTracking.state` is `Enabled`.
- The full destination PVC is retained and inspected with `qemu-img info` and `qemu-img map --output=json` where the helper is available. Repository restore verification proves the baseline workload manifest from the full image.
- On the **same recovered VM**, the post-chaos `TYPE=incremental` stage creates a distinct `vm-incremental-$RUN_ID-p01` and `vm-incremental-pvc-$RUN_ID-p01`, advances the tracker once to a distinct child checkpoint, and completes as `type=Incremental`, `Done=True`. Full-plus-incremental restore verification matches the recorded cumulative guest manifest. Failed or superseded resources remain preserved.

**Fail:** the Lease does not move to the surviving standby; either controller replica does not return Ready; a different/unscoped pod is deleted; the full backup has a terminal failure, duplicate checkpoint, duplicate successful request, missing/incorrect tracker update, or false success; CBT/VM recovery fails; artifact or restore hashes do not match; the same-VM follow-up reuses an existing name or destination; or any required evidence is unavailable. If the full backup has no valid checkpoint and the distinct-name same-VM follow-up cannot be safely requested through the active API/workflow, mark that follow-up BLOCKED rather than calling the scenario pass.

**Evidence commands** (substitute only names captured for this run):

```sh
oc -n "$NAMESPACE" get vmbackup "vm-backup-$RUN_ID" -o yaml
oc -n "$NAMESPACE" get vmbackuptracker "vm-tracker-$RUN_ID" -o yaml
oc -n "$NAMESPACE" get vm "vm-$RUN_ID" -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
oc -n "$NAMESPACE" get vmi "vm-$RUN_ID" -o wide
oc -n "$NAMESPACE" get pods -l "virt-cbt-lab/run-id=$RUN_ID" -o wide
oc -n "$CONTROLLER_NAMESPACE" get deploy virt-controller -o yaml
oc -n "$CONTROLLER_NAMESPACE" get lease virt-controller -o yaml
oc -n "$CONTROLLER_NAMESPACE" get pods -l kubevirt.io=virt-controller -o wide
oc -n "$NAMESPACE" get events --sort-by=.lastTimestamp
oc -n "$NAMESPACE" get pvc "vm-backup-pvc-$RUN_ID" "vm-incremental-pvc-$RUN_ID-p01" -o yaml
oc -n "$NAMESPACE" exec <ready-launcher-pod> -c compute -- \
  virsh checkpoint-list "${NAMESPACE}_vm-${RUN_ID}" --tree
```

The API condition, reason, checkpoint, tracker, controller Lease, pod UID, Deployment readiness, events, CBT state, libvirt tree, PVC/artifact metadata, and restore manifest are all required evidence. `Done=True`, a Krkn success, or a warning event alone is insufficient.

## 7. Blast radius, recovery, cleanup, and uncertainties

Deleting one `virt-controller` leader pod is an immediate disruption to the cluster-scoped KubeVirt control-plane reconciliation process, not only to this namespace. The exact selector limits deletion to one pod, but unrelated VM operations may experience reconciliation delay during leader handoff. Do not run with another KubeVirt chaos action, maintenance restart, or concurrent E2E lifecycle.

Recovery is expected to be automatic through the existing two-replica Deployment and Lease election. Preserve failed backups, PVCs, trackers, events, logs, and pod identity evidence. Do not run `make clean-all`, delete resources, run E2E during triage, resync a live run, or reuse a failed backup/PVC name. The trigger script performs no cleanup beyond its local temporary signal file and process cleanup if the workflow exits early.

Live triage established the two-Ready-replica Deployment, `/leader` readiness probe, Lease holder mechanism, target labels, and current `pod-scenarios` metadata/dry-run. It did **not** delete a controller, run E2E, execute a live Krkn scenario, or observe standby takeover, exact-once reconciliation, backup completion, artifact state, or same-VM recovery. Those remain execution-time acceptance evidence, not claims made by this artifact.

## 8. Reproducibility

`chaos-trigger.sh` is the executable source for the read-only condition observer, dynamic Lease-holder resolution, exact Krkn selector, full-stage invocation, and same-VM incremental follow-up. Invoke it with `RUN_ID=<unique-run-id>` and the approved `KUBECONFIG_PATH`; use `bash chaos-trigger.sh` if executable mode is not preserved.
