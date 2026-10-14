# CBT-O-11: Kill the rook-ceph-operator during the backup copy

**Purpose:** Cheap, low-expected-impact control-plane probe: the rook operator reconciles ceph cluster config (DaemonSets, mon/mgr membership, config maps) but is not in any client data path. Validate that a backup copy (and the csi-addons/hotplug plumbing around it) completes unaffected while the operator is down — and that no config drift accumulates.

## Workflow

Full backup

## Test Objective / Description

Delete the rook-ceph-operator pod (1 replica, openshift-storage) mid-copy. Expected: copy unaffected; the only observable effects are paused reconciliations (e.g., OSD PDB updates, mon membership changes) during the replacement window (~15-45s). This establishes the operator as a safe-to-lose component during backups, sharpening the family's attribution matrix.

## Chaos Target

rook-ceph-operator Deployment pod (openshift-storage)

## Chaos Action

Delete the operator pod mid-copy

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

Immediate (single pod deletion; replacement ~15-45s)

## Expected Behavior

Backup completes normally (Done=True/Successfully, duration ≈ baseline). Ceph health unaffected. No csi/hotplug errors attributable to the operator. If ANY effect appears, it is a finding (unexpected coupling).

## Recovery

Automatic Deployment replacement.

## How to Verify

Backup Done reason + duration vs baseline; operator replacement pod Ready; ceph HEALTH_OK throughout; no new csi-addons/rook warning events on the backup objects; follow-up incremental + restore verify.

## Expected Outcome

Confirms the operator is not in the backup path — completing the ODF component-attribution matrix (node-plugin O-02, ctrl-plugin O-03, OSDs O-06, mon/mgr O-07, operator O-11).

## Priority

P3 (low expected impact; cheap to run alongside family batching)

## Technical Scenario

pod-scenarios (direct-krkn pod_disruption with name_pattern pinning the rook-ceph-operator pod in openshift-storage)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Variant | Rationale |
|---|---|---|
| o11a | kill mid-copy (Progressing gate) | The standard probe |
| o11b | kill during hotplug teardown (Done-flip window, O-03's o03b gate) | The only window where operator-adjacent config could matter |
| o11c | kill + sustained (delete replacement repeatedly via 3 serial kills) | Sustained operator absence across copy + cleanup |

3 legs max; o11b/c only if o11a shows any anomaly worth isolating (otherwise the single probe suffices — P3 budget).
