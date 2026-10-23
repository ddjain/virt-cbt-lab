# Experiment intent (EXP-5): the completion-boundary "VMI backup status was lost" transient — event-only misreport or condition flip?

> **PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW.** This is a chaos experiment
> intent derived from the CBT campaign, written so an engineer who has never seen
> this cluster can reproduce and triage it. It is **not** a filed ticket; no Jira
> key exists for it and none is invented. Historical observations are cited as
> historical (with their run label); this attempt's outcome is decided by the
> independent Analyst from this attempt's raw evidence and is deliberately not
> asserted here. No credentials, private hostnames, absolute host paths or
> cleanup commands are included.

## What this is, in one paragraph

Every push-mode changed-block-tracking (CBT) backup of a Red Hat Enterprise
Linux 9 (RHEL 9) virtual machine **completes successfully** yet often emits a
`Warning` event saying `Backup has failed: VMI backup status was lost` at the
same instant. An event like that is what monitoring, alerting and GitOps
consumers act on, so a healthy backup looks like a failed one. This experiment
freezes one internal component (`virt-controller`, the component that writes the
backup's status) with `SIGSTOP` for a few seconds exactly when the backup tears
down its temporary destination volume, then resumes it with `SIGCONT`, and
records — at sub-second resolution — whether the false "failed" signal stays a
mere **event** (a reporting annoyance) or whether it ever **overwrites the
backup's terminal success condition** (a state-correctness defect that
change-detecting consumers would propagate).

**When → then → expected**

- **When** a fresh RHEL 9 virtual machine's full push-mode backup
  (`VirtualMachineBackup`, group `backup.kubevirt.io/v1alpha1`) enters its
  completion boundary — the condition `Progressing=True` with reason
  `detaching backup target pvc from vmi <vmi>` (the temporary destination volume
  is being unplugged) — **and** the disruption **EXP-5 (chaos bundle
  `cbt-chaos/scenarios_v2/CBT-EXP-05/run.sh`; not a krknctl scenario, see
  "Why not a krkn scenario" below)** is applied: the container-init host PID of
  the `virt-controller` **leader** replica (resolved from the
  `virt-controller` `Lease` holder, inside its privileged helper pod, on the
  container's host PID namespace) receives `kill -STOP`, state `T` is verified,
  the process is held 3 s (leg 1) / 2 s (leg 2), then `kill -CONT` is issued and
  state `S`/`R` is verified.
- **Then (current behaviour):** the backup still reaches `Done=True` with reason
  `Successfully completed VirtualMachineBackup`, the guest data is byte-identical
  after restore, and — in a probabilistic share of runs — a `Warning` event
  `VirtualMachineBackupFailed` with message `Backup has failed: VMI backup status
  was lost` is written for the same backup object at (or after) that success
  instant.
- **Expected behaviour:** a backup whose terminal condition is `Done=True` /
  `Successfully completed VirtualMachineBackup` must not be reported as failed to
  an event-based consumer; and no reconciliation may rewrite the terminal
  condition after it is set. Either (a) the transient is event-only and
  suppressible when the backup is already terminal, or (b) the terminal
  condition is being overwritten and the backup's reported state is untrustworthy.
  This experiment decides which.

## At a glance

| Field | Value |
|---|---|
| Issue type | Improvement (observability / status-reporting gap). **Becomes a Bug** (status truthfulness, data protection) if this experiment records a condition flip instead of an event-only transient. |
| Priority (proposed) | Medium for the event-only case (monitoring false alarms on most successful RHEL backups); the condition-flip case is High and should be re-triaged on evidence |
| Severity class | observability / status truthfulness (event-only case); availability + status truthfulness if a flip persists |
| Owning component (suspected) | KubeVirt backup completion path (not proven; the freezes below did not reproduce the transient historically) — **suspected** |
| Component(s) proven involved | The backup CR's status writer (`virt-controller` backup controller) and the VM-side backup status removal (`virt-handler`/`virt-launcher` path) are both in the observed path |
| Reproducibility | The *event* is probabilistic on RHEL 9 (historically 7 of 9 campaign runs ≈ 78 %); the *condition flip* has never been observed (0 of 9+) |
| Status / confidence | Contract question + unproven cause. Certain: the event text, the terminal condition text, and that the event can appear with a successful backup (ResourceVersion ordering). Inferred: informer-cache propagation delay |
| Blast radius | One VM's backup reporting per occurrence; the freeze itself targets one controller replica for 2–3 s while the standby replica keeps serving |
| Data at risk? | **No** in the event-only case (the backup and the restored data are complete). A condition flip would misreport, not delete, data — but consumers acting on the condition could treat a good backup as unusable |
| Related scenario / execution | Scenario `CBT-EXP-05`. Historical: run label `20261014-exp05-r01` (legs 0/1/2 + the archived harness-invalid leg that captured the transient organically), campaign characterization in `docs/findings/finding-3-ghost-event-observability.md`. This bundle's own attempts are recorded under `cbt-chaos/scenarios_v2/CBT-EXP-05/runs/<attempt-id>/`. |
| Affected versions | OpenShift 4.22.15 (Kubernetes 1.35.6) with OpenShift Virtualization 4.22.12; measured on RHEL 9 guests. See **Environment** for identifiers |

## Context (for an engineer new to this area)

- **What the feature does.** A push-mode CBT backup of a running VM works in
  three steps: (1) a *checkpoint* is created in the guest's QEMU and a *dirty
  bitmap* (the per-disk change-tracking map) is armed; (2) a temporary
  *destination volume* (a PVC) is hot-plugged into the running VM and the changed
  blocks are copied into it; (3) the destination is unplugged, the checkpoint and
  the chain's latest-checkpoint bookmark on the `VirtualMachineBackupTracker`
  object are updated, and the backup's status conditions are set to a terminal
  state. The related objects are the `VirtualMachineBackup` CR (per-backup, its
  `status.conditions[]` carry `Progressing` and `Done`), the tracker, and the
  per-VM `VirtualMachineInstance` (VMI), whose `status.volumeStatus[]` shows the
  hot-plugged destination while it is attached.
- **Where the failure sits.** The false signal is a Kubernetes **Event**, not a
  status field: kind `Event`, `reason: VirtualMachineBackupFailed`,
  `message: Backup has failed: VMI backup status was lost`, with
  `involvedObject.kind: VirtualMachineBackup` naming the successful backup. The
  authoritative state lives in that same backup's conditions.
- **Observed surface vs. origin.** The surface is the *event stream*; the origin
  is inside the backup controller's reconcile of the completion boundary. This
  experiment deliberately freezes that controller at the boundary to see whether a
  reconcile that spans the boundary — with a stale in-memory view of the VM's
  backup status — is what emits the signal.
- **Why it matters.** Consumers that alert on `VirtualMachineBackupFailed` (or on
  the `Backup has failed` reason prefix) receive false pages for healthy backups,
  which trains operators to ignore the alert. The same event is also the *only*
  trace of genuine copy failures in one documented case, so it cannot simply be
  dropped by consumers either.

### Experiment criteria (what the run must answer)

- **C1 (primary):** the emission mode of the transient — **event-only** vs
  **condition flip** — established from the `VirtualMachineBackup` conditions'
  `resourceVersion` sequence captured by a watch stream (sub-second), any
  post-`Done` condition write, and the controller's own log line.
- **C2:** self-healing behaviour after the terminal write — how many subsequent
  reconciles, if any, touch the conditions.
- **C3 (control):** the backup reaches `Done=True`/`Successfully completed
  VirtualMachineBackup`; the restore verification of the incremental chain is
  byte-clean; the controller pods' `restartCount` is unchanged across the hold
  (proving a *freeze*, not a kill/restart); and the frozen process is verified
  `T` during the hold and `S`/`R` after resume.

### Why not a krkn scenario (disruption disclosure)

The fault is a **reversible, sub-second-triggered process freeze of one lease
leader's host PID**, which the installed chaos tooling cannot express. Verified
read-only on the execution host (krknctl v0.14.2-beta):

- `krknctl list available` enumerates no process-freeze / SIGSTOP / SIGCONT
  scenario; `container-scenarios` is the closest and its `--action` is a *kill
  signal* delivered through the container runtime against targets chosen by
  `--namespace` + `--label-selector` (an arbitrary replica of a 2-replica
  controller), with no resume action, no `/proc` state verification and no
  fail-closed rollback.
- The trigger framework's finest granularity is a **polled** condition
  (`--triggers-interval`, default 5 s) and its on-timeout default is
  **`skip`** (i.e. proceed without the fault) — it cannot express a condition
  *transition* that lasts a fraction of a second.
- Therefore the approved mechanism is: a pre-created privileged helper pod
  (host PID namespace, host root mounted) plus
  `oc exec … chroot /host kill -STOP/-CONT <leader host pid>`, with the edge
  detected from a watch stream. This is recorded in the scenario's
  `scenario-spec.md` and in the bundle's `jira-issue.md`/handoff.

## Environment (measured, not assumed)

| Layer | Component | Version / identifier | How obtained |
|---|---|---|---|
| Platform | OpenShift Container Platform (client and server) | 4.22.15 | `oc version` |
| Platform | Kubernetes API | v1.35.6 | `oc version` |
| Nodes | OS image, kernel, container runtime | Red Hat Enterprise Linux CoreOS 9.8 (kernel 5.14.0-687.48.1.el9_8) with `cri-o://1.35.8-11.rhaos4.22.giteaf45bc.el9` | `oc get node <node> -o json` |
| Nodes | topology in scope | 2 `virt-controller` replicas on 2 different worker nodes; the leader node is resolved per leg | `oc get pods -n openshift-cnv -l kubevirt.io=virt-controller` |
| Virtualization | CNV / HCO | OpenShift Virtualization 4.22.12 (`app.kubernetes.io/version`) | controller pod labels |
| Virtualization | kubevirt observed version | `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].status.observedKubeVirtVersion}'` |
| Virtualization | virt-controller container | exactly one container named `virt-controller` per replica; `restartCount: 0` at preparation time | `oc get pod -o json` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` | object `apiVersion` fields |
| Storage (in use) | StorageClass for VM root disk, full and incremental backup destinations | `cbt-demo-hpp` (HostPath provisioner; `PV.spec.hostPath`) | `oc get sc cbt-demo-hpp`; manifest `manifests/*-large.yaml` for the RHEL 9 `default` variant |
| Guest | OS / workload | RHEL 9, 1000 baseline files of 15–20 MiB plus 4 incremental files per pass | lifecycle `runs/<lifecycle-id>/workload-manifest.json` |
| Harness (internal only) | chaos tooling present but not used for the fault | `krknctl v0.14.2-beta` | `krknctl --version` |

Load-bearing note: the destination PVC on this profile is a **HostPath** volume,
so there is no CSI handle, `VolumeAttachment` or node `volumesInUse` pin to
correlate; the VM-side detach surface is `VMI.status.volumeStatus[].name` equal to
`<backup-name>-backup-target-pvc`. On ODF/Ceph-RBD profiles the same scenario must
additionally correlate PVC UID → PV → CSI handle/image → `VolumeAttachment` →
node pins.

## Reproducibility

- **Classification:** the *event* is probabilistic on RHEL 9 — historically 7 of
  9 campaign runs (≈ 78 %), 0 of 2 runs under a controller freeze, 0 of 1 run on
  Windows. A condition flip has never been observed. The freeze mechanism itself
  is deterministic when the process state is verified.
- **Attempts (historical, for context only):** run `20261014-exp05-r01` (leg 0
  routine; legs 1–2 frozen) plus one archived harness-invalid leg that fired the
  transient organically. Those observations are leads, not this attempt's result.
- **Stability:** the event text, the terminal condition text, and the detach
  condition reason are stable strings; the completion boundary is *short* —
  in the historical watch stream the object moved from
  `Progressing=True/detaching …` to `Progressing=False/Done=True` within about 15
  object resourceVersions, which is why the trigger must be watch-based rather
  than polled.
- **Preconditions:** CBT enabled on the VM; a fresh VM with a completed full
  backup; the `virt-controller` lease resolvable; two running controller replicas
  (a standby keeps serving while the leader is frozen); the guest key and restore
  helper image configured on the execution host.
- **Second entry path:** the same event has been seen on abort/cleanup paths and
  as the sole signal of a real copy failure (ENOSPC), i.e. the surface is shared
  by at least three distinct situations — which is exactly why distinguishing
  them matters.

## Steps to reproduce (exact commands and injection timing)

Prerequisites: a dedicated disposable cluster, `oc` authenticated with a
kubeconfig **that is never printed or committed**, the workflow checkout present
on the execution host, and the bundle created by this experiment
(`cbt-chaos/scenarios_v2/CBT-EXP-05/`). Replace `<ns>`, `<lifecycle-id>`,
`<vm>`, `<backup>`, `<node>` with your own values; the bundle derives all of them
from `<lifecycle-id>` via the repository's own name helper.

**Step 1 — get the plan (no cluster contact).** Run the entrypoint's read-only
plan and record the lifecycle base it will use; the chaos attempt ID must embed
one of the planned VM names:

```sh
LIFECYCLE_BASE=<fresh-40-char-or-less-id> bash cbt-chaos/scenarios_v2/CBT-EXP-05/run.sh --plan
```

What you must see: `legs[]` with `lifecycle_id`, `vm`, `full_backup`,
`backup_pvc`, `tracker` for legs 0, 1 and 2, and the full `make e2e TYPE=all …`
command per leg.

**Step 2 — create the attempt identity and root.** Generate the attempt ID that
embeds the injected leg's VM name, then create the attempt root with a `run.json`
recording `scenario_id`, `run_id`, `vm_name`, `note` and `iteration`:

```sh
./cbt-chaos/run-id.sh <vm-of-leg-1> detach-edge 1     # prints the attempt ID
CHAOS_RUN_ID=<printed-id> CHAOS_EVIDENCE_ROOT=<attempt-root> \
  bash cbt-chaos/scenarios_v2/CBT-EXP-05/run.sh --check-root
```

What you must see: `check-root OK`, and refusal (exit 2) if the root already
contains action/effect outputs or a `run.json` that records a previous execution.

**Step 3 — verify the injection target identity before any backup exists.**
Resolve the leader from the lease, never from a remembered pod name:

```sh
oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}'
oc get pod <leader-pod> -n openshift-cnv -o jsonpath='{.metadata.uid}{"\n"}{.spec.nodeName}{"\n"}'
oc get pods -n openshift-cnv -l kubevirt.io=virt-controller \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
```

What you must see: exactly one lease holder, its pod UID and node, exactly one
container named `virt-controller` in that pod, and `RESTARTS` equal for both
replicas (this is the C3 baseline).

**Step 4 — preflight (before any VM is created).** The entrypoint's preflight
checks tools, kubeconfig, namespace, storage class, API permissions, the checkout
lock, the leader identity, and performs a **bounded helper-pod smoke check**
(create the privileged helper pod on the leader's node, resolve the leader
container's host PID with UID evidence, read `/proc/<pid>/status`, delete the
pod). Run it inside an authorized slot, normally as part of Step 6.

What you must see: `preflight passed` and `preflight.json` with
`controller.leader_proc_state_before_injection` equal to `S` or `R`.

**Step 5 — observation must be armed before the pipeline that opens the window.**
For each leg the entrypoint arms read-only streams (exact-name watches of the
leg's `VirtualMachineBackup`, tracker, VM and VMI; a reconnecting namespace events
watch; a 5 s controller pod/lease poll; a 10 s storage-chain poll) and captures
baselines proving the leg's objects did not pre-exist:

```sh
bash cbt-chaos/scenarios_v2/CBT-EXP-05/observe-arm.sh arm <leg> <lifecycle-id> <attempt-root>
```

What you must see: `observer-leg<leg>/armed.json` and one ready/alive marker per
stream; the baselines under `observer-leg<leg>/*.baseline.json` must record
absence for the leg's backup, tracker, PVC, VM and VMI.

**Step 6 — run the three legs (this is the injection).** One command owns the
whole sequence (`preflight → leg0 → leg1 → leg2 → teardown`):

```sh
CHAOS_RUN_ID=<attempt-id> CHAOS_EVIDENCE_ROOT=<attempt-root> \
  bash cbt-chaos/scenarios_v2/CBT-EXP-05/run.sh
```

Per leg the entrypoint runs, from the checkout root:

```sh
make --no-print-directory e2e TYPE=all NAME=<lifecycle-id> VM_OS=rhel9 \
  MANIFEST_VARIANT=default NAMESPACE=vm-cbt-demo \
  GUEST_BASE_FILE_COUNT=1000 GUEST_INCREMENTAL_FILE_COUNT=4 GUEST_INCREMENTAL_PASSES=1 \
  GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20 \
  KUBECONFIG_PATH=<host-local-kubeconfig> GUEST_KEY=<guest-key> RESTORE_HELPER_IMAGE=<pinned-image>
```

Leg 0 is the no-injection control. For legs 1 and 2 a background watcher is armed
*before* that command; it resolves the target (Step 3 identity), waits for the
leg's `VirtualMachineBackup` to exist, and then drives the freeze:

1. **Edge detection (watch-based).** The watcher reads
   `oc get vmbackup <backup> -n <ns> --watch --output-watch-events -o json` and
   looks for the first object whose `Progressing` condition has reason
   `detaching backup target pvc from vmi <vmi>`. It fires only for the leg's own
   VMI; a detach reason naming any other VMI aborts the leg. If the watch stream
   ends before the edge, a 1 s poll fallback runs for a bounded time and records
   which mode fired; if the backup is already `Done=True`, the leg is recorded as
   `missed-backup-already-terminal` and **no** signal is sent.
2. **Action.** `oc exec` into the pre-created helper pod →
   `chroot /host kill -STOP <leader-container-host-pid>` (Sub-second, because the
   pod already exists; the pod is created before the pipeline, never inside the
   window).
3. **Fail-closed verification.** Within ~1 s the watcher re-reads
   `/proc/<pid>/status`; if the state is not `T` it immediately sends `SIGCONT`
   and aborts the leg as `fail-closed-not-stopped`. It also re-reads the lease:
   if the holder's pod UID changed at the edge, it sends `SIGCONT` immediately and
   aborts the leg as `fail-closed-leader-changed` rather than holding a
   non-leader.
4. **Hold and resume.** Hold 3 s (leg 1) / 2 s (leg 2) — the kubelet liveness
   budget for this component is far larger (order of a minute), so the freeze
   cannot trip a probe — then `kill -CONT` and verify state `S`/`R`.
5. **Recovery is unconditional.** Every exit path (including interrupts) resumes a
   process that is still stopped, and the helper pod is deleted at teardown. Only
   this run's helper pod and this run's observer processes are ever touched.

What you must see per injected leg in `leg<N>-inject-result.txt`: `edge_detect_mode`,
`edge_resource_version`, `state_during_hold=T`, `sigcont_utc`,
`state_after_sigcont=S|R`, `injection_result=confirmed`; and in the leg's
status file that the controller `restartCount` did not increase.

**Step 7 — observe, read-only (the defect, if present).** For each leg the
entrypoint captures the terminal backup object, the namespace event snapshot, the
leader's controller log (`--since=10m` for leg 0, `--since=15m` for legs 1–2), the
lifecycle verifier's `summary.json`/`report.json` (referenced, never copied), and
the condition/event/storage-chain stream summaries. The decisive read-only
inspection is:

```sh
jq -r '(.object // .) | [.metadata.resourceVersion,
  ([.status.conditions[]|select(.type=="Progressing")|.status][0]),
  ([.status.conditions[]|select(.type=="Progressing")|.reason][0]),
  ([.status.conditions[]|select(.type=="Done")|.status][0])] | @tsv' \
  <attempt-root>/observer-leg1/full-backup-leg1.jsonl
jq -c 'select((.object.message // "")|test("VMI backup status was lost"))
  | {rv:.object.metadata.resourceVersion, ts:(.object.lastTimestamp // .object.eventTime),
     involved:.object.involvedObject.uid, message:.object.message}' \
  <attempt-root>/observer-leg1/events-backup-leg1.jsonl
```

Interpretation: compare the event's `resourceVersion`/timestamp with the backup's
terminal `Done=True` write. If the event lands at/after the terminal write and no
later condition write changes `Done` away from `True`, the transient is
**event-only**. If any post-terminal condition write leaves
`Successfully completed VirtualMachineBackup`, that is a **condition flip** and
this experiment is reporting a correctness defect.

**Step 8 — clean up.** The entrypoint deletes only its helper pod and stops only
its observers. Do **not** delete the VMs, backups or PVCs while triaging: they are
the evidence. Never run repository-wide cleanup commands inside a chaos attempt.

## Current behaviour (observed)

Historical observation (run `20261014-exp05-r01`, recorded in
`docs/findings/finding-3-ghost-event-observability.md`) — an **independent
artifact observation**, not this attempt's:

- On a routine successful backup, the event `VirtualMachineBackupFailed`
  (`message: Backup has failed: VMI backup status was lost`) was written with
  `resourceVersion` immediately *after* the backup's terminal `Done=True` /
  `Successfully completed VirtualMachineBackup` write, and the backup's conditions
  never left `Successfully completed VirtualMachineBackup` (`Progressing=False`,
  `Done=True`) afterwards.
- Under a controller freeze at the completion boundary in the same run, the event
  did not fire (0 of 2 legs) while both backups still completed successfully with
  byte-identical restores and `restartCount` unchanged.
- The terminal condition text observed in those runs was exactly
  `Successfully completed VirtualMachineBackup` for both `Progressing=False` and
  `Done=True`, and the detach boundary was exactly
  `Progressing=True` / `reason: detaching backup target pvc from vmi <vmi>`.
- Inference (labelled): the transient is consistent with an informer-cache
  propagation delay between the VM-side backup-status removal and the
  controller's view around the completion transition. The exact emission line was
  never captured during an organic fire.

## Expected behaviour (contract)

- A backup whose terminal `Done` condition is `True` with reason
  `Successfully completed VirtualMachineBackup` is reported as successful to
  **every** consumer of that backup — including consumers of its events. A
  failure-shaped event must not be emitted for an already-terminal successful
  backup.
- Once a backup is terminal, no reconciliation may rewrite its terminal condition
  (a `resourceVersion` change that leaves the terminal reason is acceptable and
  expected for metadata/finalizer bookkeeping; a change that removes the success
  reason is the defect).
- Acceptance check a reviewer can run: after the attempt, on each leg's
  `observer-leg<N>/full-backup-leg<N>.jsonl` (and any `.reconnect-*` continuation)
  the terminal condition write must be the **last** condition-changing write, and
  any `VMI backup status was lost` event for that backup's UID must carry a
  `resourceVersion`/timestamp at or after it; combined with a clean restore
  verification in `runs/<lifecycle-id>/summary.json`.

## Impact, workaround and data safety

- **Functions lost:** none in the event-only case; the cost is operator trust and
  alert noise (historically most RHEL backups). In the flip case, consumers that
  read the backup's condition state could treat a good backup as failed or
  unfinished.
- **Blast radius:** one VM's backup reporting per occurrence. The experiment's own
  freeze affects one `virt-controller` replica for 2–3 s while the standby replica
  continues to serve.
- **Data safety:** the backup destination and the restored data are verified
  byte-for-byte by the workflow's restore verification; the freeze pauses a
  reconcile, it does not abort or corrupt a copy. Say it explicitly: **no data
  path is expected to be at risk**, and a restore mismatch would be reported as
  such rather than attributed to the transient.
- **Workaround / operator runbook:** alert on the backup's terminal **condition
  and reason** rather than on the failure event; if events must be used, exclude
  the exact message `Backup has failed: VMI backup status was lost` when the same
  backup is already `Done=True`. This removes false alarms but does **not** fix the
  shared surface: the same event is the only trace of some genuine copy failures,
  so it should not be blanket-ignored either.
- **Frequency:** the event fires on a probabilistic share of RHEL 9 backups
  (historically ≈ 78 %); it did not fire on the one Windows run.
- **Unknowns:** the emission code path is not proven; the freeze mechanism did not
  reproduce the event historically, so absence of the event in a frozen leg is not
  evidence about the mechanism (it is a data point about the freeze).

## Evidence

- **Scenario spec (authoritative design):** `cbt-chaos/scenarios_v2/CBT-EXP-05/scenario-spec.md`.
- **This experiment's executable bundle:** `run.sh` (entrypoint: preflight, three
  legs, teardown, injection watcher), `observe-arm.sh` (pre-arm observers + stop),
  plus this ticket. Attempt evidence is written to
  `cbt-chaos/scenarios_v2/CBT-EXP-05/runs/<attempt-id>/`; lifecycle evidence stays
  in `runs/<lifecycle-id>/` and is referenced in place.
- **Historical characterization (independent artifact observations):**
  `docs/findings/finding-3-ghost-event-observability.md` (event-only RV ordering,
  7/9 firing rate, sole-signal-on-failure role) and the archived run under
  `artifacts/CBT-EXP-05/runs/20261014-exp05-r01/` including the verified
  `harness-variants/chaos-trigger-r01c.sh`.
- **Related failure families this bundle probes for:** the livelock/no-terminal-
  resolution family (`docs/findings/finding-1-backup-cr-livelock.md`) — a backup
  that never terminates and keeps its destination hot-plugged; the
  terminal-success residual attachment family
  (`cbt-chaos/scenarios_v2/CBT-F-05/bugs/backup-destination-volume-remains-mounted-after-terminal-success.md`);
  and the cancellation/failure reason conflation
  (`docs/findings/finding-4-cancellation-reason-conflation.md`) — the same
  `VirtualMachineBackupFailed` reason carries cancellation, real failure and this
  ghost message, so message text must be matched, not the reason alone.
- **Raw evidence to grade (per leg):** `leg<N>-inject-result.txt`,
  `leg<N>-target.json` (+ `target-probe-leg<N>/candidates.jsonl`),
  `leg<N>-edge-watch.jsonl`, `leg<N>-inject-status.json`,
  `observer-leg<N>/*.jsonl` + `*.baseline.json`, `leg<N>-final-backup.yaml`,
  `leg<N>-events.txt`, `leg<N>-controller.log`,
  `leg<N>-condition-stream-summary.json`, `leg<N>-event-stream-summary.json`,
  `leg<N>-storage-chain-summary.json`, `leg<N>-machine-checks.json`,
  `leg<N>-restore-verify.json`, `leg<N>-statuses.json`, `statuses.json`,
  `driver.log`, `trigger.log`, `injection-confirmation.json`,
  `runs/<lifecycle-id>/{summary.json,report.json}`.

## Negative results and what would falsify this ticket

- **Refuted hypotheses (historical):** the transient is *not* simply "the
  controller process was busy at the boundary" — a verified 2–6 s freeze of the
  leader at the completion boundary produced no event in 2 of 2 legs, and pod
  deletion (a kill) was shown in a sibling experiment not to enter the sub-second
  window.
- **Falsifier (this experiment):** a leg in which the event fires and the backup's
  condition stream then shows a post-terminal write that removes the terminal
  success reason, or a persistent non-success terminal state, or a restore
  mismatch. Conversely, if every leg shows the terminal write as the last
  condition write with the event at/after it and clean restores, the event-only
  characterization is strengthened, not refuted.
- **Not a falsifier:** absence of the event in a frozen leg. It is probabilistic;
  a leg without it is one observation.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiment for each:** (a) informer
  propagation delay — needs a controller log line at the emission instant *while
  the event fires*, best obtained from a routine leg with a wide log window;
  (b) the RHEL hotplug/fsfreeze path (the event was absent on Windows 0/1) — one
  Windows leg would test it; (c) an ordering race between the destination-volume
  detach and the VM-side backup-status removal — tested by the freeze in this
  experiment, which historically did not reproduce it.
- **Triage questions:** is the derivative event meant to be suppressed when the
  backup is already terminal? Should the abort/cancellation path use a distinct
  reason (its current wording includes the `Backup has failed` prefix)? Should
  genuine copy errors be surfaced on the backup CR instead of only as an event?
- **Environment quirks a reproducer must know:** (1) the completion boundary is
  short (about 15 object resourceVersions historically) — a polling observer or a
  polled trigger will miss it; (2) `Progressing=True` alone is *not* the edge: the
  same condition is also `True` with reason `Backup is in progress`, and is
  `False` with reason `attaching backup target pvc …` before the copy; (3) on the
  RHEL 9 `default` profile the destination is HostPath, so CSI/attachment probes
  are not applicable and the VM-side detach surface is
  `VMI.status.volumeStatus[].name`; (4) the controller runs 2 replicas — always
  resolve the **lease holder** and verify its pod UID, never a remembered pod
  name; (5) `oc exec` into the helper pod must go through
  `chroot /host` because `crictl` lives on the node, not in the helper image.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys
- [x] No private hostnames or absolute host paths (node names, kubeconfig and
      guest-key paths are placeholders; the attempt root is a placeholder)
- [x] No broad selectors (exact lease holder / exact leg-scoped object names only)
- [x] No destructive commands other than the documented, scoped teardown of this
      run's own helper pod (no VM/backup/PVC deletion, no repository-wide cleanup)
- [x] Commands are the ones actually validated (`--plan`, `--check-root`,
      `--self-test-detector`, the `STAGE_DRY_RUN=true make e2e` rehearsal and the
      read-only cluster queries); observational commands are labelled as such
