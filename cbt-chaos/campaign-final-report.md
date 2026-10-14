# CBT Chaos Campaign — Final Report
**Campaign window:** 2026-10-12 22:30Z → 2026-10-14 02:00Z (~27.5 hours)
**Cluster:** OpenShift 4.22.15, CNV 4.22.12 (kubevirt v1.8.4), ns `vm-cbt-demo`, CBT worker node d38-h18-000-r660, HostPath CSI pool (cbt-demo-hpp → /var/hpvolumes/csi on /dev/sdb, 1.5TiB), ODF/Ceph RBD 105TiB available
**Drive host:** cloud05 (`/root/virt-cbt-lab`), KUBECONFIG=/root/mno/kubeconfig
**Workload standard:** RHEL9 + MANIFEST_VARIANT=default (HPP), 1000 files × 15-20MiB (~17.5GiB guest data); per-scenario deviations documented in each report

---

## 1. Executive summary

**32/32 scenarios closed: 30 PASS, 2 FAIL.** All 28 original Jira scenarios (F-01…13, I-01…08, R-01…03, X-01…04) plus 4 campaign-authored threshold hunts (T-01…04, per user directive). A Windows extension was started (W01: full-backup PASS on both attempts) but held before the chaos variants per user direction 2026-10-14, after the Windows guest-agent flap defect was root-caused and fixed in the harness.

The two FAILs are genuine engineering findings:
- **CBT-F-05** — virt-handler killed during hotplug teardown leaks the VolumeAttachment (stale mount, EBUSY loop, cross-node restore blocked 53 min). Product defect; workaround validated; bug draft written.
- **CBT-I-02** — launcher killed mid-incremental: the chain-clearing semantic is by design, but the workflow offers NO sanctioned incremental retry after failure (`incremental_failed` state locks every stage type out). Workflow defect, hit 3× (twice on RHEL, once on Windows with zero chaos).

**Headline resilience finding:** the CBT copy path is exceptionally robust — it survived total network blackouts (pod AND host netns), full CPU saturation (112/112 cores), 92% memory pressure, controller leader kills at every lifecycle point, and kubelet restarts, with zero data-integrity failures anywhere in the campaign (every restore verification bit-exact). The real break modes are **process kills** (QEMU/launcher death — clean failures, correct attribution) and **storage capacity** (ENOSPC — clean failures, VM auto-recovers when space returns).

---

## 2. Scorecard

| Family | Theme | Scenarios | PASS | FAIL | Notes |
|---|---|---|---|---|---|
| F-01…13 | Full-backup phase chaos | 13 | 12 | 1 (F-05) | launcher/container/controller/CSI/ENOSPC/io/cpu/network kills |
| I-01…08 | Incremental phase chaos | 8 | 7 | 1 (I-02) | VM restart, kills, contention, ENOSPC, guest agent, container |
| R-01…03 | Restore/verify phase chaos | 3 | 3 | 0 | verifier kill, io contention, storage-plugin eviction |
| X-01…04 | Node-level & combined | 4 | 4 | 0 | memory hog, kubelet restart, network blackout, combined |
| T-01…04 | Threshold hunts (authored) | 4 | 4 | 0 | CPU, memory, io, capacity floors |
| **Total** | | **32** | **30** | **2** | |
| W01 (held) | Windows baseline | 1 | (full PASS ×2; incremental blocked by harness bug, then held) | — | evidence archived; agent-flap fix applied |

### Execution stats
- **~33 valid scenario runs + ~50 invalid harness legs** (all preserved with failure analysis; invalid legs root-caused, never repeated unchanged)
- **127 run trees** under virt-cbt-lab `runs/` (local + remote, md5-verified reports)
- Runtime split: ~40% test execution, ~35% harness engineering, ~15% investigation/triage, ~10% reporting
- Incidents handled: pool ENOSPC ×2 (capacity guards added), krkn rule-leak node outage (88 min, recovered via IPv6 SSH without reboot), lab network outage (54 min)

---

## 3. Product findings for engineering

### 3.1 Confirmed defects (FAIL verdicts)
1. **F-05 — virt-handler kill during hotplug teardown leaks VolumeAttachment.** Replacement handler marks the volume unmounted despite EBUSY; external-attacher finalizer keeps the VA; `/dev/rbd7` stays mounted in the replacement handler; Ceph watcher held; `rbd unmap` EBUSY 238 retries/2h+. Restore pod on another node stuck Pending (Multi-Attach) 53 min. Data itself intact (17/17 after cleanup). Workaround: delete orphaned VA + restart handler. Bug draft: `CBT-F-05/bugs/leaked-hotplug-attachment-on-handler-restart.md`.
2. **I-02 (+3 instances) — no sanctioned retry after a failed incremental.** After mid-copy launcher death, tracker clears (`CheckpointRedefinitionFailed` — by design), but the workflow state machine locks the run at `incremental_failed`: `TYPE=incremental` needs `incremental_ready`, `TYPE=recover` only admits failed FULL, `TYPE=verify` needs a completed pass plan, `TYPE=extend` needs `complete`. The Jira's "incremental can be retried" is unreachable. Hit on RHEL (I-02 r04), on a clean Windows run (W01 r01 — zero chaos), and again on W01 r02.

### 3.2 Quantified thresholds (T-family, per user directive)
| Dimension | Threshold | Evidence |
|---|---|---|
| CPU | **None** — 112/112 cores @100% → 62s (baseline 52-58s); copy is I/O-bound | T-01 a-d |
| Memory | **None** — 92% node memory (427g) → 58s, zero OOM; copy is page-cache-resident | T-02 a-d |
| Same-device I/O | Degradation begins **32→64 dsync workers**; +48% at 64 (86s), graceful, no failure | T-03 a-d |
| Storage capacity | Full backup needs **80-100GiB pool headroom**; full cycle **>100GiB**; below → clean ENOSPC; VM auto-unpauses after space restored | T-04 a-c |

### 3.3 Notable positive behaviors (worth keeping as regression expectations)
- Backup completes during **total network blackout** (pod netns AND host netns) — data movement is node-local; network is control-plane only (X-03; topology caveat: on RBD backends a host-netns blackout would stall writes)
- Controller leader kills at every lifecycle point (start/mid-copy/cleanup/pre-tracker-write) recover cleanly; tracker updates exactly once in every case; lease failover ~17-21s
- Kubelet restart mid-copy: zero impact, node never left Ready (X-02 dry-run + live)
- Combined failures (io-hog + launcher kill) fail cleanly with **correct dominant-cause attribution** in the Done reason (X-04)
- ENOSPC failures are always clean: accurate reason, tracker untouched (full checkpoint held when VMI alive), VM PausedIOError → auto-unpause on space recovery
- Container-kill vs pod-kill have **different tracker semantics** (hold vs clear) — both recover via checkpoint redefinition (I-08 vs I-02)
- Restore-phase chaos: verifier waits cleanly at scheduling when storage-plugin is down (Pending, never crash-loops; starts seconds after plugin returns) (R-03)

### 3.4 Gaps worth upstream discussion
- **HPP provisioner admits PVCs on requested size regardless of actual filesystem free space** (fair-sharing hazard; T-04)
- F-07 observability: `VirtualMachineBackupFailed: VMI backup status was lost` warning event emitted same-second as success on genuinely-successful runs — event text alone never determines verdict
- qemu-ga on Windows restarts under guest-exec load (pid-table wipe; W01) — arguably a guest-agent defect worth an upstream look

---

## 4. krkn/krknctl defects (11, all source-verified + worked around)

Full detail: `cbt-chaos/krknctl-bugs.md`. Summary: (1) hog image crashes on readOnlyRootFilesystem; (2) boolean flags have no defaults; (3) `--namespace` is the target's namespace (help text misleading); (4) `--pod-name` doesn't populate plugin `target` — CLI/plugin schema disagreement; (5) `--dry-run` doesn't validate target resolution; (6) validated direct-krkn recipe; (7) rule leak on target restart mid-chaos (krkn still reports success); (8) `--action N` = SIGTERM to PID N, not signal N (silent no-op if misread); (9) node-memory-hog doesn't create its namespace; (10) hog image writes jobfile to read-only WORKDIR (in-cluster exit 1); (11) **`ports: []` pod_network_filter is node-destructive** — took down d38-h18-000-r660 for 88 min (recovered surgically via IPv6 link-local SSH + iptables-legacy flush; no reboot needed).

**Meta-observation:** ~⅓ of invalid attempt legs trace to krkn tooling, not the product. #4/#8 are silent-wrong-behavior bugs (report success, inject nothing/wrong thing).

---

## 5. Harness fixes applied this campaign

- Windows agent-flap: `guest_exec_wait` fail-fast on "PID does not exist" (rc=2) + `guest_exec_retry` wrapper at inventory/mutation call sites (`scripts/windows-guest-agent.sh`, `scripts/vm-cbt-backup.sh`; backups saved as `.bak`)
- T-family trigger: ENV_BLOCK heredoc fixes (env: header, trailing-newline pair-drop), stress-ng tmp-dir cleanup, IO_HDD_BYTES parameterization
- Pool capacity guards: stat `/var/hpvolumes/csi` (not the parent), 300GiB floor
- Trigger env hygiene: unconditional `MANIFEST_VARIANT=default` (I-06 .env-inheritance class)
- X-04/X-03 triggers: gate-time node resolution, explicit-port network filters, rule-leak guards
- All `bash -n` validated local+remote, md5-verified both sides

---

## 6. Coverage gaps / not executed

| Gap | Reason | Effort to close |
|---|---|---|
| Windows chaos variants (launcher-stop, network-block, thresholds on Windows) | HELD per user direction 2026-10-14; W01 full-backup PASS ×2 archived; agent-flap fix applied and staged | ~2-3 hrs (2 runs + reports) |
| Windows incremental + restore verify | blocked by agent-flap bug (now fixed, untested live); then held | ~1 hr incl. fix validation |
| ODF-backend runs (any scenario) | goldens are HPP-bound; CDI can't cross-class clone — rebuild goldens on RBD first (~30 min one-time) | optional; changes storage-chaos semantics (documented in §3.3) |
| Multi-VM/concurrent-backup scenarios | not in Jira set; single-VM workflow | needs workflow extension |
| Sustained-copy (large variant) chaos | campaign used default workload per user directive; `MANIFEST_VARIANT=large` + sized GUEST_* gives ~28s full / ~16s incremental windows (see .env.example) | swap-in via env vars |

---

## 7. Things to take care of in the next campaign

1. **Windows first:** validate the agent-flap fix live (one incremental run), then run the held chaos variants. Keep `GUEST_EXEC_POLL_ATTEMPTS=900` and expect the retry wrapper to absorb flaps.
2. **VM conveyor (user-agreed design):** pre-provision ~10 RHEL + ~10 Windows clean VMs; consume exactly one per scenario, never reset. Build `TYPE=full VM=<pool-vm> NAME=<RUN_ID>` support (~2-4 hrs; the `TYPE=incremental VM=<existing>` machinery covers 80%). Saves 2-7 min/run; Windows benefits most.
3. **Backend strategy (user-agreed):** ODF as the workhorse for conveyor runs (rebuild RHEL/debian goldens on RBD FIRST — see learnings #79), keep HPP fresh-clone for the storage-topology family (T-03/T-04-class). Document that "backup survives host-netns blackout" is an HPP-only property.
4. **Fix the incremental_failed lockout** upstream (workflow state machine) or add a sanctioned `TYPE=retry-incremental` before the next campaign — it will keep biting otherwise.
5. **Pool hygiene from minute one:** capacity guard on `/var/hpvolumes/csi` in every trigger (already the pattern); schedule `make clean-all` between families rather than after ENOSPC; filler files must be removed via `oc debug node` (sleeping pods hold the fd).
6. **krkn usage rules (from krknctl-bugs.md):** explicit port lists only (never `ports: []`); pre-create hog namespaces; `--action 1` for container stop; dry-run is necessary-not-sufficient (grep live log for abort strings); post-chaos connectivity check on every network-filter target; know the IPv6 link-local escape hatch for node recovery.
7. **Sizing hogs:** absolute GiB for memory (percentage = pod cgroup view); dsync for real contention (buffered writes are page-cache-absorbed); contention threshold is 32-64 workers on this hardware.
8. **Evidence discipline that paid off:** per-run trigger-checks.txt files (decisive CHECK lines preserved immediately — bg artifacts expire), observer raw streams, dual-sync md5 verification, append-only ledger. Keep all four.

---

## 8. Evidence index

- **Authoritative ledger:** `cbt-chaos/campaign-progress.md` (append-only, every closure with timings/md5s/findings)
- **Execution summary (per-scenario commands/gates/observations):** `cbt-chaos/campaign-execution-summary.md`
- **Per-run reports:** `cbt-chaos/scenarios_v2/<ID>/runs/<RUN_ID>/test-run-{result,report}.md` (33 run dirs; decisive RUN_IDs listed in the execution summary §Evidence)
- **krkn defects:** `cbt-chaos/krknctl-bugs.md` (11 entries)
- **Product bug drafts:** `cbt-chaos/scenarios_v2/CBT-F-05/bugs/`
- **Learnings:** `.claude/skills/cbt-chaos-run/cbt-chaos-run-learnings.md` (80 entries) + `.claude/skills/cbt-chaos-issue-triage/cbt-chaos-issue-triage-learnings.md`
- **Harness fixes:** `scripts/windows-guest-agent.sh` + `scripts/vm-cbt-backup.sh` (agent-flap fail-fast + retry; `.bak` originals preserved)
- **Windows held-run evidence:** `runs/20261013-cbtw01-r01-stuck-incremental/` + `runs/20261013-cbtw01-r02/` (full PASS ×2; flap diagnosis in workflow logs)
- Everything synced local↔remote (cloud05 `/root/virt-cbt-lab`), md5-verified
