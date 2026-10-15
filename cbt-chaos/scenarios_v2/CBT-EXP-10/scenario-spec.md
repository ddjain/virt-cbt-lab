# Scenario: EXP-10 — Non-422 redefinition error → cross-backup blast radius (P5 closeout gate)

## 1. Identity

- **Experiment ID:** EXP-10 (WeaknessAnalyst P5, Judge GO with mitigations; the campaign's closeout gate)
- **Hypothesis source:** `handleRedefinitionError` clears the checkpoint only on string-matched "422 Unprocessable Entity" errors; any other error shape requeues forever while `checkPrerequisites` holds new backups in Initializing — one bad redefinition could wedge ALL backups on the tracker.

## 2. Objective / defect hypothesis

A virt-handler outage inside the checkpoint-redefinition window (VMI restart with a checkpoint present) forces the controller→handler redefinition call to fail with a CONNECTION error (non-422 shape). After handler recovery: does the tracker clear `checkpointRedefinitionRequired` (self-heal) or wedge? **Named primary criterion:** does a SECOND fresh-named backup on the SAME tracker wedge (cross-backup blast radius — the one untested severity dimension in the wedge family)?

## 3. Workflow

Fresh HostPath VM → full backup → VMI delete (opens the redefinition window) → immediately delete virt-handler on the VM's node (pre-restart logs captured; fail-closed restart verification via new startTime; time-boxed 5-min stop conditions) → handler back Ready → observe tracker redefinition state for 10 min (cleared vs stuck) → create a second fresh-named backup on the same tracker (Done vs wedge) → recovery via the proven matrix (delete CRs+tracker, `make e2e TYPE=recover`: fresh full + restore-verify).

## 4. Injection

- **Target:** virt-handler pod on d38-h18-000-r660 (pre-flight verified: only 4 campaign-owned VMIs on the node; handler restart doesn't evict running VMIs — bounded operational risk on record).
- **Action:** pod deletion at the redefinition window (SIGTERM-equivalent; the redefinition call fails with connection-refused — the non-422 shape).
- **Window:** VMI start with `checkpointRedefinitionRequired` set.

## 5. Measurements / classification (pre-registered)

- Injection validity: handler pre-restart logs captured; restart verified (new startTime, Ready within time-box); the error string in controller/handler logs (connection-class, NOT 422).
- **Tracker outcome:** redefinition cleared within 10 min (self-heal) vs stuck (wedge candidate).
- **Primary criterion:** second backup on the same tracker — Done (no blast radius) vs wedge (cross-backup blast radius CONFIRMED — joins the EXP-6/8 ticket with multi-backup severity).
- Recovery: workflow recover completes (fresh full + restore-verify PASS) — leaves the VM healthy for campaign close.
- PASS (resilient): tracker clears, second backup completes, recovery verifies. FAIL: tracker stuck and/or second backup wedged.

## 6. Blast radius / safety

Handler daemonset restart on a node with 4 campaign-owned VMIs (running VMIs unaffected; handler-mediated ops interrupted ~1-2 min). Time-boxed stop conditions. Recovery path proven. ~40 min.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-10/runs/<RUN_ID>/`: trigger.log, handler-pre-restart.log, handler-post-restart.log, controller-window.log, tracker-final.yaml, second-backup.yaml, recovery records, observer streams.
