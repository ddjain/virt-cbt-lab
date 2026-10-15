# CBT product-flow analysis — CBT-F-04 — run 20261015-cbtf04-r03

> Scope: product-flow behavior of the CBT backup/checkpoint/tracker/recovery
> machinery under the controller-kill disruption, from run r03's closed
> evidence pack only (plus the r02 analysis for reproduction counting, as
> authorized in the assignment). Harness/sequence events (rogue E2E lock,
> retry gating, workload-plan amendments) are classified as such and excluded
> from product findings except where they bound evidence. All times UTC,
> 2026-10-15. Nothing here is a confirmed defect unless stated; hypotheses
> are labeled.

Sources verified: `observer/finding.md`, `observer/watches/*.jsonl`
(events, tracker, lease, pods, vmbackup-all-r03), `observer/WATCH-LOST`,
`observer/evidence-terminal/*`, `recovery/` (done.json, retry logs,
`incremental-backup-post-retry3.yaml`, `tracker-post-{pre-incremental,retry3,retry5}.yaml`,
`checkpoint-tree-post-{incremental,retry5}.txt`,
`qemu-img-preserved-artifacts.txt`, `qemu-img-post-retry3.txt`,
`rbd-du-backup-volumes.txt`, `rbd-du-retry5.txt`,
`guest-state-post-failure.txt`, `retry-blocked-state.txt`,
`retry4-inventory-mismatch.txt`, `incremental-backup-absence.txt`,
`restore-verification.txt`), `reports/test-run-{report,result}.md`,
`scenario-spec.md` §5, `checkers/*` verdicts.

## 1. Observed CBT-flow behavior vs the intended contract

| # | Contract behavior (spec §5 / jira) | Observed behavior | Evidence | Verdict |
|---|-------------------------------------|--------------------|----------|---------|
| 1 | Data copy survives controller kill (data plane in launcher, control plane in controller) | Launcher `virt-launcher-vm-20261015-cbtf04-r03-mqtfn` (uid bbaa5ed9-…) never restarted (restartCount 0 across window); copy signal 09:14:09.971156Z; leader kgtth (uid df277fc4-…) deleted 09:14:27Z; backup terminal 09:15:15Z — copy spanned the deletion | observer finding timeline; pods watch; launcher log | HELD |
| 2 | Failover + reconciliation complete | Lease holder kgtth→mrspr at 09:14:43.048029Z (transitions 20→21); replacement rx859 (uid 0b5dbf00-…) Ready; 2/2 Running/Ready at final checks 10:59:31Z | lease watch; ctrl-pods watch; FINAL | HELD |
| 3 | Full backup terminal state correct: Done=True, non-failure reason, type Full, non-empty checkpoint, expected volumes, no duplicates | `Done=True` reason `Successfully completed VirtualMachineBackup`, type Full, checkpoint `vm-backup-20261015-cbtf04-r03-2026-10-15_09-14-05`, volume rootdisk/vda; checkpoint trees pre-injection and post-full identical (single root) | vmbackup watch (inspected twice); checkpoint-tree-pre/post | HELD |
| 4 | Tracker advances exactly once per backup; failed passes do not advance it | Tracker: null → full checkpoint 09-14-05 (one transition, `tracker-post-retry3.yaml` confirms unchanged after the ENOSPC-failed retry-3), then exactly once → child 10-49-06 (`tracker-post-retry5.yaml`); final tracker = final checkpoint | tracker watch; tracker-post-*.yaml | HELD |
| 5 | No false Incremental / chain stays rebaseable | Retry-5 incremental was a true child of the full checkpoint at the CR/tracker level; cumulative-chain restore matched 10 files / 10,737,418,240 B / manifest SHA-256 with 0 failed restore and 0 failed hash checks | checkpoint-tree-post-retry5.txt; restore-verification; done.json retry5 | HELD, with anomaly (findings 1 & 2) |
| 6 | Temp attachment cleanup; destination PVC stays run PVC and Bound | Attachment mounted 09:14:09Z / unmounted 09:15:14Z; no stale volumeStatus; full dest PVC Bound 80Gi (78 GiB used, rbd du); incremental dest PVC Bound 100Gi (68 GiB used, rbd du) | events watch; rbd-du-backup-volumes.txt; rbd-du-retry5.txt | HELD, with recurring detach anomaly (see §5) |
| 7 | VM/VMI Running, CBT Enabled throughout | VM Ready, CBT `Enabled` at all observation points incl. after the failed incremental pass (guest-state-post-failure.txt: `cbt state=Enabled`) | vm watch; recovery guest-state | HELD |
| 8 | Restore data-correctness (not just Done=True) | Full-only: 8 files / 8,589,934,592 B / manifest match (full artifact qcow2 verified: 78.1 GiB, corrupt=false, 7,732 extents all present); cumulative chain: 10 files / 10,737,418,240 B / manifest match; 0 failed restore checks, 0 hash failures | qemu-img-preserved-artifacts.txt; done.json retry5; reports | HELD (incremental chain extent map not capturable read-only — recorded limitation, chain proven via backing-file metadata + volume usage + semantic restore) |
| 9 | Same-VM post-chaos incremental succeeds with distinct child checkpoint, one further tracker update | `vm-incremental-20261015-cbtf04-r03-p01` Done=True "Successfully completed VirtualMachineBackup", type Incremental, child checkpoint 10-49-06, 68 s duration — after harness-side retries (see §2 for the failure path) | done.json retry5; reports | HELD |

Evidence-confidence limits (stated, not blocking): OpenShift/CNV versions not
captured (only virt-controller image digest sha256:23e9322e…); the incremental
chain extent map could not be captured read-only (backing file resolves to the
live launcher disk) — chain correctness rests on backing-file metadata, rbd
usage, and the semantic chain restore; watch deaths M1–M5 each post-terminal
or covered by supplementary streams/live reads (WATCH-LOST); restore/hash
verification is RecoveryWorker evidence (stage exit 0), not
observer-witnessed.

## 2. Finding 1 — CBT dirty-block retention: 68 GiB copied for a 3 GiB logical change; 30 Gi destination overflowed

### Event sequence (all r03, UTC)

1. **09:14:05 → 09:15:15** — full backup completes (Done=True, success
   reason); checkpoint `vm-backup-…-09-14-05` created; tracker advances to it.
   This checkpoint is the merge base for all subsequent incremental copies.
2. **09:49:57 → 10:29:16** — incremental follow-up attempt-1 (RecoveryWorker,
   no chaos active) fails at stage step 2/5 (guest workload mutation): the
   workload manifest planned `incremental_file_count_per_pass=1000 × 1024 MiB`
   against an 80 Gi rootdisk; the guest filled (`df`: 77G/77G, 100%) after
   **66 × 1 GiB files were fully written and mv-ed into place**
   (`guest-state-post-failure.txt`: workload dir 74 entries = 8 baseline +
   66). No incremental VirtualMachineBackup/PVC was created
   (`incremental-backup-absence.txt`: NotFound). Tracker untouched.
3. **Between attempts** — the harness deletes the 66 partial files and the
   Lead amends the plan 1000→2 files (done.json `retry.amendments`). This is
   the write-then-delete cycle: ~66 GiB written to guest blocks that are
   dead (free) by the time any backup runs. Guest at retry-3: 10 files
   (8 base + 2 incremental-01), 65G free (done.json retry3).
4. **10:34:53 (retry-3)** — new incremental backup
   `vm-incremental-20261015-cbtf04-r03-p01` (uid f71e404c-c817-489b-ac39-
   7e38a007aed8) on a 30 Gi destination PVC; checkpoint `…-10-35-19`
   created 10:35:19Z. The copy pulls the dirty set accumulated since the
   full checkpoint 09-14-05 — which includes the 66 GiB of deleted-file
   blocks — fills the destination to 29 GiB, and dies: launcher log
   "Backup has failed"; CR reaches `Done=True` with reason
   `Backup has failed: No space left on device` at 10:35:56Z
   (`incremental-backup-post-retry3.yaml`: Progressing=False and Done=True,
   both carrying the failure reason; type Incremental). **Tracker unchanged**
   at the full checkpoint (`tracker-post-retry3.yaml`).
5. **~10:41Z** — the failed backup CR is deleted (Lead-approved; name reused
   later by retry-5). Its libvirt checkpoint 10-35-19 is **not** removed —
   finding 2 (§3).
6. **10:48:40 (retry-5)** — same logical change set, 100 Gi destination. The
   incremental completes Done=True (success reason) at 10:50:14Z, checkpoint
   `…-10-49-06`, tracker advances once. **Physical copy size: 68 GiB**
   (`rbd-du-retry5.txt`: 100 GiB volume, 68 GiB used;
   `qemu-img-preserved-artifacts.txt`: incremental artifact qcow2 disk size
   67.7 GiB, backing file → live rootdisk.qcow2, corrupt=false) for a
   **logical change of ~3 GiB** (2 files added + 1 modified;
   2,147,483,648 B added). 68 GiB ≈ 66 GiB dead writes + ~2 GiB live adds +
   modified-file overlap + metadata — arithmetically consistent with the
   retained-dirty-block explanation.

### Semantics assessment — is this a defect?

**No — the bitmap behavior is correct-by-design CBT semantics, and the run
proves the copy was data-correct.** Dirty means *ever written since the
checkpoint merge base*, not *live at backup time*. It cannot mean otherwise
at block level: file deletion does not restore block contents, so the blocks
holding deleted-file data differ from the full-backup image; if the
incremental omitted them, a chain restore would present stale block content
under a live FS that has since reallocated or references that region, and
the FS-metadata churn of the deletions themselves must be captured. The
cumulative-chain restore matching the final guest manifest (0 failures)
confirms the conservative copy produced a correct image. The failure class
of the *first pass* was a loud, correct failure (explicit ENOSPC reason,
tracker not advanced, retry succeeded) — not silent corruption.

**What is ticket-worthy is the contract/guidance gap around the semantics,
on three grounds:**

1. **Sizing guidance (primary).** Nothing observed in the API surface or
   docs warns that incremental destination capacity must be sized to the
   *peak dirty volume since the last checkpoint*, which can exceed the
   entire disk's live data (here 68 GiB dirty against 8→10 GiB live) and
   has no bound related to the logical change. A customer sizing a 30 Gi
   incremental destination for a "3 GiB change" hits mid-copy ENOSPC with
   29 GiB already written. The failure is loud, but the capacity planning
   input is undocumented.
2. **`Done=True` on a failed backup (secondary, observed on retry-3).** The
   failed pass terminated with condition `type=Done, status=True` while the
   reason string says "Backup has failed: No space left on device". Any
   consumer keying on `Done=True` — the exact field that signals success on
   the happy path (the full backup in this same run) — cannot distinguish
   success from failure without parsing free-text reasons. The run's own E2E
   tooling had to special-case it ("reached Done=True but the backup
   actually failed"). This is a failure-semantics contract question
   independent of ENOSPC.
3. **No pre-copy signal (tertiary).** Nothing surfaced the dirty-set size
   before or during the copy; the mismatch was discovered only by the
   kernel ENOSPC after 29 GiB of copying. An exposed dirty-extent size (or
   a preflight capacity check) would convert this from mid-copy failure to
   a reject-at-admission. (Enhancement hypothesis, not a contract claim.)

### Reproduction status — honest count

- **r03 is the only run that demonstrates the effect**, with physical
  evidence (rbd du 68 GiB + qemu-img 67.7 GiB vs 3 GiB logical).
- **r02 did not reproduce or contradict it.** r02's incremental (1000 files,
  ~18.28 GiB payload, per its summary.json) fit its 30 Gi destination and
  completed; r02 captured no rbd-du/qemu-img copy-size measurement at all.
  "Reproduced twice in effect" is therefore not supported by evidence — r02
  is at most non-contradicting. Both runs' causal write-then-delete cycles
  were harness-induced (r03: attempt-1's ENOSPC writes + harness cleanup;
  r02: env-leak-sized workload that never stressed capacity).
- **No clean, customer-shaped reproduction exists** (a guest workload that
  writes-then-deletes large data between checkpoints — temp files, scratch
  builds, DB rebuilds — without harness intervention). Per the reproduction
  rule this cannot be filed as a Bug. It is filed below as a
  contract-clarification/documentation ticket, which does not require a
  second reproduction because it makes no defect claim: the semantics are
  demonstrated by direct physical evidence in r03 and the gap is in
  guidance, not behavior.

## 3. Finding 2 — libvirt retains the failed backup's checkpoint after its CR is deleted (orphaned tree entry)

### Event sequence

1. **10:35:19** — retry-3 creates backup CR `vm-incremental-…-p01` and its
   libvirt checkpoint `…-10-35-19`.
2. **10:35:56** — backup fails (ENOSPC, Done=True with failure reason);
   tracker NOT advanced (still full checkpoint 09-14-05).
3. **~10:41** — the failed CR is deleted (Lead-approved; captured by the
   supplementary vmbackup-all-r03 watch, per WATCH-LOST M4 note). Deletion
   completes through the `backup.kubevirt.io/vmbackup-protection` finalizer.
4. **10:58:10 / 10:59:31** — captured checkpoint trees
   (`checkpoint-tree-post-retry5.txt`, final live reads) show:
   `root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)`.
   The tree strictly contains the live objects: an entry with no
   corresponding backup CR or tracker reference persists between the full
   and the successful incremental.

### Analysis

- **No functional impact in-run.** The orphan did not affect the successful
  incremental's checkpoint name, the single tracker advancement, or restore
  correctness (cumulative chain restore: 0 failures). The chain remains
  rebaseable through it.
- **CR-chain vs libvirt-tree divergence.** At the CR/tracker level the
  successful incremental is a child of the *full* checkpoint (tracker:
  full → 10-49-06; and the retry-5 copy demonstrably used 09-14-05 as its
  bitmap base — it copied the full 68 GiB dirty set, not just post-10-35-19
  changes). In libvirt's tree, however, 10-49-06 is *nested under the
  orphan* 10-35-19. Tree structure therefore does not reflect the logical
  backup chain: any consumer deriving chain membership or parentage from
  the libvirt tree alone would mis-model the chain.
- **Open semantics question.** Is the retention deliberate (e.g., checkpoints
  are only pruned on chain maintenance for tracker-advancing backups, so
  failed-backup checkpoints are never cleaned) or an oversight in the
  CR-deletion path? Repeated failed attempts would grow the tree with
  orphans indefinitely (hypothesis — not established; no repeated-failure
  evidence in this run).

### Reproduction status

Single run (r03). r02 had no failed-then-deleted backup CR (its incremental
passed), so no second reproduction exists. No spec §5 criterion mandates
tree = live objects, so this is an unresolved question / consistency
observation, not a violated criterion. Draft below stays in this analysis
until a second reproduction or an engineering answer establishes the
intended semantics.

## 4. Engineering-ticket drafts

> All three drafts remain in this analysis file. `bugs/` does not exist yet
> and contains no r02 drafts (the r02 HotplugFailed draft stayed in
> `analysis/20261015-cbtf04-r02-product-flow.md` §3 per its single-run
> status). Move-to-`bugs/` recommendations are stated per draft.

### Draft 1 — [Contract clarification]: incremental backup copy size is peak dirty volume since the last checkpoint, not logical change; destination sizing is undocumented

| Field | Value |
|---|---|
| Issue type | Contract clarification / Documentation (Improvement) — NOT a Bug claim |
| Owning component | KubeVirt/OpenShift Virtualization CBT backup (incremental copy sizing and API/doc surface; `VirtualMachineBackup` spec/status) |
| Priority | Unassigned pending triage (proposed medium: customer-visible capacity-failure mode with no sizing guidance) |
| Status / confidence | Semantics demonstrated by direct physical evidence in one run (r03); behavior data-correct (restore-verified); no defect claim, so single-run status is sufficient for a contract-clarification filing |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r03`, 2026-10-15 (UTC) — sole reproducing run. Run `20261015-cbtf04-r02` (same day) is non-contradicting only: its incremental fit its 30 Gi destination and no copy-size measurement was captured |
| Affected versions | OpenShift version UNKNOWN (not captured); CNV virt-controller image registry.redhat.io/container-native-virtualization/virt-controller-rhel9@sha256:23e9322e… (tag not captured); storage ODF/Ceph RBD (ocs-storagecluster-cephblockpool); guest RHEL 9 |

**Description (plain language).** An incremental CBT backup physically
copied 68 GiB (destination volume rbd-du usage 68 GiB; incremental artifact
qcow2 disk size 67.7 GiB) for a logical guest change of ~3 GiB (2 files
added, 1 modified). The difference is ~66 GiB of blocks written to guest
files that were subsequently deleted between the full checkpoint and the
incremental: change tracking marks blocks dirty on write and never un-marks
them on deletion, so the incremental must copy data that is already dead at
backup time. This is correct-by-design for block-level restore consistency
(deleted blocks differ from the base image; deletion churns FS metadata),
and the chain restore verified correct — but the API surface and
documentation observed give no warning that incremental destination
capacity must be sized to the *peak dirty volume since the last checkpoint*
(a quantity with no relation to logical change, and no observable bound
short of total disk capacity). A 30 Gi destination sized for a "3 GiB
change" failed mid-copy with ENOSPC after writing 29 GiB.

**Steps to reproduce.** On a dedicated cluster, VM with CBT enabled:
1. Take a full backup; note the checkpoint.
2. In the guest, write ~66 GiB of files, then delete them (any
   write-then-delete churn: scratch builds, temp files, DB rebuilds).
3. Make a small (~3 GiB) live change; provision an incremental destination
   sized near the logical change (e.g. 30 Gi for a 78 Gi disk); run the
   incremental backup.
4. Observe: the copy consumes the full dirty set (~68 GiB) and the backup
   fails with "No space left on device" once the destination fills.

**Actual result.** Run `20261015-cbtf04-r03`, ns `vm-cbt-demo`, tracker
`vm-tracker-20261015-cbtf04-r03` (uid 4e362574-dee7-4fec-bb8d-1ba46f814f02).
Full checkpoint 09-14-05 (Done=True 09:15:15Z). Attempt-1 guest mutation
(09:49:57→10:29:16Z) wrote 66×1 GiB files before guest ENOSPC (no backup
object created); files deleted by harness before retry. Retry-3 incremental
`vm-incremental-20261015-cbtf04-r03-p01` (uid f71e404c-c817-489b-ac39-7e38a007aed8),
checkpoint `…-10-35-19`, 30 Gi destination: filled to 29 GiB (rbd du),
`Done=True` / "Backup has failed: No space left on device" at 10:35:56Z,
tracker unchanged. Retry-5 on a 100 Gi destination: Done=True success
10:50:14Z, checkpoint `…-10-49-06`, **68 GiB copied** (rbd-du-retry5.txt;
qemu-img 67.7 GiB, backing file → live rootdisk, corrupt=false) for 3 GiB
logical; cumulative-chain restore matched 10 files / 10,737,418,240 B /
manifest SHA-256, 0 failures.

**Expected result / requested outcome.** Documentation and API guidance
state that incremental copy size is bounded by peak dirty volume since the
merge-base checkpoint, and that destinations must be sized accordingly (or
the product exposes a dirty-set size estimate — see triage question).
Acceptance: a customer following documented sizing guidance for a
write-then-delete workload between checkpoints does not hit mid-copy ENOSPC.

**Impact and workaround.** No data corruption (restore-verified; loud
failure). Impact is operational: mis-sized incremental destinations fail
mid-copy after writing up to the destination's capacity, wasting capacity
and time, with a retry required on a larger volume. Workaround: size
incremental destinations to expected peak dirty volume (or disk capacity),
and/or take a fresh full backup after large write-then-delete churn to
reset the dirty set.

**Additional information and evidence.**
`runs/20261015-cbtf04-r03/recovery/{rbd-du-retry5.txt, rbd-du-backup-volumes.txt, qemu-img-preserved-artifacts.txt, qemu-img-post-retry3.txt, guest-state-post-failure.txt, incremental-backup-post-retry3.yaml, tracker-post-retry3.yaml, done.json}`;
`observer/finding.md` (harness-vs-product classification); reports. r02:
`runs/20261015-cbtf04-r02/recovery/summary.json` (incremental 1000 files /
18.28 GiB fit 30 Gi — no copy-size artifact captured). Contradictory
evidence: none. Confidence limits: version tags not captured; incremental
chain extent map not capturable read-only (chain proven via backing-file
metadata + volume usage + semantic restore); the causal write-then-delete
cycle was harness-induced (failed attempt-1 + cleanup), not a clean
customer-shaped reproduction.

**Acceptance criteria.**
- Documented sizing rule for incremental destinations expressed in terms of
  dirty volume since the last checkpoint (with the write-then-delete churn
  case called out explicitly).
- If implemented: an exposed pre-copy dirty-set size or admission-time
  capacity check that rejects an incremental whose dirty set exceeds the
  destination, before any bytes are copied.

**Triage questions.**
- Is a dirty-set size (or estimated copy size) knowable before the copy
  starts, and should it be surfaced in `VirtualMachineBackup` status?
- Should the docs define incremental destination sizing relative to
  tracked-disk capacity rather than logical change?
- Does guest TRIM/discard (`fstrim`) shrink the dirty set on this path, and
  should that be recommended? (Hypothesis — untested.)

**Move-to-bugs/ recommendation:** file as Documentation/Contract
clarification now (no defect claim, single-run physical evidence
sufficient); do NOT classify as Bug unless a clean (non-harness-induced)
reproduction appears.

### Draft 2 — [Contract clarification]: failed backup terminates with condition Done=True carrying a failure reason

| Field | Value |
|---|---|
| Issue type | Contract clarification (failure semantics) — candidate Bug pending a second reproduction of a failed backup |
| Owning component | KubeVirt/OpenShift Virtualization backup controller (`VirtualMachineBackup` status conditions) |
| Priority | Unassigned pending triage (proposed medium: success/failure indistinguishable on the boolean alone) |
| Status / confidence | Observed once (r03 retry-3); loud failure (explicit reason, tracker not advanced) — the question is purely the meaning of `Done=True` |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r03`, 2026-10-15 (UTC) — single run. r02 had no failed backup object (not reproduced) |
| Affected versions | Same as Draft 1 (OpenShift/CNV versions not captured; virt-controller digest sha256:23e9322e…) |

**Description.** When an incremental backup fails mid-copy (destination
ENOSPC), the CR settles with conditions `{type: Progressing, status: False}`
and `{type: Done, status: True}`, both with reason `Backup has failed: No
space left on device`. `Done=True` is the same terminal signal that
accompanies successful backups (`Done=True` + "Successfully completed…").
A consumer polling `Done=True` as completion-success cannot distinguish the
two without parsing the free-text reason. The run's own E2E tooling had to
add a special case ("reached Done=True but the backup actually failed").

**Steps to reproduce.** Any incremental backup whose copy fails (e.g.
Draft 1's ENOSPC scenario); read `.status.conditions`.

**Actual result.** `vm-incremental-20261015-cbtf04-r03-p01` at 10:35:56Z:
Done=True, reason "Backup has failed: No space left on device", type
Incremental, checkpoint `…-10-35-19`; tracker unchanged at the full
checkpoint (`incremental-backup-post-retry3.yaml`;
`tracker-post-retry3.yaml`; launcher log "Backup has failed"; captured by
vmbackup-all-r03 watch and live reads).

**Expected result / requested outcome.** Clarify (or fix) the condition
semantics: what `Done=True` with a failure reason obligates consumers to
do, or a machine-readable success/failure distinction (e.g. a `Failed`
condition or Done reserved for success). Acceptance: a consumer can
determine backup success/failure from structured status without parsing
reason strings.

**Impact and workaround.** No state corruption in-run (tracker correctly
not advanced; retry succeeded). Risk is monitoring/orchestration silently
treating failed backups as complete. Workaround: alert on
`Done=True && reason != "Successfully completed…"`, which is brittle
string-matching.

**Additional information and evidence.** As Draft 1, plus
`recovery/incremental-followup-retry3.log` (E2E special-case message).

**Acceptance criteria.** Structured, machine-readable success/failure in
`VirtualMachineBackup` terminal status; documented semantics for `Done`
with failure reasons.

**Triage questions.**
- Is `Done` intended as "reconciler finished" rather than "backup
  succeeded"? If so, document it; if not, is a `Failed=True` condition
  warranted?
- Do CNV status conventions elsewhere reserve `Done=True` for success?

**Move-to-bugs/ recommendation:** stays in this analysis (single run, no
r02 counterpart) until a second run produces a failed backup object or
engineering confirms the intended semantics.

### Draft 3 — [Unresolved question]: libvirt checkpoint tree retains a failed backup's checkpoint after its backup CR is deleted (orphaned entry; tree diverges from CR chain)

| Field | Value |
|---|---|
| Issue type | Unresolved question / consistency observation (candidate Improvement) — not a violated criterion |
| Owning component | KubeVirt/OpenShift Virtualization backup controller ↔ libvirt checkpoint lifecycle (checkpoint creation/pruning on backup deletion) |
| Priority | Unassigned pending triage (proposed low: no functional impact observed in-run) |
| Status / confidence | Observed once (r03); no impact on naming, tracker, or restore; mechanism unknown |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r03`, 2026-10-15 (UTC) — single run. r02 had no failed-then-deleted backup CR (not reproduced) |
| Affected versions | Same as Draft 1 |

**Description.** A failed incremental backup's CR was deleted (after
ENOSPC; the deletion completed through the `vmbackup-protection`
finalizer), but its libvirt checkpoint (`…-10-35-19`) remains in the live
checkpoint tree between the full checkpoint and the successful incremental:
final tree `root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)`.
The tree strictly contains the live objects. Additionally, the tree
parentage diverges from the logical chain: the successful incremental's
copy used the full checkpoint as its bitmap base (it copied the full 68 GiB
dirty set, and the tracker advanced full → 10-49-06 directly), yet in
libvirt's tree its checkpoint is nested under the orphan. No functional
impact was observed — chain restore passed with 0 failures — but tree
structure alone mis-models the chain, and repeated failed attempts would
(hypothesis) accumulate orphans.

**Steps to reproduce.** CBT-enabled VM; full backup; run an incremental
that fails after checkpoint creation (e.g. Draft 1's ENOSPC path); delete
the failed backup CR; dump the launcher checkpoint tree
(`virsh checkpoint-list --tree` equivalent) and compare against live
backup CRs and the tracker.

**Actual result.** r03: retry-3 backup CR created 10:35:19Z (checkpoint
`…-10-35-19`), failed 10:35:56Z (ENOSPC, tracker unchanged), CR deleted
~10:41Z (Lead-approved; captured by vmbackup-all-r03 watch). Trees captured
10:58:10Z (`checkpoint-tree-post-retry5.txt`) and 10:59:31Z (final live
reads) show the orphaned `10-35-19` between root and the successful child
`10-49-06`. Observer flagged it (finding.md contradiction #3: "tree ⊃ live
objects").

**Expected result / requested outcome.** Clarify intended semantics:
either checkpoint-tree entries are removed (or reconciled/marked) when
their owning backup CR is deleted after failure, or the retention is
documented as deliberate (with the chain-derivation caveat). Acceptance:
the relationship between deleted backup CRs, tracker state, and the
libvirt checkpoint tree is specified; tree consumers can derive the live
chain.

**Impact and workaround.** None observed in-run (restore correct, tracker
correct). Theoretical risks (hypotheses): unbounded tree growth under
repeated failed attempts; mis-modeled parentage for tooling that reads the
tree; interaction of future prune/rebase operations with orphaned entries.
No customer mitigation identified from this run.

**Additional information and evidence.**
`runs/20261015-cbtf04-r03/recovery/{checkpoint-tree-post-retry5.txt, checkpoint-tree-post-incremental.txt, incremental-backup-post-retry3.yaml, tracker-post-retry3.yaml, done.json}`;
`observer/finding.md` contradiction #3; `observer/WATCH-LOST` M4 (CR
deletion ~10:41Z captured by supplementary watch). Contradictory evidence:
none.

**Acceptance criteria.**
- Specified behavior for libvirt checkpoints whose owning backup CR is
  deleted after a failed copy (removed, retained-with-reason, or
  reconciled).
- If removal is chosen: failed-then-deleted backups leave no tree entry,
  and subsequent successful incrementals still chain and restore correctly.

**Triage questions.**
- Is the checkpoint retained because pruning only runs on
  tracker-advancing (successful) backups, or is deletion-path cleanup
  expected to remove it and missed it?
- Does the retained orphan affect `checkpoint-delete`/rebase/prune
  operations later (e.g. removing the full checkpoint while an orphan
  references it)?
- Is tree parentage (child-of-orphan) ever used by restore tooling, given
  the tracker/CR chain differs?

**Move-to-bugs/ recommendation:** stays in this analysis (single run, no
violated criterion). Reassess on a second failed-backup deletion or an
engineering answer.

## 5. Related observation — r02's HotplugFailed detach finding now has its second run-label reproduction

The `HotplugFailed` / `lstat … disk.img` event on successful backup detach
(single-run draft at `analysis/20261015-cbtf04-r02-product-flow.md` §3)
**reproduced in r03**: events watch shows the identical pattern on
`vm-20261015-cbtf04-r03` at 09:15:14Z (count 1→2 within the second, during
teardown of the full backup's target volume), again on a fully successful
pass (Done=True success reason, cleanup complete, PVC Bound). It also fired
on an unrelated same-cluster VM (`vm-20261015091633-silent-wolf-4eb4`,
09:19:39Z and 09:21:51Z, full and incremental passes), further supporting
the r02 conclusion that it is workflow-typical, not chaos-attributable.
Per the reproduction rule, the r02 draft now meets the two-run-label bar
(r02 + r03) and is eligible to be moved into `bugs/` as a candidate Bug —
Lead's call; this analysis does not duplicate the draft. No functional
impact in r03; classified HELD-with-anomaly in row 6 of §1.

## 6. Follow-up hypotheses (labeled — not established mechanisms)

- **HYPOTHESIS (bitmap semantics — high confidence, not code-verified):**
  the dirty bitmap marks blocks on write and retains them until the next
  checkpoint merge; file deletion never un-dirties blocks (deletion itself
  dirties FS metadata and possibly the freed blocks). Supported by the
  arithmetic: 68 GiB copied ≈ 66 GiB dead writes + ~3 GiB live change, and
  by the copy using the full checkpoint (09-14-05) as base despite the
  intervening 10-35-19 checkpoint.
- **HYPOTHESIS (TRIM interaction):** guest-level discard (`fstrim`) after
  file deletion could allow the copy engine to skip or zero-detect freed
  blocks, shrinking the incremental. Untested in this run; would change the
  sizing guidance in Draft 1.
- **HYPOTHESIS (no preflight sizing):** the copy path has no dirty-set-size
  estimation or admission-time capacity check; ENOSPC surfaces only from
  the kernel mid-copy (29 GiB written before failure). Supported by the
  absence of any size-related status field in the failed CR.
- **HYPOTHESIS (checkpoint retention is a pruning-path gap):** libvirt
  checkpoints are pruned only during successful chain maintenance, so a
  checkpoint created by a backup that fails and whose CR is later deleted
  is never visited by cleanup — predicting unbounded orphan accumulation
  under repeated failures. Consistent with the single observed orphan;
  contradicted-if a second failed-then-deleted backup shows its checkpoint
  removed.
- **NON-hypothesis (ruled out):** chaos causation of any finding — both
  findings occurred in the post-chaos recovery sequence, minutes after
  failover on a settled control plane (2/2 Ready, lease stable), and
  involve no controller-availability dependency. Likewise ruled out: silent
  corruption — all restores hash-verified; both observed failures were loud
  (explicit reasons, tracker untouched).

## 7. Customer recommendation

Concrete only for Finding 1: size incremental backup destinations to the
expected **peak dirty volume since the last checkpoint** (bounded by
tracked-disk capacity), not the logical data change; and after large
write-then-delete churn (scratch builds, temp files, DB rebuilds) between
checkpoints, either expect an incremental approaching the churn volume or
take a fresh full backup to reset the dirty set. For Findings 2 and 3 no
customer action is supported by this run (no functional impact observed).
