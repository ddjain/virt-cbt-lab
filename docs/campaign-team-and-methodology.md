# CBT Chaos Campaign — Team & Methodology Summary

**Campaign:** 2026-10-14 → 2026-10-15 · 4 Jira baselines + 10 adaptive experiment runs (13 total reported runs, plus 9 fail-closed harness iterations) · 4 product findings (2 with engineering tickets)

## 1. The subagent team (16 agents, 3 tiers)

### Tier 1 — Standing experts (persistent, whole campaign)

| Agent | Role |
|---|---|
| **Judge** | LLM-as-expert-judge. Reviewed every run's evidence: verdict validity, unsupported claims, evidence gaps, accuracy improvements for the next run. Held the **GO/NO-GO authority** — decided whether each proposed experiment ran, in what order, and when the campaign stopped. Caught two invalid-run claims that would otherwise have been recorded as product results (EXP-3's missed race window; EXP-10's kill-after-window), mandated the EXP-7 restore triad, and issued the final STOP after a full verdict audit. |
| **WeaknessAnalyst** | Adversarial scenario designer. Mapped untested CBT attack surface from kubevirt v1.8.4 source + live cluster state, prioritized experiments by defect probability, and produced concrete designs (P1 multi-disk bitmap drop → became EXP-6/7; P2 tracker deletion → EXP-8; P3 late-ENOSPC → EXP-7; P4/P5). Verified its proposals against live cluster facts and the 12 known krknctl defects before proposing. |

### Tier 2 — Research & discovery (one-shot, campaign start)

| Agent | Role |
|---|---|
| **ParamDiscovery** (scout) | Mapped every tunable knob in the harness: the hard 20-min backup gate, the 20 s tracker pre-check, the 60 s recovery wait, workload sizing, manifest variants — the parameter inventory that bounded experiment design. |
| **KubevirtRE** | Reverse-engineered github.com/kubevirt/kubevirt (matched to the live CNV 4.22.12 build): identified the actual backup implementation (native `backup.kubevirt.io/v1alpha1` in virt-controller/launcher/handler), the full push-mode lifecycle state machine, every hardcoded timeout/retry, and a ranked top-5 fault-hypothesis list that seeded the entire adaptive phase. |

### Tier 3 — Per-run observers (one per run, 12 total)

| Agent | Run |
|---|---|
| F09Observer | F-09 baseline (I/O hog, full) |
| F10Observer | F-10 baseline (CPU hog) |
| F11Observer | F-11 baseline (netfilter) |
| I04Observer | I-04 baseline (I/O hog, incremental) |
| EXP1Observer | EXP-1 (VM restart → redefinition) |
| EXP3Observer | EXP-3 (controller kill at completion ×3) |
| EXP2Observer | EXP-2 (backup-CR deletion mid-copy) |
| EXP5Observer | EXP-5 (SIGSTOP stale-reconcile induction) |
| EXP6Observer | EXP-6 (per-disk bitmap loss — Finding 1) |
| EXP7Observer | EXP-7 (late ENOSPC — Finding 2) |
| EXP9Observer | EXP-9 (Windows coverage) |
| EXP10Observer | EXP-10 (handler outage in redefinition window) |

**Observer role (identical contract per run):** independent read-only injection witness + bounded evidence analyst. They (a) read the scenario spec themselves and derived the expected target/signal/window — never trusting the parent's claims; (b) armed authenticated watch streams (`watch-resource.sh`) and proved liveness before any trigger fired; (c) independently confirmed the chaos actually landed on the intended component at the intended lifecycle phase (UID checks, state-T verifications, node placement, RV orderings); (d) delivered a criterion-by-criterion PASS/FAIL table with an independent timeline; (e) never injected, modified resources, or wrote reports. Multiple decisive findings came from observers contradicting the parent: EXP-1's transient redefinition flag (polling missed it, the watch stream caught it), EXP-5's ghost-event rv-pair, EXP-10's kill-after-window RV proof.

## 2. How the campaign was tested (methodology)

### Execution loop

```
for each run:
  1. Hypothesis  — from source analysis (KubevirtRE/WeaknessAnalyst),
                   a prior run's anomaly, or a Jira baseline spec
  2. Design      — WeaknessAnalyst proposes, Judge approves/reorders
                   (GO/NO-GO) with mandated controls and criteria
  3. Trigger     — parent ALONE writes/executes the injection
                   (never two injectors on shared resources)
  4. Observer    — armed BEFORE the trigger; independently verifies
                   injection validity fail-closed
  5. Verdict     — observer's criterion table + parent reconciliation
                   against lifecycle records
  6. Judge       — adversarial review; tightens evidence, decides
                   what runs next (or STOP)
  7. Evidence    — reports + tickets written locally and remotely;
                   results feed the next hypothesis
```

### Key methodology rules (learned, then enforced)

1. **Fail-closed injection proofs.** Every leg verifies its chaos actually landed (state-T checks, 404 verifications, restart evidence, placement guards). Nine harness iterations were caught this way and archived invalid — never recorded as product results. Notable catches: krkn cpu-hog's readOnlyRootFilesystem crash; container-pid1 SIGSTOP being a silent no-op; the EXP-9 placement guard (Windows on Ceph vs hog on HostPath).
2. **Watch streams over polling.** Transient states (~1-2 s windows: `checkpointRedefinitionRequired`, the ghost event's rv-pair, the sub-second completion race) are invisible to polling — proven twice. Observers used continuous watches, later supervisor-wrapped against ~1 h idle-stream drops.
3. **Control legs on every new harness path.** The 2-disk VM (EXP-6) and the pre-filled PVC (EXP-7) each ran a no-surgery control before the experiment leg — new machinery is new failure modes.
4. **Pre-registered criteria, including alternative outcomes.** After EXP-3's window miss, every experiment defined its PASS/FAIL (and the "unexpected outcome" classification) before execution.
5. **Data-integrity oracles with teeth.** Hash-verified restores on every successful chain (~20/20 clean); per-disk/per-file granularity; destination-size and duration-vs-workload arithmetic as silent-corruption discriminators (EXP-7's 3-second "copy" of 17.4 GiB was proof by arithmetic).
6. **Single injector.** All mutations (chaos, E2E, recovery) were coordinated by the parent; observers were strictly read-only — no conflicting experiments against shared resources.
7. **Evidence on both hosts.** Every run's artifacts (trigger logs, object snapshots, observer streams, reports, tickets) preserved in the local checkout and on cloud05, addressed by run ID.

### What was tested (coverage)

- **Jira baselines (4):** I/O contention (full + incremental), CPU pressure, launcher network isolation — all PASS.
- **Adaptive experiments (10 runs):** VM hard restart (redefinition), backup-CR abort, controller kills at completion, controller process freeze, per-disk bitmap corruption, late-copy destination ENOSPC, tracker deletion mid-copy, Windows cross-OS coverage, handler outage in the redefinition window.
- **Fault classes exercised:** storage I/O (buffered + O_DSYNC), CPU, network (pod-level), process signals (SIGSTOP/SIGCONT, pod deletion), API-object surgery (QMP bitmap removal, CR/tracker deletion, pre-filled PVCs), storage capacity.
- **Result: 4 product findings** (wedge/no-terminal-resolution with 2 entry paths; silent corruption with the restore triad; two-sided ghost-event observability; cancellation-reason conflation), 2 engineering ticket drafts with verified recovery matrices, and a documented untested-claims list (persistent-error wedge via in-process injection; Windows Ceph-path contention; ghost-event Windows rate beyond n=1).

## 3. Artifact map

- Final report: `docs/chaos-experiments.md`
- Finding details: `docs/findings/finding-{1..4}-*.md`
- Engineering tickets: `cbt-chaos/scenarios_v2/CBT-EXP-06/bugs/`, `CBT-EXP-07/bugs/`
- Per-run evidence + reports: `cbt-chaos/scenarios_v2/<SCENARIO>/runs/<RUN_ID>/` and `runs/<RUN_ID>/` (both hosts)
- Tooling defects: `cbt-chaos/krknctl-bugs.md` (12 entries)
