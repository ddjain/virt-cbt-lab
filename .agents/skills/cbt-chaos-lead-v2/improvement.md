# Reusable run lessons

Lead-owned memory for evidence-backed lessons from failed/INVALID runs and
specialist feedback. Read before every run; keep each accepted lesson to a
single deduplicated bullet of 1–3 lines: condition → prevention (evidence reference).
Keep incident details in run evidence; never store secrets or live target identities here.

- Before accepting a scenario verdict, map its check set to every mandatory
  requirement; a full-interruption evaluator can misgrade a valid between-stage
  injection (evidence: `cbt-chaos-run/cbt-chaos-run-learnings.md`, 2026-10-16 HV1).
- Agree who creates the run directory: a Lead-prepared run root is not reuse.
  Reject existing action/evidence outputs, not the empty pre-armed directory
  (evidence: `cbt-chaos-run/cbt-chaos-run-learnings.md`, 2026-10-16 pre-arm ordering).
- Never pre-flip a pre-armed run.json to phase=running/execution_started=true
  before invocation; the entrypoint's prior-execution guard refuses it. Write
  phase only once, at terminal closed (evidence: CBT-EXP-05 iteration 1
  `blocked.json` + `resolution-review.md`, 2026-10-18).
- Before freezing a bundle, align credential guards with setup-owned generation;
  approval fingerprinting must not silently add an existing-key prerequisite
  (evidence: CBT-F-05 iteration 1 `analysis.json`, 2026-10-16).
- Do not gate backup success on a guessed reason prefix; reuse established
  terminal classification and record checkpoint/reason guard operands separately
  (evidence: CBT-F-05 iteration 2 `analysis.json`, 2026-10-16).
- VMI detach does not prove host/storage cleanup: correlate the exact PVC/PV
  with host mount/device identity, CSI attachment and node pins through a bounded
  post-terminal window (evidence: CBT-F-05 iteration 3 `analysis.json`, 2026-10-16).
- Keep CLI text and decoded JSON scalar types explicit at command boundaries;
  numeric stdout may become an integer, so string methods can abort preflight
  (evidence: CBT-EXP-06 iteration 1 `analysis.json`, source-geometry AttributeError).
- Assert third-party CLI flags only on metadata surfaces exercised verbatim on the
  execution host before approval; a flag can exist on one help surface but not
  another, and some help invocations exit nonzero (evidence: CBT-EXP-01
  iterations 1-3 `operation-error.json`, 2026-10-17 krknctl help surfaces).
- Treat null-valued list fields in API JSON as empty in evidence projections;
  `oc` rc=0 with a TypeError in the projection still fails closed (evidence:
  CBT-EXP-01 iteration 4 `csinodes.status.json`, spec.drivers null, 2026-10-17).
- Quote or parenthesize numeric jq object keys in generated programs and
  dry-parse them (`jq -n '<program>' >/dev/null`) in rehearsal; bare `130:`
  keys crash aggregation after evidence completes (evidence: CBT-EXP-05
  iteration 2 `analysis.json` investigation.harness_defect, 2026-10-18).
- Rehearse the full post-action code path, not just preflight: a NameError after
  a valid injection burns the attempt and leaves decisive criteria UNKNOWN
  (evidence: CBT-EXP-01 iteration 5 `operation-error.json`, observe_restart
  NameError, 2026-10-17).
- Decode watch streams defensively (per-record JSON decode, not line-by-line
  parsing of pretty-printed output) or transient flag transitions are silently
  missed (evidence: CBT-EXP-01 iteration 5 watch transitions.json vs raw
  tracker-watch.jsonl, 2026-10-17).
- Make image tool probes report per-tool presence (`command -v x || echo MISSING:x`)
  instead of aborting at the first missing binary, and align the mandatory list
  with the restore path's actual optional-tool usage (evidence: CBT-EXP-06
  iteration 2 `restore-tool-probe.status.json`, udevadm absent in pinned image, 2026-10-17).
- A decisive terminal-disposition criterion cannot be resolved at a short wait
  bound: pre-approve a longer read-only post-bound observation window instead
  of burning attempts on reruns (evidence: CBT-EXP-06 iteration 3
  `analysis.json`, NONTERMINAL_AT_BOUND wedge, 2026-10-17).
- Re-hash the live execution checkout when approval is recorded, not only the
  preflight candidate: a shared-checkout dependency can drift between preflight
  and approval and surface only at the execute-time gate, costing the slot
  (evidence: CBT-EXP-08 iteration 1 `execution-blocked/operation-error.json`,
  Makefile drift 05:33→05:45Z, 2026-10-17).
- A loop-repeated probe with a fixed output name collides with save()'s
  exclusive create once its wait condition persists past one cadence; key every
  repeated probe name by its loop index (evidence: CBT-EXP-10 iteration 1
  run.json, collector node-probe FileExistsError, 2026-10-17).
- Path construction `directory / "prefix" + suffix` binds as (Path) + str and
  raises TypeError only at that line's first execution; parenthesize the string
  and audit every bundle path join by AST before approval (evidence: CBT-EXP-10
  iteration 2 run.json, exclusions() PosixPath+str, 2026-10-17).
- A stdout-only jq without `-n`/input operand blocks forever on open inherited
  stdin — compile sweeps and `/dev/null`-stdin rehearsals are structurally
  blind to it; audit every jq for -n/file-operand/stdin-producer and rehearse
  post-setup paths with stdin held open (evidence: CBT-EXP-08 iteration 2
  `execution/operation-error.json`, run.sh:988, 2026-10-17/18).
- Preserve the approved package/parameters files on the execution host and
  re-verify approval.json integrity immediately before execution: sibling
  syncs on a shared checkout can clobber it back to an older attempt's record
  (evidence: CBT-EXP-01 attempt 6 pre-execute check found approval.json at
  the attempt-5 fingerprint; restored from preserved /tmp package files,
  2026-10-18).
- Gate a recovery follow-on on the scenario spec's own criteria, not a stricter
  side invariant: an over-strict operand check can skip the spec-mandated
  restore and force INCONCLUSIVE by deleting mandatory evidence (evidence:
  CBT-EXP-02 iteration 1 `analysis.json`, 2026-10-18).
- Parenthesize jq array-concatenation values inside object literals and compile
  every generated jq program verbatim with the execution host's jq version;
  jq-1.6 rejects `key:[..] + [..]` after all evidence is captured (evidence:
  CBT-EXP-02 iteration 1 publish-step parse error, 2026-10-18).
- A CR-condition poll cannot enter a sub-second pre-terminal gap when the signal write IS the terminal write (EXP-03 Progressing-flip = the Done write, cleanup ~2 rvs earlier); trigger such races from the upstream object's watch stream (e.g. VMI backupStatus removal), not the CR condition (evidence: CBT-EXP-03 iteration 1 `analysis.json`, 2026-10-18).
- Gates that extract UIDs from previously written artifacts must assert the
  value is non-null/UID-shaped and fail loudly instead of comparing against
  the string "null"; rehearsals should exercise each gate with the artifact
  shapes the live path actually writes (evidence: CBT-EXP-08 iteration 3
  `analysis.json`, run.sh:1183 `.metadata.uid` vs stored `.backup_uid`,
  2026-10-18).
- Keep Engineer rehearsal roots outside the scenario `runs/` tree: a cleanup
  `rm -rf` there can delete pulled closed-attempt evidence packs (local copies
  only; restore via the verified scoped pull from the untouched remote canon)
  (evidence: CBT-EXP-08 repair 3 incident, Engineer disclosure, 2026-10-18).
- Pre-registered "requeue/404 in controller-window.log" signatures are
  hypotheses to verify, not required evidence — a wedge can be provably
  silent (frozen resourceVersion, zero log lines); surface resourceVersion per
  stuck sample to distinguish silence cheaply (evidence: CBT-EXP-08 iteration
  4 `analysis.json`, 2026-10-18).
- Trust deployed pod specs over injector telemetry: krknctl node-io-hog echoes
  the approved --node-mount-path while silently mounting hostPath /tmp
  (krkn-lib 7.0.3 template key mismatch); assert .spec.volumes[].hostPath.path
  against the approved path as a machine check (evidence: CBT-EXP-09 iteration-2
  analysis.json + node-debug physical proof, 2026-10-18).
- Rehearse evidence collectors against the real first-read object shape and gate
  their liveness through the injection window with an evidence-preserving rescue
  re-arm: krkn hog pods are created label-less, and to_entries on null labels
  kills a set -euo pipefail collector exactly when the evidence appears
  (evidence: CBT-EXP-09 iteration-1 resolution-review.md, 2026-10-17).
- Capture read-only device-level telemetry (iostat via oc debug node) during
  contention copy windows: duration alone cannot distinguish page-cache
  absorption from weak block-layer contention (evidence: CBT-EXP-09 iteration-3
  analysis.json, 42 s under proven in-window pool-path writes, 2026-10-18).
- Seed lifecycle `report.json` with `.recovery.attempts` before calling the
  repository restore test in recovery mode, or tolerate its absence: the
  shared script's post-verdict report merge fails (rc 5) over a file
  scenario-local recovery legs never create (evidence: CBT-EXP-02 iteration 2
  `analysis.json` rc=5 investigation, 2026-10-18).
- Bind the cluster identity to the session-wide source (kube-system
  namespace UID) and generate every relayed files map programmatically from
  the published canonical package; hand-typed hash/UID fields in relay
  messages have twice corrupted an otherwise valid package (evidence:
  CBT-F-02 iteration-1 approval rejection + relay corrections, 2026-10-18).
- Pair every cleanup-collector probe state with its own readable/status fields
  so residual-vs-UNKNOWN is machine-checkable at the bound; keep that pairing
  in future collectors to preserve FAIL-grade evidentiary strength (evidence:
  CBT-F-05 iteration-4 analysis.json residual audit, 2026-10-18).
- Never reference a `local` variable inside the same `local` statement that
  declares it (bash expands all words before assigning; `set -u` makes it a
  fatal abort at first execution) — audit for this class alongside jq/Path
  checks (evidence: CBT-F-06 iteration-1 run.sh:1179 abort, 2026-10-18).
- Strip ANSI color escapes from tool logs at the read boundary before any
  parsing and include a colored-line fixture in the offline self-test: krkn INFO
  lines are ANSI-colored and either silently null log-derived checks or, via an
  end-anchored regex, append ESC[0m to parsed names and corrupt identity
  comparisons into a false INVALID (evidence: CBT-F-02 iteration-3 analysis.json
  harness defect F-1; CBT-F-11 iteration-5 resolution-review.md, 2026-10-18).
- Keep driver/helper evidence paths in sync: a run.sh status merge that reads
  $WORK/<name>.status.json while the helper writes execution/<name>.status.json
  records not-observed and forces graders to reconcile four raw sources
  (evidence: CBT-F-10 iteration-1 analysis.json unexpected_signals, 2026-10-18).
- Preflight the shared hostPath evidence pool capacity (df / PV inventory of
  /var/hpvolumes/csi) before any backup-destination scenario: retained run
  PVCs monotonically consume it and its exhaustion converts attempts to
  environment-attributed INCONCLUSIVE (evidence: CBT-F-13 iteration-1
  analysis.json, 96%-full pool ENOSPC, 2026-10-18).
- Persist a watch stream's terminal containerStatuses into the status snapshot
  instead of a fresh `oc get` after deletion; the object may be gone, leaving
  null exit fields the grader must reconcile against raw streams (evidence:
  CBT-F-09 iteration-1 analysis.json stress_pod_lifecycle nulls, 2026-10-18).
- Point duration ride-alongs at lifecycle report.json backup_timings (or the
  observer window), not summary.json duration_seconds, which can be null on an
  otherwise clean run (evidence: CBT-F-09 iteration-1 duration-comparison.json,
  2026-10-18).
- oc-debug node telemetry sessions are fragile (3 exits/10 min); keep the
  segment-preserving re-arm and prefer a longer-lived or node-local sampler —
  bracketing counter deltas bridged a 31 s in-window gap (evidence: CBT-F-09
  iteration-1 analysis.json device telemetry, 2026-10-18).
- Size mid-copy injection windows against the fixed latency budget (trigger
  poll quantization + measured fill pipeline), assuming fast-case throughput:
  a 4.2 s copy lost to a 4.4 s budget and the deleted attachment pod surfaced
  as a misleading krkn shell error (evidence: CBT-F-08 iteration-1
  resolution-review.md §3, 2026-10-18).
- Class-ify probe exit codes before acting on them: a TLS-verification
  failure (curl rc=60) proves a path is OPEN; only rc 7/28-class proves
  blocked — any-nonzero-oracle guards delete healthy targets (evidence:
  CBT-F-12 iteration-1 guard.status.json + resolution-review Chain B,
  2026-10-18).
- krkn pod_* helper pods render imagePullPolicy: Always from an in-image
  Jinja template; on no-egress nodes the node-cached image is never used and
  no rule is applied while krkn appears to run — bind-mount a verified
  IfNotPresent override and watch the helper pod phase for fast abort
  (evidence: CBT-F-12 iteration-1 leftover-helper-pod.json + resolution-review
  Chain A, krknctl-bugs #12 family, 2026-10-18).
- Publish approval packages as canonical files on the execution host (jq -cS
  | sha256sum) and relay only the path: hand-typed 29-file hash maps corrupted
  two approval requests even after a correction pass (evidence: CBT-F-03
  requests 20261018T1534/1545Z, superseded by file-based 20261018T1615Z).
- Record approval.json with the bundle's own live-computed parameters
  verbatim: adding derived keys (cluster_uid, host) to the recorded parameters
  breaks check_approval's equality gate before any cluster action (evidence:
  CBT-F-03 execution-blocked-paramshape-20261018T2350Z, 2026-10-18).
- A failed --execute leaves a finalizer injection-confirmation.json at the run
  root; archive it with the failed execution dir before relaunch, since
  check_root refuses it as prior output (evidence: CBT-F-03 relaunch refusal,
  2026-10-18).
- Compute canonical approval fingerprints with the same real jq implementation
  as the approver, on the published package file: a control host's `jq` can be
  a jaq shim whose `-cS` bytes differ from jq-1.6, making the fingerprint
  irreproducible for the approver (evidence: CBT-F-01 retracted request
  1b81d241 → corrected dd049b78, 2026-10-18).
- When the fault can crash the target mid-window (controller liveness/leader
  election), expect the krknctl-bugs #7 rule leak to RECURRE: krkn cleanup
  nsenters pre-crash pids and rules outlive chaos end — the guard rollback
  then legitimately preempts resume-as-follower criteria and confounds the
  verdict; record the confound explicitly instead of grading either way
  (evidence: CBT-F-12 iteration-2 analysis.json INCONCLUSIVE, guard rc=28 at
  +21s after rule removal, 2026-10-19).
- Record approval decision timestamps at answer time in the durable approval
  record, not only as a later-transcribed relay field, so approval.answered_at
  can never postdate execution evidence timestamps (evidence: CBT-F-05
  iteration-5 analysis.json harness observation, 2026-10-19).
- Pin an additional controller-log pull to the wedged-CR delete instant (or
  recovery-done): delete-instant windows captured 0 run-scoped lines in both
  graded CBT-EXP-08 attempts while all decisive mechanism lines post-date that
  instant, forcing post-hoc live verification (evidence: CBT-EXP-08 iterations
  4-5 `analysis.json`, 2026-10-18/19).
- Re-snapshot stage-boundary evidence after every follow-up stage, not only in
  the terminal finalizer: an early finalizer call plus an idempotence guard
  froze lifecycle-capture.json at its post-full state, forcing graders to
  reconcile stale operands against authoritative sources (evidence: CBT-I-01
  iteration-1 analysis.json harness observation, 2026-10-20).
- Load the repository dotenv before assembling a stage's explicit environment:
  a first full-stage invocation burned a BLOCKED rc=2 on a missing
  RESTORE_HELPER_IMAGE that .env already carried (evidence: CBT-I-01 iteration-2
  run.json harness_notes, 2026-10-21).
- Audit generated jq invocations for a missing -n even when they take -f and
  with rc=0 (evidence: CBT-I-01 iteration-2 approval.json recording, 2026-10-21).
- Keep analysis.json `proposed_scenarios` strictly to allocated jira-issue.md paths; grading owners must park unallocated ideas in `proposal_candidates`/`feedback` — the verified pull path-validates every entry and a candidate OBJECT aborts the whole scenario pull (evidence: CBT-I-02 i1 pull failure 2026-10-21, amended by grading owner).
- A remote background-arm wait loop must poll the marker file and the recorded PID (`pgrep -f`), never ssh shell job control (`kill -0 %1`), which reports NOT-ARMED while the watcher is alive and costs a diagnosis round-trip (evidence: CBT-I-02 i1 action.armed.utc false alarm, 2026-10-21).
- A mid-lifecycle capacity refresh needs a phase-aware floor: re-applying the
  pre-full pool floor after the full stage has allocated its share false-BLOCKs
  at ~6x headroom (evidence: CBT-I-04 iteration-1 refresh 340 GiB free vs 51 GiB
  remaining need, 2026-10-21; repaired with POST_FULL_FLOOR_KIB).
- The HostPath pool monotonically fills with closed runs' retained VMs/PVCs;
  before any backup-destination scenario batch, clean closed+pulled runs'
  cluster objects (VM cascades root disk; then managed PVC/vmbackup/tracker)
  and verify pool free — 344 GiB free was reclaimed to 1.42 TiB in one pass
  (evidence: CBT-I-04 iteration-2 preflight unblock, 2026-10-21).
- Drive background-arm + stage-launch sequences from a script file on the
  execution host with absolute $OUT_DIR paths; an ssh one-liner that backgrounds
  a compound `cd && dotenv && export && nohup …` with one trailing `&` leaves
  the foreground shell without the env, so the arming poll checks `/marker`,
  reports ARMING-FAILED, and the stage never starts while the armed injector
  times out (two INVALID attempts: CBT-I-08 i1 &&-chain + i2 env-loss, 2026-10-21).
- A scoped `pull-reports --scenario X` cannot update a defect bug file that
  lives in a sibling scenario's bugs/ tree (the one-bug-per-distinct-defect
  rule keeps evidence in the original scenario): run the unscoped pull after
  the scoped one when a cross-scenario bug was updated (evidence:
  CBT-EXP-08V1 closeout 2026-10-23, scoped pull left the EXP-08 bug stale).
