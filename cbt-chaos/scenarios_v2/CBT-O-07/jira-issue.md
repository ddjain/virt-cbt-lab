# CBT-O-07: Kill ceph mon and mgr pods during the backup copy

**Purpose:** Separate the ceph control plane (mon quorum, mgr) from the OSD data plane: an established RBD client session should not need mons mid-copy, but mon quorum loss affects new watches, and mgr loss affects status/autoscaler — measure whether the backup copy or its bookkeeping (hotplug attach, tracker updates) notices.

## Workflow

Full backup

## Test Objective / Description

Delete ceph mon pods (3, quorum-based) and mgr pods (2, active+standby) mid-copy at two intensities: single-daemon kills (quorum survives) and mon-quorum-majority kill (2 of 3 — quorum at risk). Record copy outcome, ceph health, and any client-visible stall.

## Chaos Target

rook-ceph-mon-a/b/c and rook-ceph-mgr-a/b pods in openshift-storage (labels app=rook-ceph-mon, app=rook-ceph-mgr)

## Chaos Action

Delete mon/mgr pods mid-copy

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

Immediate kills; quorum/member replacement in ~30-120s

## Expected Behavior

Single mon/mgr kill: copy unaffected (quorum intact; established sessions keep streaming). 2-of-3 mons: quorum shrinks to 1 — ceph typically maintains quorum with 1 of 3 during graceful member replacement; if quorum is lost, new I/O may block until quorum reforms — copy stalls then resumes or fails cleanly. Never a false success.

## Recovery

Rook reschedules mon/mgr pods automatically. Verify HEALTH_OK before the next leg.

## How to Verify

Backup Done reason + duration; `ceph quorum_status` / `ceph health` series via toolbox; mon/mgr pod replacement events; follow-up incremental + restore verify.

## Expected Outcome

Documents the backup's sensitivity to ceph control-plane loss vs data-plane loss (contrast O-06).

## Priority

P2

## Technical Scenario

pod-scenarios (direct-krkn pod_disruption with label_selector app=rook-ceph-mon / app=rook-ceph-mgr, namespace_pattern openshift-storage)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Target | Count | Rationale |
|---|---|---|---|
| o07a | mgr (app=rook-ceph-mgr) | 1 | Active mgr death — standby promotes; expect no copy effect |
| o07b | mon (app=rook-ceph-mon) | 1 | Quorum 3→2 — client sessions continue; watch for attach-path effects |
| o07c | mon (app=rook-ceph-mon) | 2 (parallel) | Quorum 3→1 — the risky leg; stop if o07b already broke the copy |

3 legs max; o07c only if o07a/b clean (escalate-to-failure rule).
