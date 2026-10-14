# CBT-O-04: Black out storage-network traffic from the VM's node to Ceph during the backup copy

**Purpose:** Test THE key ODF differential: on HPP the copy survived a total host-netns blackout (X-03) because data movement was node-local; on RBD the copy's writes leave the node via the kernel RBD client (host netns, msgr2 to OSD/mon endpoints). A host-netns port-scoped block on the VM's node should STALL the copy — the first campaign scenario expected to interrupt an in-flight copy via networking.

## Workflow

Full backup

## Test Objective / Description

Apply an iptables DROP for the Ceph msgr2 port set (3300 mon, 6800-6803 OSD) on the VM's node, host network namespace, for a bounded window mid-copy. Record whether the copy stalls, errors, or (unexpectedly) completes; and whether it resumes/completes after rule removal.

## Chaos Target

Host network namespace of the VM's node (node_network_filter; interface ovn-k8s-mp0 — the route to OSD pod IPs)

## Chaos Action

iptables DROP tcp ports 3300,6800,6801,6802,6803 egress (EXPLICIT port list — NEVER ports:[] per krknctl-bugs #11)

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

45 seconds

## Expected Behavior

Copy stalls (writes block on OSD acks); backup does not reach Done during the window. After rule removal: either the copy resumes and completes Done=True/Successfully (RBD client retries), or it fails cleanly with an accurate reason (client timeout). The VM must not be corrupted; guest may pause on I/O error only as a clean, recoverable state.

## Recovery

krkn removes the iptables rules after test_duration; node connectivity verified post-chaos (bug #7 leak guard: explicit-port rules on the default interface are node-safe — X-03 r03 precedent).

## How to Verify

Backup Done reason and timing vs the block window; RBD write throughput during window (node debug: /proc/diskstats deltas on the rbd device); post-chaos node Ready + launcher connectivity; follow-up incremental + restore verify; tracker advances once.

## Expected Outcome

Documents the differential: HPP copy is network-independent, RBD copy is network-dependent — with the recovery semantics (resume vs fail) after transient storage-network loss.

## Priority

P1

## Technical Scenario

node-network-filter (network_chaos_ng, direct-krkn with target=<vm-node>, interfaces=[ovn-k8s-mp0], explicit ports — krknctl cannot set the target field reliably, bugs #3/#4)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Ports blocked | Duration | Rationale |
|---|---|---|---|
| o04a | 3300 + 6800-6803 (full storage path) | 45s | The differential test — copy must stall or fail |
| o04b | 6800-6803 only (OSDs; mons reachable) | 45s | Mon-only reachability: does an established OSD session survive mon exclusion? |
| o04c | 3300 + 6800-6803, 120s | 120s | Longer window: does the RBD client time out and fail the backup rather than block forever? |

3 legs max. All legs: ingress+egress both false/true per plugin semantics — egress: true, ingress: true (writes need both directions for acks).
