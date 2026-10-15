# CBT-F-04 Re-run Matrix Proposal — after closed run 20261015-cbtf04-r03 (Leg 2 complete)

Author: Variation Decider (propose only; Lead executes, human approves).
Basis: closed runs `20261015-cbtf04-r02` (Leg 1, PASS WITH FINDINGS) and `20261015-cbtf04-r03` (Leg 2, PASS WITH FINDINGS — clean re-run with fixed harness and tightened evidence: Full, rhel9, large-odf/ODF Ceph-RBD, 8-file/8 GiB workload per pinned sizing, controller-leader kill 17 s into the active copy). r03 outcomes: HotplugFailed/detach anomaly reproduced and classified workflow-typical (matches the r02 success pattern; not chaos-attributable); `qemu-img info`/extent-map evidence captured on the full artifact (incremental chain extent map not capturable read-only — recorded limitation); two NEW product findings: (1) CBT retained dirty blocks from guest files written-then-deleted between checkpoints — incremental physically copied ~68 GiB for a 3 GiB logical change, overflowing the 30 Gi destination; (2) libvirt retained the failed backup's checkpoint in the tree after its backup object was deleted. Harness debt open: incremental-destination sizing pin (3rd env-leak-class occurrence; mandatory edit pending) and the rogue-lifecycle probe fix. r03 also hit the same-VM recovery hard stop (destination ENOSPC) — human-authorized retry, ultimately attributed to harness-induced dirty blocks, not product; run closed PASS WITH FINDINGS.

## Decision: NEXT LEG (2 legs remain; baseline + clean re-run + 2 = 4-leg cap)

Rationale: r03 answered the Leg-2 questions (HotplugFailed is benign workflow noise in two independent runs; allocation-map evidence corroborates the restore evidence; the harness env-leak fix changed no product outcome), so same-parameter confirmation is again below the marginal-value line. What remains above it, in priority order: (a) an unresolved product finding needing reproduction under deliberate, clean conditions — the dirty-block/bitmap-retention behavior was observed only as a harness accident (blocks dirtied by a failed first incremental pass); a deliberate write-then-delete workload between checkpoints with a correctly sized destination would test the CBT bitmap semantics cleanly and validate the customer sizing guidance (decision framework rule 2: finding reproduction outranks new coverage); (b) the window-position coverage gap — both runs hit only the early-mid window; reconciliation/tracker exactly-once semantics near copy completion (closest to the detach and checkpoint-commit moments) remain untested, and the late window is the likeliest place to reproduce finding 2's orphaned-checkpoint class. The HPP backend leg is DROPPED: its primary motivation (third data point on HotplugFailed across a different CSI detach path) evaporated when r03 de-escalated that anomaly to workflow-typical, and the residual question (backend independence of already-twice-proven core criteria) now fails the marginal-value test against the two questions above under the 4-leg cap. Incremental-mode chaos remains NOT proposed: the Jira issue and spec scope disruption to the full-backup copy phase — an improver matter, not a variation.

---

## Leg 1 (baseline, run): 20261015-cbtf04-r02

- Parameters: TYPE=full, VM_OS=rhel9, MANIFEST_VARIANT=large-odf (ODF Ceph-RBD), GUEST_BASE_FILE_COUNT=1000 / 1024 MiB files, injection at copy-start +17 s (early-mid window).
- Verdict: PASS WITH FINDINGS. Proved: data-plane copy survives leader kill, exactly-once tracker advancement, attachment cleanup, chain + restore correctness on ODF/RHEL9, early window. Left open: HotplugFailed detach anomaly; missing qemu-img allocation-map evidence.

## Leg 2 (DONE): 20261015-cbtf04-r03 — clean re-run, fixed harness, tightened evidence

- Parameters: identical to the approved reproduction leg — Full, rhel9, large-odf/ODF, spec-pinned 8-file/8 GiB workload, same early-window signal; env-leak fix applied; detach/hotplug event capture and qemu-img inspection added.
- Verdict: PASS WITH FINDINGS. Proved: every acceptance criterion re-passed under the fixed harness; copy uninterrupted through leader failover (09:14:27Z kill → 09:15:15Z Done=True); tracker advanced exactly once per checkpoint (failed intermediate attempts left it unchanged); full artifact qcow2 78.1 GiB, corrupt=false, complete extent map; restores matched with 0 hash failures. HotplugFailed reproduced and classified workflow-typical (not chaos-attributable) — question closed, no escalation.
- New findings to carry forward: (1) CBT dirty-block retention — write-then-delete churn between checkpoints inflates the incremental to peak dirty volume (~68 GiB physical for 3 GiB logical), overflowing an undersized destination; (2) libvirt retained the failed backup's checkpoint (10-35-19) in the tree after approved object deletion — orphaned child in chain.
- Hard-stop event: same-VM recovery failure on first incremental pass (30 Gi destination ENOSPC) — stopped and asked per skill; human-authorized retry with 100 Gi destination succeeded; root cause attributed to harness-induced dirty blocks, not product.
- Harness debt recorded (improver track, preconditions for Leg 3): incremental-destination sizing pin in the trigger (3rd env-leak-class occurrence; mandatory edit pending) and the rogue-lifecycle probe fix.

## Leg 3 (proposed): Dirty-block / CBT bitmap semantics — deliberate write-then-delete, correctly sized destination

- Parameters: chaos parameters identical to baseline (Full, rhel9, large-odf/ODF, pinned workload, early-window leader kill — this leg does not vary the chaos dimension); the variation is workload sizing in the post-chaos phase only: between full-backup completion and the same-VM incremental follow-up, deliberately write then delete a known volume of guest data (e.g. ~60 GiB across a few large files), record exactly what was written/deleted, then run the incremental with a destination pre-sized to peak dirty volume (≥ 70 Gi, using the corrected 100 Gi class) — never an undersized destination.
- Question answered: does CBT deliberately retain dirty blocks for deleted guest files (bitmap tracks block writes, not file liveness), and does the incremental then copy peak-dirty rather than logical-change volume under clean, non-accidental conditions? Quantifies the retention ratio with a controlled manifest instead of r03's harness accident, and validates the customer sizing guidance (size incremental destinations to peak dirty volume).
- Finding/gap resolved: product finding #1 (dirty-block retention) reproduction under deliberate conditions; converts the accidental r03 observation into controlled evidence for the engineering follow-up ticket.
- Preconditions: the pending trigger amendments land first — the incremental-destination sizing pin (mandatory edit) extended to accept an explicit, make-command-line destination size (never exported env), plus the deliberate write-then-delete step between full and incremental stages; amendments pass preflight self-rehearsal and checksum checks before execution. The write-then-delete step and explicit destination sizing are additions to the spec's follow-up sequence — the improver's harness amendment must carry spec acknowledgment (the chaos phase itself is unchanged and spec-compliant). Fresh RUN_ID/VM; no backup-reset; workload values passed as make command-line arguments. Watch the hard stops: the destination MUST be pre-sized so the same-VM recovery failure (ENOSPC) stop condition cannot recur for product-side reasons — an overflow on this leg would itself be evidence, but only if the destination was correctly sized to the recorded write volume.
- Stop condition: incremental fails on a correctly sized destination (would indicate bitmap over-retention beyond written bytes — product defect, escalate) or checkpoint/tracker misadvancement → stop the matrix, file the defect. Standard hard stops below.

## Leg 4 (proposed): Late-window injection — vary injection window position only

- Parameters: identical to baseline except the observer arms Krkn for a late-T-PROG injection — leader deletion targeted at roughly the last quarter of the copy window. r03's timing evidence makes this reachable: copy ran 09:14:09.97Z → 09:15:15Z (~65 s), so the arm point is ~copy-start +45–50 s, established from launcher copy-progress timing, not a sleep. Standard (correctly sized) incremental destination per the Leg-3 sizing discipline.
- Question answered: does a leader restart just before copy completion still reconcile, clean up the hotplug attachment, and advance the tracker exactly once — i.e., is the reconciliation path window-position-independent? The restart lands closest to the detach and checkpoint-commit moments, making this the likeliest leg to reproduce finding #2's orphaned-checkpoint class (a backup object failing or being deleted near commit).
- Finding/gap resolved: window-position coverage gap (only early-mid hit in r02 and r03); second, controlled data point on the libvirt orphaned-checkpoint behavior.
- Preconditions: copy-window duration re-measured from Leg 3's launcher logs must confirm a reliable late-window arm point; Leg 3's trigger amendments (destination sizing pin) landed and preflight-clean; fresh RUN_ID/VM; no other dimension varied.
- Stop condition: any duplicate/replayed checkpoint or stale attachment (cleanup race confirmed), or an orphaned checkpoint left in the libvirt tree after a completed (non-deleted) backup → stop, escalate as product defect. Standard hard stops below.

### Dropped: HPP backend leg (was old Leg 4)

- Reason: r03 de-escalated HotplugFailed to workflow-typical in two runs, removing the leg's primary motivation (backend-specificity of the detach event). The remaining question — backend independence of core criteria already proven twice on ODF — fails the marginal-value test against the dirty-block reproduction and window-position questions under the 4-leg cap. Do not substitute an unsupported backend; if HPP coverage is later wanted, it needs a fresh matrix proposal with its own capacity assessment.

---

## Cumulative matrix

| Leg | Run | Mode | Window | Backend | OS | Sizing | Verdict |
|-----|-----|------|--------|---------|-----|--------|---------|
| 1 | 20261015-cbtf04-r02 (closed) | Full | early-mid (+17 s) | ODF Ceph-RBD | RHEL9 | 1,000 files / ~17 GiB | PASS WITH FINDINGS |
| 2 | 20261015-cbtf04-r03 (closed) | Full | early-mid (+17 s) | ODF Ceph-RBD | RHEL9 | pinned 8 files / 8 GiB | PASS WITH FINDINGS (HotplugFailed closed; new: dirty-block retention, orphaned checkpoint) |
| 3 (proposed) | — | Full | early-mid (same) | ODF Ceph-RBD | RHEL9 | post-chaos write-then-delete churn + correctly sized (100 Gi) incremental dest | dirty-block/bitmap semantics reproduction (finding #1) |
| 4 (proposed) | — | Full | late (last ~25% of copy) | ODF Ceph-RBD | RHEL9 | same as baseline | window-position coverage; orphaned-checkpoint second data point |

Uncovered after this matrix (accepted residual): Incremental-mode chaos window (spec-scoped to the full-backup phase — improver finding if wanted), HPP/other storage backends (dropped, see above), Windows/Debian OS, HPP × late-window combination, incremental chain extent-map capture (read-only limitation — improver/evidence-scope item). Each fails the marginal-value test against the findings legs 3–4 target.

## Hard-stop conditions (Lead enforces; apply to every leg)

1. Any FAIL verdict on any leg → matrix stops; findings escalated before further cluster time.
2. Two consecutive BLOCKED legs → stop and reassess harness, not the scenario.
3. Same-VM recovery failure (post-chaos follow-up cannot run on the recovered VM) → stop, preserve resources. (r03 hit this once — ENOSPC attributed to harness-induced dirty blocks; user-authorized retry passed. Legs 3–4 must pre-size destinations so this stop can only fire for product-side reasons.)
4. Cluster degradation or capacity starvation (controller replicas not recovering, PVCs pending, node pressure) → stop immediately.
5. Dirty-block reproduction failing on a correctly sized destination (bitmap over-retention), checkpoint/tracker misadvancement, or an orphaned checkpoint after a completed non-deleted backup → stop and file the product defect.
