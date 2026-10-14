# CBT-O-05: Inject storage-path network latency and loss on the VM's node during the backup copy

**Purpose:** Instead of a hard blackout (O-04), degrade the node→Ceph path with tc netem shaping — latency and packet loss on the interface carrying RBD client traffic — to find where the backup copy slows measurably and where it breaks.

## Workflow

Full backup

## Test Objective / Description

Apply HTB+netem qdiscs (latency, loss) on the VM's node ovn-k8s-mp0 interface mid-copy and measure backup duration vs the O-01 ODF baseline. Sweep latency and loss independently to find the degradation threshold (≥2× baseline) and the failure point (RBD client timeout / backup failure).

## Chaos Target

Host network namespace of the VM's node, egress (and optionally ingress) on ovn-k8s-mp0 (node_network_chaos)

## Chaos Action

tc netem: latency Xms / loss Y% for the chaos window

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

120 seconds per leg (longer than O-04: degradation, not outage)

## Expected Behavior

Low latency/loss: copy slows proportionally (each write ack pays the added RTT × replication factor). High latency: copy duration inflates ≥2× (DEGRADED). Extreme: RBD client queue stalls, backup fails cleanly or the workflow's 20m wait times out. No corruption in any case.

## Recovery

krkn removes the tc qdisc tree after test_duration (finally-block cleanup, source-verified); node connectivity unaffected (shaping, not filtering).

## How to Verify

Backup duration vs O-01 baseline; Done reason; tc qdisc presence during window (krkn log); node Ready post-chaos; follow-up incremental + restore verify.

## Expected Outcome

A latency/loss sensitivity curve for the RBD-backed copy — the ODF analog of T-03's dsync-worker sweep.

## Priority

P2

## Technical Scenario

node-network-chaos (network_chaos_ng NodeNetworkChaosModule: latency/loss/bandwidth via tc HTB+netem, direct-krkn with target=<vm-node>)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Shaping | Value | Rationale |
|---|---|---|---|
| o05a | latency | 100ms | ~10× typical pod-network RTT; measurable but survivable |
| o05b | latency | 500ms | Severe — copy should degrade ≥2× or stall |
| o05c | loss | 10% (plugin takes the number WITHOUT % — config `loss: "10"`) | Packet loss forces msgr2 retransmits; find break point |

3 legs max, single variable each. Egress only (traffic-type [egress]) — ingress shaping uses the ifb redirect path and adds risk without new information for the copy's write path.
