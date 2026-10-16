# CBT product-flow analysis — CBT-I-01 — run `20261016-cbt-i-01-r01` (VMI restart between the full and the incremental)

> Scope: what the **CBT product** (KubeVirt/OpenShift Virtualization
> `VirtualMachineBackup` + `VirtualMachineBackupTracker` + the launcher-side checkpoint/bitmap
> machinery) did when the VMI was deleted after the full backup's checkpoint was recorded and
> before the incremental pass began, judged only from this run's closed evidence pack. Every
> fact below is cited by artifact + field. Harness/sequence events (the deterministic evaluator
> returning `INVALID`, the empty `trigger/`, a ledger/`state.json` that was not advanced past
> `preflight_go` when the observer froze, the non-monotonic pod `deletionTimestamp`, launcher
> **startup log noise**) are classified as such in §4 and are **excluded from the product
> claim**. All times UTC, 2026-10-16. Nothing here is a defect claim; hypotheses and inferences
> are labelled `[INFERENCE]`. Read-only wrt the run directory — no cluster access was used.
>
> Sources used (run root = `cbt-chaos/scenarios_v2/CBT-I-01/runs/20261016-cbt-i-01-r01/`):
> `observer/FINAL`, `observer/finding.md`, `observer/PRESERVED`,
> `observer/watches/{vmbackup-run,vmi,pods-vm,tracker}.jsonl`, `observer/_poll-phase2{,-prefilter}.jsonl`,
> `checkers/evidence-sufficiency.json`, `checkers/injection-validity.json`, `reports/test-run-{report,result}.md`,
> `full-backup.yaml`, `incremental-backup.yaml`, `tracker.yaml`, `vmi-recreated.yaml`,
> `trigger.log`, `injection.log`, `preflight.json`, `evidence-index.json`; lifecycle artifacts
> `runs/20261016-cbt-i-01-r01/{run.json,summary.json,report.json,logs/virt-launcher.log,logs/workflow.log,fragments/restore-test.json}`;
> `scenario-spec.md` §2/§4/§5/§7; cross-run: `cbt-chaos/scenarios_v2/CBT-F-01/runs/20261016-cbt-f-01-r03/observer/watches/launcher-compute.log`,
> `cbt-chaos/scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r03-product-flow.md`,
> `cbt-chaos/scenarios_v2/CBT-F-01/analysis/20261016-cbt-f-01-r04-product-flow.md`,
> `docs/agent-plan-incorrect-points.md` (HV1), `docs/agent-workflow-audit.md`;
> upstream primary sources read 2026-10-16: `kubevirt/kubevirt` `main`
> `staging/src/kubevirt.io/api/backup/v1alpha1/types.go`, `kubernetes/kubernetes` v1.35.0
> `staging/src/k8s.io/apiserver/pkg/registry/rest/delete.go`, k/k issue #132205.

## 0. Bottom line

**No product defect is supported by this run's evidence, and no engineering ticket is drafted.**
The run lands on the *intended* side of every branch `scenario-spec.md` §5 defines: after the VMI
restart the product **redefined the recorded full checkpoint on the recreated domain
automatically, before any incremental was requested**, the pass-1 backup was a genuine
`Incremental` (17 s vs the 55 s full, its own distinct checkpoint, single tracker advancement,
17/17 chain-and-restore checks true), and the scenario's named failure mode — a silent
wrong-content incremental — is affirmatively excluded by an independent restore measurement over
the rebased chain. The one residual (§3) is **block-extent-level verifiability**, and it is an
**evidence-coverage limitation, not a product concern**: the product exposes no copied-byte or
dirty-extent figure in this deployment, the run's own summary disclaims qcow2 allocation-map
inspection by design, and the read-only observer role could not have captured one.

Two observations a reader might expect to carry a ticket are dispositioned in §4 and are
deliberately **not** in the product claim: the recurring non-monotonic pod `deletionTimestamp`
(§4.1 — resolved to documented Kubernetes API-server behaviour, working as intended upstream),
and virt-launcher **startup** log noise (§4.2 — one occurrence of each line per launcher log, in 93–95 of the 95
launcher logs present in this repository). The post-restart **quiesce** warning documented in the
CBT-F-01 analyses did **not** recur here (§4.3) — the freeze succeeded — which strengthens the
existing disposition of that warning as guest-agent-reconnection timing rather than a CBT defect.

## 1. What the run establishes about CBT behaviour across a VMI restart

| # | Intended product behaviour (spec §4 "expected mechanics" / §5) | Observed product behaviour | Evidence | Verdict |
|---|---|---|---|---|
| 1 | The disruption lands after the full checkpoint is recorded and before the incremental object exists (the experiment's precondition) | Full `Done=True` `lastTransitionTime=01:39:04Z`, checkpoint `vm-backup-20261016-cbt-i-01-r01-2026-10-16_01-38-09` on both the object and the tracker; VMI `metadata.deletionTimestamp=01:39:06Z` (2 s later); p01 object `metadata.creationTimestamp=01:40:35Z` (89 s later) | `observer/watches/vmbackup-run.jsonl:8`; `observer/watches/vmi.jsonl:30-34`; `tracker.yaml:26-29`; `trigger.log:78-79`; `injection.log:1`; `full-backup.yaml:25,33-40` | HELD |
| 2 | VM object recreates the VMI; launcher pod replaced (pod teardown + domain shutdown + recreation) | Old VMI UID `b203235a…` DELETED (rv 27132865, phase `Succeeded`) → new UID `29dfe33c…` ADDED (rv 27132866, `creationTimestamp=01:39:16Z`); old launcher `…-tb228` (uid `d07f057a…`) → new `…-zp4kv` (uid `6743da80…`, created 01:39:16Z); old pod's compute container `state.terminated.finishedAt=01:39:15Z`; parent VM UID `9002f647…` unchanged | `observer/watches/vmi.jsonl:34-35`; `observer/watches/pods-vm.jsonl:13-15`; `vmi-recreated.yaml:27,141-151`; `runs/…/run.json` `.vm_uid`; `trigger.log:80-81` | HELD |
| 3 | **CBT state recovery is explicit and observable, not implicit** — the control plane signals that the checkpoint must be redefined | `vm-tracker-20261016-cbt-i-01-r01` `status.checkpointRedefinitionRequired` is **`true`** at rv 27132991 (its only occurrence in the whole stream), then **absent/cleared** at rv 27133000 | `observer/watches/tracker.jsonl:3` (status carries `checkpointRedefinitionRequired:true` **and** `latestCheckpoint=<full checkpoint>`) vs `:4` (field gone, `latestCheckpoint` unchanged) | HELD |
| 4 | Checkpoint redefinition is attempted against the recorded full checkpoint in the restarted launcher | Restarted launcher logs `Redefining checkpoint` `checkpointName=vm-backup-…_01-38-09` at `01:39:20.703916Z` (0.4 ms after a `Synced vmi`), then `Checkpoint redefined successfully with 1 disks` at `01:39:20.735245Z` and `Checkpoint <name> redefined successfully` (`server.go:949`) at `01:39:20.735277Z`; no failure/warning line about backup or checkpoint in the log | `runs/…/logs/virt-launcher.log:1303-1309`; `checkers/evidence-sufficiency.json` criterion 2 citation and false-positive check `done-masks-failure` | HELD |
| 5 | Redefinition happens as part of VMI recovery, **before** the incremental is requested (so the pass cannot be a silent fallback) | Redefinition at `01:39:20.7Z`; the incremental backup object was created `01:40:35Z` — 74 s later — and the launcher's `Generating incremental backup vm-incremental-…-p01 **from checkpoint: vm-backup-…_01-38-09**` is stamped `01:40:38.054177Z` | `runs/…/logs/virt-launcher.log:1304,1364`; `observer/watches/vmbackup-run.jsonl:9`; `runs/…/logs/workflow.log:83` ("`uses base checkpoint vm-backup-…_01-38-09`") | HELD |
| 6 | The tracker's recorded checkpoint survives the restart (it is the bitmap base, not per-domain state) | Tracker `latestCheckpoint` = the full checkpoint, unchanged, at rv 27132614 / 27132991 / 27133000 (the object is never recreated across the restart; sampler samples 01:39:33–01:40:46Z all show the same value); the tracker holds `latestCheckpoint: null` only at its own creation (rv 27131533, i.e. before the full completed) | `observer/watches/tracker.jsonl:1-4`; `observer/finding.md` §7; `observer/_poll-phase2-prefilter.jsonl` fields `tracker.latestCheckpoint_name`/`tracker.rv` | HELD |
| 7 | Post-restart pass terminal type is explicit and correct | p01 `status.type=Incremental`, `conditions[Done]={True, "Successfully completed VirtualMachineBackup", 01:40:52Z}`, `Progressing={False, same reason}`, `status.error` absent, `checkpointName=vm-incremental-…-p01-2026-10-16_01-40-35`, `includedVolumes=[vda/rootdisk]` | `observer/watches/vmbackup-run.jsonl:16`; `incremental-backup.yaml:20-40`; `runs/…/run.json` `.backups.incrementals[0]`; `trigger.log` `RESULTING BACKUP TYPE … Incremental` | HELD |
| 8 | Exactly one checkpoint for the pass; tracker advances exactly once; chain valid | Single pass-1 object with one `checkpointName`; tracker rv 27131533 (null) → 27132614/27133000 (full) → **27134717** (p01 wrapper checkpoint) then stable across all 16 samples; `incremental_pass_01_checkpoint_is_distinct=true`, `tracker_matches_final_incremental_checkpoint=true` | `observer/watches/tracker.jsonl:1-5`; `observer/_poll-phase2.jsonl`; `runs/…/report.json` `.verification.checks`; `checkers/evidence-sufficiency.json` criterion 3 | HELD |
| 9 | Restore correctness through the chain (the decisive anti-silent-fallback test) | full-only 1000 files / 18,277,728,256 B / `351c3fab…b13b`; cumulative (p01 rebased on full) 2000 files / 36,561,747,968 B / `a9ca19b4…d7a8d`; `failed_restore_check_count=0`, `failed_hash_check_count=0`, `algorithm=SHA-256`; 17/17 checks true | `runs/…/summary.json` `.restore_hashes`, `.guest_payload`; `runs/…/fragments/restore-test.json`; `runs/…/report.json` `.verification.checks`; `trigger.log` (`Details: PASS`) | HELD |
| 10 | VM/VMI healthy and CBT re-enabled after recovery | Recreated VMI `phase=Running`, `Ready=True`, `AgentConnected=True`, `status.changedBlockTracking.state=Enabled`; workload re-validated against the saved manifest before mutation | `observer/watches/vmi.jsonl:56`; `vmi-recreated.yaml:141-151`; `runs/…/logs/workflow.log:54-58`; `trigger.log:120-121` | HELD |
| 11 | Guest quiesce on the post-restart copy | `Freezing VMI to capture backup state` `01:40:38.054247Z` → `Thawing VMI after backup job started` `01:40:38.127063Z`, **no** freeze-failure warning; guest agent connected at `01:39:27.749Z`, 70 s before the freeze. p01 `Done.reason` carries no warning | `runs/…/logs/virt-launcher.log:1316,1320-1330,1365,1369`; `incremental-backup.yaml:33-35` | HELD (contrast §4.3) |
| 12 | Durations inside the spec baselines (a Full fallback would be visibly longer) | full 55 s (`01:38:09Z`→`01:39:04Z`); p01 17 s (`01:40:35Z`→`01:40:52Z`); spec §5 windows 52–55 s / 16–21 s | `observer/watches/vmbackup-run.jsonl:1,8,9,16`; `runs/…/fragments/backup-timings.json`; `runs/…/run.json` `.backup_timings` | HELD (with the §3 caveat that duration cannot *by itself* prove a small dirty set here) |

**The control loop, in rv order (one etcd resourceVersion space across the pinned streams).**
rv 27132865 old VMI DELETED → rv 27132866 new VMI ADDED (`01:39:16Z`, `Pending`) → rv 27132961/27132990 `Scheduled`
→ **rv 27132991 tracker `checkpointRedefinitionRequired=true`** → rv 27132993 VMI `Running` → **rv 27133000
tracker flag cleared, `latestCheckpoint` still the full checkpoint** → rv 27133002 VMI `Running`; launcher
`Redefining checkpoint` `01:39:20.703916Z` / `redefined successfully` `01:39:20.735245Z`. The tracker field's
transitions bracket the launcher's redefinition on both sides; the tracker object itself is never recreated.
Tracker-status events carry no timestamps of their own, so the flag's exact instants are **bounded by the VMI
phase transitions and by the launcher's own log stamps (~01:39:20Z)**, not measured directly.
`[INFERENCE]` the field name and the observed clear-after-success relation make this the product's explicit
"redefine the checkpoint after (re)start" signal; the launcher-side trigger of the redefine call is a VMI sync
(the log order is `Synced vmi` → `Redefining checkpoint` 0.4 ms later), and nothing in the pack shows any other
trigger.

## 2. The evidenced negative, stated with its grounds

**No product defect is supported by this run's evidence.** The negative rests on:

- **The restart was real and the CBT state survived it** — new VMI UID `29dfe33c…` vs old `b203235a…`
  (`observer/watches/vmi.jsonl:34-35`), new launcher uid `6743da80…` vs old `d07f057a…`
  (`observer/watches/pods-vm.jsonl:13-15`), while the tracker's `latestCheckpoint` never moved off the full
  checkpoint and the tracker object was not recreated (§1 rows 2, 6).
- **Recovery was explicit, not implicit and not a fallback** — `checkpointRedefinitionRequired:true` → cleared
  (`observer/watches/tracker.jsonl:3-4`) around the launcher's `Checkpoint redefined successfully with 1 disks`
  (`runs/…/logs/virt-launcher.log:1308`); the pass was then generated *from that checkpoint*
  (`virt-launcher.log:1364`) and terminated as `type=Incremental` with a success reason
  (`incremental-backup.yaml:33-40`). A full-backup fallback would have shown a longer, `type=Full` copy — neither
  occurred (§1 row 12).
- **The named failure mode is positively excluded, not merely unobserved** — the cumulative restore reads the
  p01 image rebased onto the full image and hashes the workload directory inside the restore pod; the result
  matches the guest manifest captured after the mutation (2000 files / 36,561,747,968 B / `a9ca19b4…`, 0 failed
  hash checks) (`runs/…/fragments/restore-test.json`, `runs/…/summary.json` `.restore_hashes`; the
  self-comparison trap is examined and rejected in `checkers/evidence-sufficiency.json`
  `false_positives_checked.restore-self-comparison`).
- **Guest quiesce was achieved on the post-restart copy** — Freezing/Thawing pair with no failure warning and no
  warning in `Done.reason` (§1 row 11).
- **No error, warning or failed condition appears anywhere on the CBT path** — `Done=True` with the success
  reason on both objects, `Progressing` flipping `True→False` at the same instant, no `status.error`, and
  "no error/warning line about backup or checkpoint exists in `runs/…/logs/virt-launcher.log`"
  (`checkers/evidence-sufficiency.json` `false_positives_checked.done-masks-failure`).

This negative agrees with the run's own reports and with the two blind checkers
(`reports/test-run-result.md` "CBT product findings: None"; `checkers/injection-validity.json` `.verdict=PASS`
with `target`/`window`/`independent-effect` all `SUPPORTED`; `checkers/evidence-sufficiency.json` `.verdict=PASS`,
`reject_reasons:[]`). No artifact in the pack asserts a contrary product finding.

## 3. The residual — is unproven block-extent-level incrementality a *product* concern? No; it is evidence coverage

The residual is recorded in three places and is consistent across them:
`checkers/evidence-sufficiency.json` `missing_evidence[0]` ("Block-extent level incrementality of the pass-1
backup (qcow2 allocation map / dirty-bitmap extents) … severity: non-blocking residual"), criterion 2's
`detail` ("UNPROVEN (bounded residual): block-e…"), and the harness's own disclaimer
`runs/…/summary.json` `.scope` = "Workflow summary; **does not independently inspect qcow2 allocation maps**."

**Why it is not a product concern.**

1. **Nothing observably misbehaved.** A product defect requires an observed behaviour outside the contract; the
   contract here (§5 criterion 2: "changed blocks vs full — data content correct per restore"; §7: "the decisive
   check is the restore content matching the mutated workload") is met, by measurement, through the rebased
   chain. Extent-level evidence would add *confidence about the mechanism*, not *information about the outcome*.
2. **It is unverifiable by construction in this run, on the evidence side.** The incremental destination volume
   is a separate PVC; inspecting its qcow2 allocation map needs a pod that mounts it (or `oc exec`/libvirt
   access), and the observer contract was explicitly read-only with no `oc exec`
   (`observer/FINAL` gaps: "No `oc exec` and no libvirt domain access (read-only observer): the CBT checkpoint
   redefinition in QEMU/libvirt is not observed directly"). That is a coverage decision, not a product
   behaviour.
3. **The verdicts are already framed that way.** The run verdict is PASS on §5 with the residual named as
   *unproven sub-aspect*, and no criterion was graded INSUFFICIENT on it
   (`checkers/evidence-sufficiency.json` criterion 2: "the criterion's operative test … is met").

**Two honest caveats that belong with the residual (not with any ticket).**

- **Duration and byte volume are degenerate discriminators in this scenario.** The harness mutation between the
  checkpoint and the pass was `payload_bytes_added = 18,284,019,712` B / 1000 files added + 1 modified
  (`runs/…/summary.json` `.guest_payload`, `.backups.incremental_passes[0]`), i.e. the *logical change is the
  same order as the whole baseline* (18,277,728,256 B). So "17 s vs 55 s" is **not** evidence of a small dirty
  set, and a hypothetical full fallback would have moved a comparable allocated volume. `[INFERENCE]` the 3.2×
  difference is more plausibly explained by the full path walking/zero-detecting the whole 80 GiB virtual disk
  while the incremental path walks only dirty extents (or by copy-parallelism/page-cache differences) — but that
  is an inference, not a measurement, and it is exactly the sort of claim the allocation map would settle.
- **The workload design limits the strength of the restore-based exclusion.** The mutation is static files
  written and hashed before the backup, so the restore comparison proves *content* correctness of the chain; it
  does not probe crash-consistency or in-flight-write behaviour (the same limitation the CBT-F-01 r04 analysis
  records for its unquiesced recovery copy).

**What would settle the residual** (named as the acceptance asks — this is a follow-up for the *harness*, and it
needs no product change):

1. **A read-only allocation-map capture of the incremental destination**: run a scratch pod that mounts the
   pass-1 destination PVC read-only and capture `qemu-img map --output=json` (and `qemu-img info
   --backing-chain`) for the incremental image and for the full image, comparing allocated-extent totals and the
   incremental's backing-file chain. That is the artifact `missing_evidence[0]` names.
2. **A size-discriminating workload**: make the between-checkpoint change small (a few MiB) instead of
   baseline-sized, so the copied-bytes/extents measurement is decisive rather than a comparison of two
   ~18 GB figures, and record the destination volume's used bytes (`du`/allocation) at both cp points.
3. **Optional product-side route** (a pointer, not a claim): upstream `main` defines a per-volume backup link
   surface with `dataEndpoint` and `mapEndpoint` (`staging/src/kubevirt.io/api/backup/v1alpha1/types.go:72-83`)
   plus `VirtualMachineBackupStatus.Links` (`:278`) — a pull/export-mode backup could in principle expose the
   backup volume for mapping. This deployment's push-mode backups with an explicit `pvcName` populate no
   `links` (`incremental-backup.yaml:29-40`; same in `full-backup.yaml`), and nothing in the pack used them, so
   whether a map endpoint yields dirty extents is an engineering question for the CBT owners, not an
   established fact here.

If (1) or (2) were run and showed an incremental that copied extents the guest never wrote, *that* would be a
product ticket. Nothing in this run's evidence points that way.

## 4. Observations examined and deliberately excluded from the product claim

### 4.1 Non-monotonic `metadata.deletionTimestamp` on the old launcher pod — **resolved; Kubernetes API-server behaviour, not CBT** (no ticket)

Observed: `observer/watches/pods-vm.jsonl` carries the old pod `…-tb228` with
`deletionTimestamp=2026-10-16T01:40:06Z` **and** `deletionGracePeriodSeconds=60` at rv 27132652/27132660/27132852,
then `deletionTimestamp=2026-10-16T01:39:16Z` with `deletionGracePeriodSeconds=0` at rv 27132861/27132862 (the
DELETED tombstone). The value moves **backwards** while `resourceVersion` rises — and the grace period moves
`60 → 0` with it.

Resolved by primary source (not by inference): the apiserver sets a pod's `deletionTimestamp` to
*request time + grace period*, and on a subsequent delete request **with a shortened grace period** it rewrites
it as `old_deletionTimestamp − old_grace + new_grace`, floored at `now()`
(`kubernetes/kubernetes` v1.35.0 `staging/src/k8s.io/apiserver/pkg/registry/rest/delete.go:108-145`, with the
in-source comment "Move the existing deletionTimestamp back by existing object.DeletionGracePeriod, then forward
by options.DeletionGracePeriod … the grace period can only be shortened in this code path"). The field contract
says the same ("may be shortened", never extended — liggitt in k/k#132205, which was **closed `not-planned`
2025-12-09** with the maintainer statement "I think this issue is working as intended"). The run's numbers
reproduce the formula exactly: `01:39:06Z + 60 s = 01:40:06Z` (grace 60), then `−60 s + 0 s = 01:39:16Z`
(grace 0) — where `01:39:06Z` is the VMI deletion instant that caused the pod deletion
(`observer/watches/vmi.jsonl:30-34`; `trigger.log:78-79`), and `01:39:16Z` is when the shortened/zero-grace
delete landed.

Disposition — **excluded from the product claim; no ticket.** It is a **pod-object** field written by the API
server, on a surface Kubernetes documents and considers intended; it is not CBT state, it does not touch the
backup, and the authoritative launcher-termination instant used by the observer is the container
`state.terminated.finishedAt=2026-10-16T01:39:15Z` (`pods-vm.jsonl:13-15`), which is consistent with the final
observed `deletionTimestamp` and *not* with the transient `01:40:06Z`. Consequence for the pack: any timing
claim that reads a pod's `deletionTimestamp` naively can be off by up to the grace period; the injection-window
claims in this run use the **VMI's** `deletionTimestamp` and are unaffected
(`checkers/injection-validity.json` `.checks[].window=SUPPORTED`). The same phenomenon recurs in the CBT-F-01
run pack for the same reason; it is a harness-facing citation note, not a product finding.

### 4.2 virt-launcher **startup** log noise (`No disk capacity`, client-request limit, domain taints) — environment-wide, no functional impact (no ticket)

Observed in the restarted launcher, all within ~5 s of domain start and all **once per log file**:
`level=error "No disk capacity"` (`manager.go:995`, `01:39:20.659126Z`), `level=warning "Client hit max requests
limit 5. This may result in keep-alive timeouts…"` (`virNetServerClientDispatchRead:1269`, `01:39:27.753000Z`),
and libvirt `tainted: custom-monitor` / `tainted: custom-ga-command` (`runs/…/logs/virt-launcher.log:1300,1307,1327,1329`).

Disposition — **excluded from the product claim; no ticket.** `max_client_requests` appears in **95 of the 95**
`virt-launcher.log` files that exist under `runs/*/logs/` in this repository and `No disk capacity` in **93 of
them** (one occurrence per file; counted over the files present), so both are an environment-wide launcher
startup signature, not an effect of this run's restart. The two libvirt `tainted:` lines are the domain-taint
notices emitted when KubeVirt drives the custom QEMU monitor and guest-agent commands (present in 5 of the 95
logs — they appear only where libvirt's own message stream is captured), informational by construction. The
`No disk capacity` line is
already documented in-repo for a *different* cause (Block-mode CD-ROM volumes: `docs/windows-cbt-plan.md:69`,
`manifests/windows-image.yaml:11-15`); here it is logged at domain start, 0.3 ms after
`kubevirt domain status: Running(Paused) reason: Unknown(StartingUp)` and before any disk statistics can be
populated (`virt-launcher.log:1298-1300`) — `[INFERENCE]` a benign stats-read race at startup, in the launcher's
domain-stats path, not the CBT path, with no observable consequence (the checkpoint redefinition, the
incremental copy and the restore all followed normally). It is worth one line in *launcher log-hygiene*
discussions because an error-level line adjacent to the CBT redefinition lines can read as a CBT symptom;
nothing here justifies a product ticket.

### 4.3 The post-restart quiesce warning did **not** recur here — and that is consistent with its existing disposition

CBT-F-01 r02/r03/r04 recorded `Done=True` … `warning: Failed freezing guest filesystem: virError(Code=86, …
QEMU guest agent is not connected)` on the first backup taken seconds after a launcher replacement, with the
launcher sequence `Freezing VMI → agent not connected → warning → Backup started` and **no** thaw line
(`cbt-chaos/scenarios_v2/CBT-F-01/runs/20261016-cbt-f-01-r03/observer/watches/launcher-compute.log:71-77`;
dispositioned as non-fatal by design in
`cbt-chaos/scenarios_v2/CBT-F-01/analysis/20261016-cbt-f-01-r04-product-flow.md` §3.2/§5.1). **This run produced
the opposite outcome on the same class of copy**: the guest agent had reconnected at `01:39:27.749Z`
(`virt-launcher.log:1316`), the incremental's freeze at `01:40:38.054Z` succeeded — `Thawing VMI after backup job
started` at `01:40:38.127Z` with no `Failed freezing` warning and no warning in p01's `Done.reason`
(`virt-launcher.log:1365,1369`; `incremental-backup.yaml:33-35`).

Disposition — **no ticket, and no change to the CBT-F-01 disposition**: the difference between the runs is *how
soon after the restart the copy starts* (CBT-F-01: ~15–36 s, agent still down; here: the copy began ~79 s after
the recreated VMI object existed and ~74 s after it was `Ready` (`01:39:21Z` → p01 object `01:40:35Z`), with the
agent connected 70 s before the freeze), i.e. guest-agent readiness timing. It corroborates
reading that warning as timing-dependent rather than as a CBT defect, and it also means the **guest-consistency
open question** of CBT-F-01 §5.1 (is an unquiesced post-restart copy crash-consistent?) is **not** answered or
raised by this run — here the copy was quiesced.

### 4.4 Harness-side items, kept out of the product claim

- **Deterministic evaluator `INVALID` (`verdict.json`)** — inapplicable, already recorded as harness finding
  **HV1** in `docs/agent-plan-incorrect-points.md:186-199` (it implements CBT-F-01's shape: it requires
  `trigger/action-request.json`, `trigger/effect-check.json`, a *failed* full backup and a same-VM recovery
  attempt, none of which this scenario produces by design). Not re-litigated here; see HV1 for the fix
  direction (declared scenario shape → `NOT_APPLICABLE`/`INCONCLUSIVE`).
- **Empty `trigger/` in the scenario run root** and **`ledger.jsonl`/`state.json` not advanced past
  `preflight_go` when the observer froze** — layout/terminality artifacts, listed as
  `checkers/evidence-sufficiency.json` `missing_evidence[2]` and `observer/FINAL` gaps; they underlie the
  evaluator's layout complaint, not any spec §5 criterion. `state.json` now reads `phase=closed`,
  `verdict=PASS`.
- **Unpinned-digest lifecycle run root** (`runs/20261016-cbt-i-01-r01/**` outside
  `evidence-index.json`'s key namespace) — `missing_evidence[1]`; criterion-relevant values are corroborated
  inside the pinned pack (I cite the launcher log for the redefinition lines, and transcribe digests *as
  observer-quoted values* where they are pinned only as quotes, per `observer/FINAL` `.observed_facts`).
- **Citation slip in `observer/finding.md` §4** (recreated VMI cited as `vmi.jsonl:31`; the ADDED is line 35) —
  `missing_evidence[4]`; corrected in citations here and in the checker.
- **`PodSecurity` warning on the harness's restore-verifier pod** (`trigger.log:149`: the `restore-verify`
  container is `privileged`, uses `hostPath` volumes and does not set `runAsNonRoot`/`seccompProfile`, so `oc
  apply` warns under the `restricted:latest` policy) — a manifest property of the **harness's** verification pod
  (the same class of warning the CBT-F-01 r04 analysis lists as harness-side). It did not block the apply and has
  no product content; it matters only because a reader grepping the trigger log for "warning" will hit it.

None of these is a CBT behaviour, and nothing in them implicates the product.

## 5. Environment actually exercised (from the artifacts)

| Component | Value | Evidence |
|---|---|---|
| OpenShift / Kubernetes | `oc client 4.22.15`; namespace `vm-cbt-demo` `phase=Active` | `preflight.json` check `1-cluster-and-namespace` |
| CNV / KubeVirt | HCO `kubevirt-hyperconverged` `Available=True Degraded=False Progressing=False`; CSV `kubevirt-hyperconverged-operator.v4.22.12` `Succeeded`; KubeVirt CR `Available=True Degraded=False`; zero `openshift-cnv` pods outside Running/Completed | `preflight.json` check `2-cnv-health-and-absent-disruption-target` |
| KubeVirt software version | **not recorded as an image tag/digest in the pack**. Observable discriminator: the backup status carries only `Initializing`/`Progressing`/`Done` (`incremental-backup.yaml:31-39`) with `status.type`, `status.checkpointName`, `status.includedVolumes`, and **no** `Complete`/`Failed`/`Quiesced` condition and no `status.error` — whereas upstream `main` defines `ConditionComplete`/`ConditionFailed`/`ConditionQuiesced` with `QuiesceSucceeded`/`QuiesceFailed`/`ReasonCompletedWithWarning` (`staging/src/kubevirt.io/api/backup/v1alpha1/types.go:282-314`). `[INFERENCE]` this deployment predates that restructure (same inference as the CBT-F-01 r04 analysis §6); the delta cannot be pinned to a release from this pack. Note the tracker **does** expose `checkpointRedefinitionRequired` (§1 row 3), which upstream defines at `types.go:165` | `incremental-backup.yaml`, `full-backup.yaml`, `observer/watches/tracker.jsonl:3`, upstream `types.go` |
| libvirt / QEMU (launcher) | libvirt 11.10.0, package `12.3.el9_8`; qemu `10.1.0-17.el9_8.5`; guest kernel `5.14.0-687.5.1.el9_8` | `runs/…/logs/virt-launcher.log:1305,1312`; guest boot line `:3` |
| Storage | **HostPath variant** — SC `cbt-demo-hpp` (`kubevirt.io.hostpath-provisioner`, `WaitForFirstConsumer`), HPP `cbt-demo-hpp` `Available=True`, pool `Ready 1/1`, backed by a local PV on the node the VM ran on; plan sizes rootDV 80 Gi, full dest 80 Gi, incremental dest 30 Gi (`scripts/common.sh`) | `preflight.json` check `3-storage-class-for-MANIFEST_VARIANT-default` and check `4-capacity-headroom-full-plus-incremental` |
| Backend note (cross-scenario) | unlike the CBT-F-01/CBT-F-04 analyses (ODF/Ceph RBD), this run exercised CBT on a **file-backed HostPath** volume — the same checkpoint-redefinition/incremental behaviour appears there too | `preflight.json` check 3/4; `full-backup.yaml`, `incremental-backup.yaml` |
| Guest / workload | RHEL 9, CBT `Enabled`; baseline 1000 files / 18,277,728,256 B (15–20 MiB each); pass adds 1000 files (+1 modified) = 18,284,019,712 B | `runs/…/summary.json` `.guest_payload`, `.cbt.vm_state=Enabled`; `trigger.log:117-127` (`Pass 1 workload updated · 1000 files added · 1 modified`); `runs/…/run.json` `.guest` |
| Backup API objects exercised | `VirtualMachineBackup` Full (implicit base of the chain) and Incremental **in push mode against an explicit `pvcName`**, sourced from `VirtualMachineBackupTracker` `vm-tracker-20261016-cbt-i-01-r01`; tracker `status.latestCheckpoint` + `status.checkpointRedefinitionRequired` | `full-backup.yaml:20-27`, `incremental-backup.yaml:20-27`, `tracker.yaml:22-29`, `observer/watches/tracker.jsonl:1-5` |

## 6. Scope of the negative — what this run does **not** establish

- **Single run, one restart, one pass.** Nothing here can bound *frequency* of any behaviour; the product
  behaved correctly once, on a file-backed HostPath volume, with a restart landing 2 s after the full's `Done`.
- **No failed-path coverage.** This run produced no failed backup, no `forceFullBackup` recovery leg and no
  ENOSPC-shaped copy, so it neither supports nor contradicts CBT-F-04's dirty-set-sizing and orphaned-libvirt-
  checkpoint findings (`…/CBT-F-04/analysis/20261015-cbtf04-r03-product-flow.md` §2/§3), nor adds to the
  `Done=True`-on-failure surface question of the CBT-F-01 r04 analysis §3.1. One incidental non-contradiction:
  this run's dirty payload (18.28 GB) fit its planned 30 Gi incremental destination.
- **No crash-consistency probe** — the workload has no in-flight writes at the restart instant, so the matched
  restores cannot distinguish a crash-consistent image from a journal-dirty one (the CBT-F-01 r04 analysis §5.1
  question). Here the copy was additionally *quiesced* (§4.3), so the question is not even raised.
- **No block-extent evidence** (§3) and **no direct QEMU/libvirt observation**: the checkpoint redefinition is
  evidenced by `status.checkpointName` + the tracker's `latestCheckpoint`/`checkpointRedefinitionRequired` + the
  launcher's own log lines, not by `virsh checkpoint-list` output.
- **A multi-restart or restart-during-copy variant is untested** (this scenario's injection is deliberately
  between the stages; the restart-during-copy shape belongs to the CBT-F-01 scenario, not to this one).

## 7. Disposition and next action

- **Product: no ticket.** Candidate ticket shapes were considered and each is closed by this run's evidence or
  is out of scope: (a) a missing/exposed redefinition signal — not applicable, the signal exists and is
  observable server-side (`checkpointRedefinitionRequired`, §1 row 3); (b) silent or false incrementals — the
  named failure mode is affirmatively excluded (§2); (c) the `Done=True`-as-sole-discriminator surface — not
  exercised here (no failure in this run) and already dispositioned upstream in the CBT-F-01 r04 analysis §3.1;
  (d) block-extent verifiability — evidence coverage, §3; (e) the non-monotonic pod `deletionTimestamp` —
  Kubernetes-intended API behaviour on a pod object, §4.1.
- **Falsifiers this run defines for a future ticket** (state them so a later run can act fast): if a restart ever
  yields `status.type=Full` while the tracker kept a prior checkpoint *and* `checkpointRedefinitionRequired`
  never cleared; or a pass whose cumulative restore mismatches the guest manifest; or an allocation map showing
  copied extents outside the mutated range — each would be product-ticket evidence. None occurred here.
- **Harness follow-ups needed to settle the residual** (§3): the read-only allocation-map capture on the
  incremental destination PVC, on a workload whose between-checkpoint change is small enough for the copy size
  to discriminate. Harness-side items of §4.4 (HV1 evaluator shape, `trigger/` layout, lifecycle-run
  digest-pinning) are already tracked as the run's own `missing_evidence` entries and `docs/agent-plan-incorrect-points.md` HV1 — no product content.
