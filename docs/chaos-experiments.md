# CBT Chaos Campaign — Final Report

**Campaign window:** 2026-10-14 → 2026-10-15 · **Cluster:** OpenShift 4.22 / OpenShift Virtualization 4.22.12 (kubevirt v1.8.4-era backup.kubevirt.io/v1alpha1) · **Harness:** this repository (`make e2e`, per-scenario chaos triggers, read-only observer agents, standing Judge/WeaknessAnalyst review team)

## Executive summary

**4 product defects found: 1 availability/wedge, 1 silent corruption, 2 observability.** The wedge family reduces to a single root cause — **push-mode backups have no terminal resolution for permanent failures, so a permanently-failing backup start requeues forever, wedging the backup CR and (via the one-backup-per-source rule) the entire VM's backup capability** — reproduced from two independent entry paths (corrupt checkpoint bitmap; tracker deleted mid-copy) with a verified recovery matrix. The silent-corruption defect (target-PVC ENOSPC mid-copy) reports Done=True while the destination holds a metadata-only overlay of the live source disk: restore-while-alive "succeeds" by reading through to the running VM, and the disaster-case restore delivers nothing.

Every verdict is backed by live evidence (watch-stream resourceVersion orderings, controller logs, byte-level destination measurements, hash-verified restores); two engineering ticket drafts with reproduction steps and recovery matrices are filed at scenario level (`CBT-EXP-06/bugs/`, `CBT-EXP-07/bugs/`).

## What was executed

| Run | Scenario | Verdict | One-line result |
|---|---|---|---|
| 20261014-cbtf09-r04 | F-09 I/O hog during full (Jira baseline) | PASS | 69s vs 52-55s baseline (+27-33%); correctness preserved |
| 20261014-cbtf10-r04 | F-10 CPU hog during full (Jira baseline) | PASS | 55s, no degradation (copy is I/O-bound) |
| 20261014-cbtf11-r04 | F-11 netfilter on launcher (Jira baseline) | PASS | 53s; backup data path confirmed node-local |
| 20261014-cbti04-r04 | I-04 dsync I/O hog during incremental (Jira baseline) | PASS | 18s in baseline band — even synchronous contention absorbed |
| 20261014-exp01-r01 | EXP-1 VM hard restart between backups (checkpoint redefinition) | PASS | Chain survives; redefinition ~2min; no full fallback |
| 20261014-exp02-r01 | EXP-2 backup CR deleted mid-copy (abort semantics) | PASS | 3s finalizer removal; clean detach; no leaks; recovery verified |
| 20261014-exp03-r02 | EXP-3 controller leader kill ×3 at completion | PASS (resilience) / INCONCLUSIVE (race) | Race window sub-second (~19 RVs); unreachable by pod deletion |
| 20261014-exp05-r01 | EXP-5 SIGSTOP→resume of controller at completion edge | PASS | Ghost transient proven EVENT-ONLY (organic rv-pair); controller freeze harmless |
| 20261014-exp06-r01 | EXP-6 per-disk bitmap loss across redefinition (2-disk VM) | **FAIL — DEFECT** | Redefinition accepts broken checkpoint; incremental wedges in Initializing forever (19 retries/22min, no terminal state, errors invisible on the CR) |
| 20261014-exp07-r01/2/3 | EXP-7 late-copy ENOSPC on target | **FAIL — DEFECT** | Done=True with 4.25MiB overlay of the live source (0.02% of 17.4GiB); chain advances onto the shell; error surfaces nowhere |
| 20261014-exp08-r01 | EXP-8 tracker deleted mid-copy | **FAIL — DEFECT (wedge entry #2)** | Backup wedges; wedged-CR deletion wedges (abort needs tracker); all new backups on the VM rejected |
| 20261014-exp09-r01 | EXP-9 Windows coverage (F-09 cross-OS) | PASS (Windows baseline; hog placement-invalid) | Full 49s / incr 15s / restore PASS; **ghost event ABSENT on Windows** (0/1 vs 7/9 RHEL) |
| 20261014-exp10-r01+r02 | EXP-10 (P5) handler outage in redefinition window | RESILIENT (closed) | Real non-422 redefinition error captured: one requeue, same-second self-heal; persistent-error wedge unreachable by external injection |

Invalid/harness-iteration runs (all fail-closed, archived): EXP-3 r01 (watcher brace bug), EXP-5 r01b (container-pid1 SIGSTOP no-op), EXP-6 manifests ×4 (adoption labels/annotations/SSH-service/ENOSPC), EXP-9 ×4 (OOBE-secret RETURN-trap bug — fixed in `scripts/windows-oobe-secret.sh`; jq-filter restoration).

## Product findings

### 1. Backup wedge — no terminal resolution for permanent failures (highest severity)

- **Ticket:** `cbt-chaos/scenarios_v2/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md` (merged EXP-6 + EXP-8)
- **Entry path A (EXP-6):** vdb checkpoint bitmap removed (QMP, fail-closed verified) → redefinition accepts the broken checkpoint (tracker claims both volumes) → incremental wedges in Initializing: 19 retries of the permanent libvirt 400 "checkpoint inconsistent: missing or broken bitmap for disk vdb", no terminal condition, stuck finalizer, leaked hotplug-mounted target PVC, and all 19 BackupError events land on the VMI while the backup CR's own event stream stays EMPTY.
- **Entry path B (EXP-8):** tracker deleted mid-copy (404-verified) → same wedge; additionally the wedged CR's own deletion wedges (the abort path needs the tracker — "update backup is deleting" loop, 35+ min deletion limbo) and all NEW backups on the VM are rejected ("in progress for source") — VM-wide backup deadlock with no API-only recovery.
- **Root cause (one fix):** no max-retry/deadline terminalization for permanent backup-start/cleanup failures. A terminal Failed (releasing the finalizer, detaching the PVC) fixes both paths.
- **Verified recovery matrix:** (a) delete wedged CR — works with tracker present (seconds; EXP-6a) but wedges without it; (b) fresh `forceFullBackup` — works (~20s); (c) recreate/delete tracker — unblocks the abort; next backup cleanly falls back to Full. Operator runbook in the ticket.
- **Positive backstop:** QEMU's checkpoint-consistency check prevents the hypothesized silent disk-drop — no Done=True-with-missing-disk occurred.

### 2. Silent corruption on copy failure (worst class; kubevirt#17578 class on shipped CNV 4.22.12)

- **Ticket:** `cbt-chaos/scenarios_v2/CBT-EXP-07/bugs/backup-reports-success-with-no-data-on-target-enospc.md`
- **Reproduction (×3, deterministic):** backup target PVC pre-filled to ~127MiB free vs 17.4GiB workload → backup Done=True "Successfully completed VirtualMachineBackup" in 3 seconds; destination holds a 4,456,448-byte qcow2 whose **backing file is the LIVE VM's source disk** — the copy never ran.
- **The triad (all live-verified):** Done=True always; restore-while-VM-alive "succeeds" in 15.8s by reading through the overlay to the live source (first GiB md5-identical) — **normal restore verification cannot detect this class**; disaster-case restore (VM gone) fails with "Could not open backing file" — the backup delivers nothing exactly when needed.
- **Chain propagation (verified):** the tracker advances onto the empty backup's checkpoint; a subsequent workflow incremental was refused only by the HARNESS's checkpoint guard — the product raised no objection.
- **Error visibility:** the ENOSPC never appears in any object, condition, or event — the only trace is the ghost event (see finding 3).
- **Operator heuristic (until fixed):** a "successful" backup whose duration is implausibly short for the VM's data size, or whose destination usage did not grow, wrote nothing.

### 3. Ghost event — two-sided observability defect

`VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` fires at the instant backups complete successfully (7/9 RHEL runs) — **and is simultaneously the ONLY visible trace of real copy failures** (EXP-7's ENOSPC surfaced solely as this event). Event-based monitoring is thus both falsely alarmed on success and misleadingly informed on failure. Windows: absent in 1/1 run — localization toward the RHEL hotplug/fsfreeze path. Proven EVENT-ONLY (EXP-5 organic rv-pair: event rv after terminal Success rv; condition never left Success). Fix direction: suppress the derivative event on terminal backups; surface real copy errors on the backup CR.

### 4. Cancellation-reason conflation (minor)

User-initiated abort terminates with reason `Backup has failed: backup aborted: Operation canceled` — the "Backup has failed" prefix makes operator cancellation indistinguishable from errors without reason-parsing (EXP-2).

### Minor observations

- HotplugFailed teardown noise at backup completion (lstat races during volume unmount) — cross-OS (RHEL + Windows), no outcome impact.
- EXP-6's backup-CR event stream empty while errors land on the VMI (observability gap folded into ticket 1).
- Degradation boundaries (from this + prior T-family): CPU/mem absorbed; I/O 64 dsync writers = +48%; capacity theft → clean ENOSPC failure (early); VM restart → 10s recovery, chain intact.
- Windows performance comparable to RHEL (49s vs 53-69s full for the same workload).

## Resilience results (what did NOT break)

Controller leader kills at any achievable timing (EXP-3); 2-6s controller process freeze at the completion boundary (EXP-5); VM hard restart between backups (EXP-1); mid-copy backup-CR deletion with tracker present (EXP-2); transient non-422 redefinition errors (EXP-10: one requeue, same-second self-heal); sustained I/O contention incl. synchronous writes (F-09/I-04); launcher pod network isolation (F-11); virt-handler outage with collateral VMIs unaffected (EXP-10). Every successful backup restored hash-identical (100% across ~20 verified restores).

## Harness lessons (not product findings)

1. **Watch streams beat polling** — decisive twice (transient `checkpointRedefinitionRequired` invisible to 0.2s polling; EXP-5's rv-pair proof).
2. **Fail-closed injection proofs** — every leg verifies its injection actually landed (state-T checks, 404 verification, restart evidence); every harness miss was caught, never recorded as a product result.
3. **Control legs on every new harness path** (2-disk VMs, pre-filled PVCs) — new machinery is new failure modes.
4. **Per-disk / per-file restore granularity and destination-size throughput arithmetic** as corruption discriminators (aggregate checks can mask a wholly absent disk; a 3s "copy" of 17GiB is proof by arithmetic).
5. **Pre-registered alternative-outcome criteria** (adopted after EXP-3's window miss).
6. Tooling defects catalogued in `cbt-chaos/krknctl-bugs.md` (#1-12, incl. the OOBE-secret RETURN-trap fix and node image-pull/IfNotPresent workaround).
7. Observer supervision: idle watch streams drop ~1h; supervisor-wrapped generations close the gap.

## Untested claims (with rationale)

1. **Persistent non-422 redefinition-error wedge / cross-backup blast radius via the tracker:** rendered unreachable by external injection (window ~1s, externally unobservable; transient case proven self-healing in EXP-10). Requires in-process fault injection on the controller→handler subresource path. Note: blast radius was NOT refuted — it was unreachable from this entry path; VM-wide stands as observed (EXP-8), multi-VM-via-tracker remains untested.
2. **Windows I/O contention:** the Windows default variant provisions on Ceph RBD (placement-invalid for the HostPath hog); needs an O-family Ceph-path injection or a HostPath-pinned Windows manifest.
3. **Ghost-event Windows rate beyond n=1.**
4. **fsfreeze leak on daemon death:** covered by design (source: freeze timeout=0); the alive-VM leak question was closed by ride-along (post-backup guest writes succeeded on both OSes).
5. **kubevirt#17578 fix status in main:** verify before choosing backport-request vs new-bug framing for ticket 2.

## Where the evidence lives

Per-run: `cbt-chaos/scenarios_v2/<SCENARIO>/runs/<RUN_ID>/` (trigger logs, object snapshots, observer streams, reports) and lifecycle JSON under `runs/<RUN_ID>/`; both hosts (local checkout + cloud05). Bug tickets: `CBT-EXP-06/bugs/`, `CBT-EXP-07/bugs/`. Prior-campaign context (F/T/O/R/X families, 2026-10-13) predates this report; this campaign's runs are all `20261014-*`/`20261015-*`.
