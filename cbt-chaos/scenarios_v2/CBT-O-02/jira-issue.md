# CBT-O-02: Kill the RBD CSI node plugin on the VM's node during the backup copy

**Purpose:** Establish whether an in-flight ODF/RBD backup copy survives deletion of the csi-rbdplugin node DaemonSet pod on the VM's node — the ODF analog of F-07 (HostPath CSI node plugin), where the copy survived because the volume was already mounted.

## Workflow

Full backup

## Test Objective / Description

Delete the csi-rbdplugin pod on the node hosting the VM (resolved at gate time) mid-copy. On RBD the copy writes through a kernel rbd device that was mapped by the plugin before the copy started; the plugin process is not in the steady-state data path, but its death may disrupt ancillary state (registration, liveness, re-map on error). Determine which.

## Chaos Target

openshift-storage.rbd.csi.ceph.com-nodeplugin DaemonSet pod on the VM's node (label app=openshift-storage.rbd.csi.ceph.com-nodeplugin, hostNetwork=true)

## Chaos Action

Delete the node-plugin pod (graceful) mid-copy

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

Immediate (single pod deletion; DaemonSet replaces in ~10-30s)

## Expected Behavior

Copy continues to Done=True/Successfully (kernel rbd device persists independent of the plugin pod — F-07 analog), OR fails cleanly with an accurate Done reason. Never a false success; never silent data corruption.

## Recovery

Automatic DaemonSet pod replacement. Verify the replacement is Ready before the follow-up incremental (its PVC attach needs the plugin alive).

## How to Verify

Backup Done reason; replacement plugin pod Running/Ready on the same node; plugin pod restart/replacement timestamps inside the copy window; follow-up incremental + restore verify; tracker advances once.

## Expected Outcome

Documents whether the RBD node plugin is in the copy's data path or only in the attach/detach path.

## Priority

P1

## Technical Scenario

pod-scenarios (direct-krkn pod_disruption pattern: name-pattern + node-names cannot be ANDed in krknctl, and pod-scenarios' random selection must not hit an arbitrary node's plugin — so the F-12-validated direct-krkn invocation with a hand-written list-of-configs YAML pinning namespace_pattern/name_pattern/node_names)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Variant | Rationale |
|---|---|---|
| o02a | graceful delete (grace period default) | Baseline: does the copy even notice? |
| o02b | force delete (grace_period_seconds=0, force: true) | Skip graceful drain; fastest possible replacement churn |
| o02c | kill during hotplug ATTACH instead of copy (gate: destination PVC Bound ∧ attachment pod absent) | Attacks the staging path where the plugin IS required — expect failure or delayed attach |

3 legs max; o02c only if o02a/b show copy-path immunity (then the interesting surface is attach).
