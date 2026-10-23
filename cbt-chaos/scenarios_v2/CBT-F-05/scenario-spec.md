# CBT-F-05: Restart the node virtualization backup handler during a full CBT copy

- Jira: CBT-F-05; priority P1; active-operation fault; technical scenario `pod-scenarios`.
- Source requirements: `jira-issue.md`. Preparation follows `cbt-chaos-trigger-preparer-v2`, `krkn-scenario`, and `cbt-chaos/template/chaos-trigger-pattern-v2.md`.
- This bundle is a proposal, not approval, an executed attempt, or an injection/product verdict.

## Objective

Interrupt only the new CBT VM's node-local `virt-handler` during actual full-copy activity. The full may finish after automatic handler recovery or fail clearly because backup status was lost. Neither outcome may falsely advertise a checkpoint or accept a partial artifact. Preserve the original backup/PVC, observe multilevel cleanup for that exact destination, and, only when safe, demonstrate the required distinct same-VM follow-up and restore branch. A clean reproduction means a fresh VM/lifecycle/tracker/backups/destinations, never namespace cleanup or deletion of previous resources/evidence.

## Chaos Injection

`run.sh` first owns `make vm-setup RUN_ID="$LIFECYCLE_ID"`, then resolves the new VMI's actual node. Exactly one Running/Ready, non-deleting handler on that node must have the current `virt-handler` DaemonSet UID as controller owner; an ambiguous node-local population blocks. Its exact name, UID, node, DS identity/counts, and every sibling handler identity/readiness/restart count are saved before arming.

Use **native krkn command triggering**, not direct `oc delete` and not a broad pod selector. The pinned installed pod scenario supports an anchored exact-name regex and `NODE_NAMES`. `POD_LABEL` is deliberately empty: installed code ignores `NAME_PATTERN` when a pod label is supplied. Effective action:

```sh
podman run --rm --pull=never --user 0 --network host --security-opt label=disable \
  -v '<host-kubeconfig>:/home/krkn/.kube/config:ro' \
  -v '<approved-scenario-bundle>:/bundle:ro' \
  -v '<attempt-execution>:/evidence:rw' \
  -e KUBECONFIG=/home/krkn/.kube/config \
  -e 'NAMESPACE=^openshift-cnv$' -e 'POD_LABEL=' \
  -e "NAME_PATTERN=^${handler}$" -e "NODE_NAMES=[\"${node}\"]" \
  -e DISRUPTION_COUNT=1 -e EXECUTION=serial -e FORCE=false \
  -e KILL_TIMEOUT=60 -e EXPECTED_RECOVERY_TIME=300 \
  -e ITERATIONS=1 -e DAEMON_MODE=False -e WAIT_DURATION=1 \
  -e TELEMETRY_ENABLED=False -e 'REPORT_FORMATS=[]' \
  -e TRIGGERS_MODE=all_of -e TRIGGERS_TIMEOUT=1200 \
  -e TRIGGERS_INTERVAL=1 -e TRIGGERS_ON_TIMEOUT=fail \
  -e 'TRIGGER_COMMAND=timeout -k 1 25 bash /bundle/condition.sh --poll' \
  -e TRIGGER_EXPECTED_RC=0 --entrypoint /bin/bash \
  containers.krkn-chaos.dev/krkn-chaos/krkn-hub-multiarch@sha256:c83dcd027f3aa2815aa9f7fa4ab726ea3e9613a7a04ee212a95648fe330b6edc \
  /home/krkn/run.sh
```

The approved bundle's image-native `/home/krkn/run.sh` bypasses only the image's unrelated SSH bootstrap, not krkn or its trigger. The pinned image normally runs as user `krkn`; explicit container UID 0 permits writing the root-owned attempt mount without changing ownership of the checkout or evidence. No privileged container, host namespace PID attachment, or host filesystem write mount beyond attempt evidence is requested. Host networking and disabled SELinux relabeling are explicit approval scope. Credentials and scenario code remain read-only mounts.

The old direct-oc rationale was stale: setup can run separately, so exact targeting is known before full begins. Native Kubernetes condition triggering alone cannot express the required launcher log plus live QMP copy signal; the native command predicate can, with container-local tools/auth and a mounted evidence helper. No fault-action fallback exists.

### Installed metadata and known krkn semantics

Read-only preparation inspected `krknctl v0.14.2-beta`, available/describe/run-help, Podman 4.9.4-dev, the cached digest above, pod plugin source, `main_env.sh`, trigger-manager and command-trigger source. The image contains bash, timeout, python, oc/kubectl and jq. Authenticated read-only queries inside the image succeeded with the intended read-only kubeconfig mount. Supported CLI schema dry-run of the exact fault/trigger shape succeeded; it does not execute a scenario or access the cluster.

The native command has a 30-second per-evaluation limit; the helper command uses 25 seconds with one-second kill grace, individual API calls use 3-second request / 4-second process bounds. Native trigger timeout is explicitly `fail`, never installed default `skip` or `run_anyway`.

**Important:** the installed pod plugin's recovery wait/monitoring reuses the original exact name regex. A DaemonSet replacement normally has a different name, so krkn may report an internal exact-name recovery failure even when independent replacement/DS checks succeed: the selection wait uses the configured 60-second `timeout`, and the separate pod monitor has a 300-second recovery bound. This is an evidenced installation limitation, not a hidden retry or success override. Preserve complete krkn status/log; the entrypoint remains nonzero if krkn is nonzero. Analyst must distinguish this from a missed condition or failed action. No assertion of valid injection follows from script exit code.

## Injection Timing

Arm the scoped authenticated watches and native krkn process **after setup but before `make vm-backup`**. The readiness protocol is explicit files produced by authenticated children, not a startup sleep. Polling sleeps only pace bounded readiness/condition checks.

The helper must capture all of the following before returning trigger exit 0:

1. The exact new, run-labeled `VirtualMachineBackup` source tracker, name/UID, creation timestamp at or after the full-start marker, nonterminal conditions, and no deletion timestamp.
2. The setup VMI UID still Running on the selected node, and exactly one Ready launcher owned by that VMI, with its exact UID.
3. Launcher compute logs fetched with `--timestamps --since-time=<full-start UTC>` containing both exact `"backupName":"<original-full-name>"` and `"msg":"Backup started"`.
4. Read-only `virsh qemu-monitor-command <namespace>_<VM> '{"execute":"query-block-jobs"}'` showing a `type=backup,status=running` job with numeric `0 < offset < len`. Progressing=True or a stale start line alone is insufficient.
5. Immediately before releasing the native fault, the same Ready handler UID/node, same nonterminal backup UID, the new tracker's still-empty prior checkpoint, and a second live active-copy QMP result.

A missing/unsupported QMP signal, already completed copy, node/VMI/handler identity change, unavailable log, or expired predicate fails closed. No alternate weaker signal, delayed deletion, retry fault, or label broadening is allowed. Krkn's selection/action follows this predicate with a small unavoidable API scheduling gap; it offers no UID-precondition delete flag. Raw timestamps, native action logs, UID watch deletion and replacement evidence must be independently checked for that gap.

## Expected Behavior / Pass-Fail Criteria

All mandatory criteria remain required, with actual successful-full or terminal-failed-full branch recorded rather than assumed:

- **copy-window-identity:** exact backup/launcher/handler UID, fresh copy-start line, active QMP job and UTC decision timestamp precede the one action. Save argv, output, command status, old-UID watch DELETED event and replacement UID.
- **handler-auto-recovery:** the old handler UID disappears; exactly one different Ready handler UID controlled by the same DS appears on the VM node; original DS desired count is retained and ready count returns. Never manually restart a handler.
- **handler-sibling-exclusion:** snapshots retain every non-target handler UID, node, readiness and restart count. Raw label-scoped handler watch provides intermediate deletion/state evidence; independent Analyst checks for any extra deletion or replacement, not merely the final count. The direct fault is limited to one handler, but other VMs on that node can experience transient node-handler effects.
- **original-terminal-result:** the original full settles. Clear terminal failure must explain the backup-status-lost outcome; successful-looking Full must have a nonempty checkpoint and expected `rootdisk/vda` included volume. Classification reuses `scripts/common.sh:backup_done_reason_is_failure`: only `Backup has failed` prefix is failure; benign success warnings containing `Failed` are not. Require Done=True and a nonempty reason, but do not invent a literal success prefix. Record terminal, reason, identity, Full, checkpoint, included-volume, tracker-volume and checkpoint-name operands separately; reason wording cannot masquerade as tracker mismatch. An unexplained/false success is a product violation, not an acceptable branch.
- **tracker-checkpoint-before-followup:** capture raw tracker and recovered-launcher checkpoint tree/names before any follow-up. The new VM starts with no checkpoints. A failed full must not advance the prior empty tracker/checkpoint tree. A successful Full must set tracker latest to the reported full checkpoint, and its tree/names must agree. Record VM UID stability, VM Ready, VMI Running and CBT Enabled.
- **original-artifact-preserved:** preserve the original backup object, PVC UID and partial artifact. Do not restore from a failed partial image. Save PVC consumers; run bounded read-only `qemu-img info --output=json` through any already-existing accessible original-PVC consumer where available. If no consumer/tool remains, explicitly record metadata unavailable; the restore verifier alone does not prove qcow2 allocation/backing metadata. No new inspector pod is authorized by this bundle.
- **multilevel-post-terminal-cleanup:** for this new original backup PVC only, capture the initial VMI/launcher UID and exact backup-target path, immutable PVC UID → PV UID → CSI handle/imageName chain, matching VolumeAttachment, node volume-in-use/attached state, exact pod references, VMI utility/volumeStatus, actual original guest domain disks and QMP block/backend nodes, and exact original-launcher residual hotplug mount/matching RBD mapping in the existing node-local current/replacement handler. Observe from terminal through a fixed 300-second test observation window. This is a user-requested test bound, **not a claimed historic product SLA**. API detach/Bound storage alone cannot prove host cleanup. Unreadable probes are UNKNOWN. Preserve persistent residual/unsafe evidence and stop before restore/reuse; independent Analyst grades the named criterion and distinguishes observed residual from missing evidence.
- **successful-original-followup:** create a distinct incremental through the existing same-VM tracker, then run `make vm-cbt-verify` for checkpoint chain and full/incremental restore file-count, payload-byte and canonical-manifest SHA-256 verification.
- **failed-original-followup:** invoke existing same-VM `make vm-cbt-recover`, which allocates distinct `vm-recovery-full-<lifecycle>-rNNN` / `vm-recovery-pvc-<lifecycle>-rNNN`, forces Full through the same tracker and restore-verifies the saved baseline. Original failed backup/PVC are untouched.

Product FAIL includes false successful backup, failed-copy tracker/checkpoint advancement, unclear failure reason, handler/VM/CBT recovery failure, partial-artifact acceptance or incorrect backup/restore follow-up. Safe terminal failure can pass only with consistent original failure and successful distinct same-VM recovery. Blocked recovery is inconclusive. Missing mandatory evidence cannot become PASS. A stage nonzero alone is not a product FAIL.

Unsafe terminal, identity, tracker/checkpoint, included/tracker-volume or cleanup evidence blocks automated follow-up rather than restoring/reusing a partial or still-attached artifact. Preserve initial original backup/PVC snapshots and the cleanup result even when a later gate stops follow-up. Stopping is not a product verdict: Analyst classifies the observations and missing mandatory follow-up. No clean control lifecycle or third branch is silently added. `scenario-verdict.sh` launcher-interruption and EXP-06 bitmap check sets do not model this scenario; use named machine observations and independent Analyst, never an unrelated evaluator.

### Named evidence coverage; no generic evaluator fallback

The launcher is **only the signal source** (its UID, timestamped log and live QMP copy job). The deleted pod and independently observed old/replacement UIDs are **virt-handler**, not launcher. A launcher replacement is not required as handler-fault effect evidence. A default launcher-kill evaluator would conflate these identities, reject a legitimate successful original Full, or demand an unapproved clean-lifecycle leg; EXP-06 checks a different bitmap fault. Neither is invoked, and no absence-of-an-F05-set fallback is permitted.

All paths below are under attempt `execution/`, unless explicitly lifecycle-prefixed:

| Named criterion | Machine observations and raw references | Branch |
|---|---|---|
| copy-window-identity | `condition.json`, referenced `polls/*/{backup-before,handler-before,jobs-before,vmi,launchers}.json`, fresh `copy-lines.json`, `target.json`, action argv/log/status; separate launcher signal and handler target fields | Both |
| handler-auto-recovery | `effect.json`, `observations/*/{handlers,ds}.json`, exact old-UID handler watch DELETED event and different replacement UID | Both |
| handler-sibling-exclusion | `siblings-before.json`, baseline/final UID/readiness/restart comparison, `sibling_deletions_excluded` machine check and full scoped handler watch for independent transient-state review | Both |
| original-terminal-result | `original-terminal-observed.json`, later `original-terminal.json`, original UID events, full status and `product-before-followup.json` separate guard operands using shared terminal semantics | Both |
| tracker-checkpoint-before-followup | Empty `checkpoint-baseline.log`, raw condition tracker, `tracker-before-followup.json`, recovered checkpoint tree/names, `vm-recovered.json`, `vmi-recovered.json`, recorded VM UID equality and consistency gate | Both |
| original-artifact-preserved | `original-backup-initial.json`, `original-pvc.json` captured before later gates, bound/final backup/PVC snapshots and UID comparisons, scoped consumers, `qcow2-*.log` statuses or explicit metadata-unavailable record | Both |
| multilevel-post-terminal-cleanup | `cleanup-check.json`, `cleanup/identity.json`, `cleanup/terminal.json`, `cleanup/baseline/`, timestamped `cleanup/samples/*/` scoped reads/statuses and mount/PV/image correlation; API-only detach is separate from guest and host state | Both; unsafe/UNKNOWN bound blocks follow-up |
| successful-original-followup | Distinct same-VM incremental status, verify status, lifecycle `runs/<lifecycle>/` workload manifest, chain/restore fragments/report and full/prefix hash checks | Successful original only |
| failed-original-followup | Same-VM recover status, lifecycle `runs/<lifecycle>/run.json` recovery attempt with distinct Full/PVC, forced-Full checks and recovery baseline restore fragment/hash checks; failed original retained | Failed original only |

The script emits observations/guard outcomes, not `analysis.json` or a product verdict. Independent Analyst must validate raw injection timing/identity/effects and every applicable product criterion; a missing artifact remains missing evidence. No generic evaluator implementation or unrelated lifecycle experiment is added.

### Read-only cleanup protocol and interpretation

`cleanup-observer.py` is scenario-local and uses only Python standard-library code,
host `oc`, and existing-pod exec of read-only `virsh`, `bash`, `findmnt` and `cat`.
No inspector/debug pod, new mount, unmount, detach, delete, restart, reconciliation
or forced repair is permitted. Read-only preflight checks the host surface in an
existing Ready handler and permissions before setup; after setup, prepare checks
the actual node-local handler and records the original launcher/VMI plus disk/QMP
baseline and exact path. Runtime node selection remains live, never a past pod/node.

The collector is armed with a file readiness handoff **before** full starts.
It runs concurrently with both full and the native krkn process, not after the
native exact-original-name recovery monitor. Initial backup/PVC snapshots are
saved on first observation, independently of all later injection/product gates.
The first bound PVC is linked by claim UID/name/namespace to an exact PV UID and
CSI handle/imageName. Every later sample must retain that chain; replacement,
ambiguous identity or unreadable data cannot be accepted as detached.

Sampling is paced at 10 seconds while probes are fast; reads carry actual UTC
start/end times and individual process/decode/projection statuses. A successful
list/query returning no scoped references is absence; command/parse/identity
failure is UNKNOWN, not absence. Namespace pod, cluster attachment and node
queries are projected before persistence. No unrelated node mount table or
namespace pod collection is saved. Only this VM's guest disk/QMP state is read.
The exact mount is
`/pods/<original-launcher-UID>/volumes/kubernetes.io~empty-dir/hotplug-disks/<original-backup>-backup-target-pvc`.
The handler reads its existing `/proc/self/mountinfo` for that exact target and
uses scoped `findmnt` only when present. RBD sysfs `name` must exactly match the
PV imageName; `/sys/class/block/rbd<resolved-number>/dev` supplies dynamic
major:minor correlation with the mount. Never assume `/dev/rbd4` or match a PVC,
PV, image or launcher-name prefix. An exact-path mount whose device cannot be
correlated remains unsafe/UNKNOWN, never clear; raw correlation fields expose
whether the PV image link was actually established.

At first Done=True, record its transition timestamp and first observation time.
Continue the fixed 300-second post-terminal timeline even after early apparent
VMI detach. A final sample must **begin at or after** terminal +300 seconds;
bounded read latency can make its completion later, and actual sample/terminal
elapsed times are retained rather than claiming simultaneous observations.
Late first observation (>60 seconds), missing/invalid terminal timestamp,
incomplete bound coverage or unreadable required probes blocks follow-up.
`cleanup-check.json` records the window, actual elapsed times, last scoped raw
references, per-surface states and safe-stop decision, with no product verdict.
The window is a test bound, not a retrospective product cleanup deadline.

**Interpretation for independent Analyst:** VMI utility/volumeStatus and pod
references clearing establishes API-layer cleanup only. Guest domblklist plus
query-block/query-named-block-nodes distinguish actual guest device/backend
state. Stable exact mount + matching PV image/major:minor at bound (especially
across samples after API detach), matching attached VolumeAttachment or exact
node pin documents residual host/storage state; it is not a guest disk claim.
All required surfaces readable and clear at bound permits the declared follow-up.
Any positive residual, changed identity, failed probe or missing evidence safely
stops the bundle before follow-up/restore; preserve resources and let Analyst
grade the criterion, persistence evidence and remaining UNKNOWNs. No script
declares a product FAIL or PASS, and no separate no-chaos control is added.

### Preparation provenance

The closed iteration-2 `analysis.json` under
`runs/16-10-2026-13-08-38-vm-20261016130007-brave-valley-3af1-full-copy-iteration-2/`
identifies the harness-only success-prefix rejection despite consistent
tracker/checkpoint operands. This revision calls the existing workflow failure
predicate and records each safety operand independently; it does not change
native injection logic, timeout-fail behavior, images or historical analysis.
New cleanup coverage follows the separately retained scoped diagnosis under
repository `artifacts/CBT-F-05/attachment-check-20261016T141111Z/`; this revision
does not copy, rewrite or regrade those observations.



## Execution and Approval

### Inputs and evidence layout

`CHAOS_RUN_ID` is generated by Lead with `cbt-chaos/run-id.sh <exact-planned-VM> full-copy <next-iteration>` and is never a Kubernetes name. Separate `LIFECYCLE_ID` is a legal <=40-character lifecycle identity; VM is `vm-<lifecycle>`. Lead creates the fresh attempt directory and matching `run.json` **before** preflight/arming:

```json
{"scenario_id":"CBT-F-05","run_id":"<CHAOS_RUN_ID>","lifecycle_id":"<LIFECYCLE_ID>","vm_name":"vm-<LIFECYCLE_ID>"}
```

Commands from the intended checkout, with host-local authentication/guest key and a digest-pinned existing `RESTORE_HELPER_IMAGE` configured without committing paths or credentials:

```sh
CHAOS_RUN_ID=<generated-attempt> LIFECYCLE_ID=<short-id> bash cbt-chaos/scenarios_v2/CBT-F-05/run.sh --plan
CHAOS_RUN_ID=<generated-attempt> LIFECYCLE_ID=<short-id> bash cbt-chaos/scenarios_v2/CBT-F-05/run.sh --check-root
CHAOS_RUN_ID=<generated-attempt> LIFECYCLE_ID=<short-id> bash cbt-chaos/scenarios_v2/CBT-F-05/run.sh --preflight
# Only after Lead obtains explicit complete-bundle approval:
CHAOS_RUN_ID=<same-attempt> LIFECYCLE_ID=<same-short-id> bash cbt-chaos/scenarios_v2/CBT-F-05/run.sh --execute
```

`--plan` is offline/read-only; `--manifest` prints the full file list; `--check-root` exercises the offline identity/freshness boundary. `--preflight` makes only read-only cluster/runtime queries and writes fresh local `preflight/` evidence; it can precede execution in the same fresh attempt. It refuses to overwrite an earlier rehearsal. Execution refuses any existing `execution/`, prior action/effect/condition or confirmation output, any mismatching `run.json`, or an existing lifecycle directory. Never delete/rename evidence just to reuse an ID.

Attempt evidence: `cbt-chaos/scenarios_v2/CBT-F-05/runs/<CHAOS_RUN_ID>/{run.json,preflight/,execution/,injection-confirmation.json}`. Lead/Analyst add `analysis.json` and `run-report.md`. Lifecycle artifacts remain at repository `runs/<LIFECYCLE_ID>/` and are referenced, never copied. No historical evidence migration.

### Stage commands and sole ownership

All commands below are started, waited and exit-recorded only by `run.sh`. Lead must not concurrently start any of these stages. Each uses `make --no-print-directory` with explicit common arguments: `VM_OS=rhel9 MANIFEST_VARIANT=large-odf NAMESPACE=vm-cbt-demo GUEST_BASE_FILE_COUNT=8 GUEST_INCREMENTAL_FILE_COUNT=4 GUEST_INCREMENTAL_PASSES=1 GUEST_FILE_SIZE_MIN_MIB=1024 GUEST_FILE_SIZE_MAX_MIB=1024 GUEST_INVENTORY_VERIFY=full INCREMENTAL_PVC_SIZE=30Gi STAGE_SKIP_PREFLIGHT=false E2E_STAGE_WRAPPED=false STAGE_DRY_RUN=false`, plus host-local kubeconfig/guest key and pinned restore image. This prevents `.env` assignments from silently changing approved sizing.

| Stage | Exact target / selector | Bound | Start condition |
|---|---|---:|---|
| Preflight | `make preflight` | 180 s | Before all lifecycle work; automatic stage preflights remain enabled |
| Setup | `make vm-setup RUN_ID="$LIFECYCLE_ID"` | 2400 s | All runtime, auth, mount, cluster, storage and approval guards pass |
| Full | `make vm-backup RUN_ID="$LIFECYCLE_ID"` | 1500 s | Scoped watches + native trigger authenticated readiness |
| Success branch incremental | `make vm-cbt-backup RUN_ID="$LIFECYCLE_ID"` | 1800 s | Successful original, separate safe terminal/identity/checkpoint/volume operands and clear readable cleanup at bound |
| Success branch verify | `make vm-cbt-verify RUN_ID="$LIFECYCLE_ID"` | 2400 s | Incremental succeeded; exactly one verify, which already includes restore |
| Failure branch recovery | `make vm-cbt-recover RUN_ID="$LIFECYCLE_ID"` | 3000 s | Clear failed original, unchanged prior tracker/tree and safe cleanup at bound; distinct same-VM Full/PVC plus baseline restore |
| Read-only cleanup preflight/prepare | `python3 cleanup-observer.py --preflight <work>` / `--prepare <execution>` | 120 / 90 s | Preflight before setup; prepare after exact node/launcher known, before full |
| Read-only cleanup collector | `python3 cleanup-observer.py --observe <execution>` | 2520 s process; 2100 s terminal discovery; 300 s post-terminal window; each read 12 s | 40 s authenticated readiness handoff before full; runs concurrently with native process; status joined separately |

No `TYPE=all`, `make clean-all`, preflight bypass, concurrent stage owner, or automatic recovery after a failed incremental is authorized.

### Prerequisites, capacity and approval

The entrypoint checks required runtime binaries, cached pinned krkn image, supported scenario metadata and schema dry-run, authenticated container tools/helper/read-only kubeconfig mount/evidence-write mount, read/watch/delete/exec permissions, kubeconfig/context and cluster identity before setup. The host fingerprint, redacted context fingerprint, guest-key approval mode, image digests, IDs, scope/sizing and fixed timeouts are approved effective parameters. For a readable existing private/public pair, approval binds `guest_key.mode=existing-pair` and the public-half SHA-256 fingerprint. If the private or public half is absent, approval binds `guest_key.mode=setup-managed` with a null pre-setup fingerprint; `--preflight` does not generate or derive keys. An existing private key must be a readable regular file, and an existing public half paired with it must also be readable; unusable existing key files block rather than weakening the guard.

The existing `scripts/common.sh` `ensure_guest_key` remains the sole setup owner: it preserves an existing private key, derives its public half when missing, or generates a missing private key at the configured host-local `GUEST_KEY` path. After `make vm-setup`, `run.sh` records the resulting public fingerprint and setup/key-capture statuses in `execution/guest-key.json`. For setup-managed mode, that post-setup fingerprint is non-secret evidence only and does not change the approved parameter object. Preflight and execute therefore compare the same mode/fingerprint parameters up to setup; afterward, later approval checks compare the live public fingerprint to the captured post-setup value, and existing-pair mode also requires the originally approved fingerprint. No alternate host key or personal SSH-key fallback is used. Key paths and private-key contents are not added to approval parameters or `execution/guest-key.json`; the configured host-local path remains supplied only through the existing `GUEST_KEY` setting. No image build/pull or tool installation occurs mid-pipeline.

Read-only ODF guards require exact RBD storage class/pool, `ceph status` HEALTH_OK, and **at least 320 GiB logical pool `max_avail`**, not raw OSD free or an unbound PVC request. This covers the 80-GiB clone including overhead, original 80-GiB full, distinct recovery 80-GiB full or 30-GiB incremental, and reserve. Storage/PVC ResourceQuota requires a separately reviewed capacity calculation and currently blocks rather than guessing. Missing trustworthy Ceph metadata/tool access blocks before setup. Capacity is a point-in-time guard, not a reservation; concurrent consumers remain a limitation.

`bundle-files.txt` is the complete hash manifest: scenario entrypoint/helper/predicates, spec/Jira, invoked shared stage/transitive scripts and selected manifests, run-ID/watch helpers, Makefile, offline safety test, and host-local `.env` **digest only**. Never sync `.env`/keys/kubeconfig or dump their contents. Pinned image digest covers transitive image-native scripts/configs. `approval.json` begins `NOT_APPROVED`. Successful read-only preflight writes `preflight/approval-candidate.json` with hashes/effective parameters/cluster UID but never grants approval. Lead presents that whole candidate and effective fault/window/container scope, records explicit approver/time and APPROVED status only after approval, then uses the same bundle. File set, all hashes, parameters and cluster UID are checked again before setup; hashes/parameters are checked again before full and follow-up. Approval's own mutable record is not self-hashed.

Approval additionally binds `cleanup_observation_window_seconds=300`,
`cleanup_observation_interval_seconds=10`, process/terminal-discovery/read bounds
2520/2100/12 seconds, first-observation maximum lag 60 seconds, and exact
read-only API/guest/existing-handler mount/sysfs scope in `cleanup_scope`.
No new privileged pod, host write mount or cluster mutation is added by this
coverage. New helper/test dependencies are in the hash manifest. Changed
window, scope, file or effective parameter requires fresh explicit approval.


### Bounds, safe stop and status handling

Whole pipeline budget 10800 s; stages and collector outer timeout are capped by remaining budget. Native startup readiness 120 s; trigger 1200 s; native process 1620 s; independent handler effect 600 s; VM/CBT/terminal readiness 600 s; scoped watches 10800 s. Cleanup observation has the separate bounds above, and its first sample is never postponed for native process join. Every command read has saved status/timestamps, and failed decode/projection is UNKNOWN. No early CLEAR shortcut: final sample must start at/after the fixed 300-second test bound; actual read latency/elapsed is recorded. Logging uses direct files, not tee. Every stage/action/watch/observer status remains independent; evidence-write failure stops safely. Full child nonzero is retained, never itself a branch/product verdict. Native exact-name monitoring nonzero remains preserved and makes orchestration nonzero even if independent recovery and the declared follow-up succeed.

On interruption/timeout, stop only invocation-owned timeout children, watches and exact owned krkn container. Automatic DaemonSet reconciliation is the only cluster rollback. Do not recreate/delete handlers, stop/restart the VM, clean backup/PVCs, or remove partial artifacts. Lead preserves every terminal attempt, including BLOCKED/INVALID, and independent Analyst owns injection/product classification. No preferred verdict is inherited.
