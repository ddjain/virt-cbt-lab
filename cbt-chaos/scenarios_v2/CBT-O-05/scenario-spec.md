# Scenario: O-05 storage-path latency/loss on the VM's node mid-copy

## 1. Identity

- **Jira issue:** CBT-O-05 (P2, technical scenario: node-network-chaos via direct-krkn network_chaos_ng)
- **Run family:** ODF data-path degradation sweep
- **Precedents:** O-04 (same trigger shape, filter→shaping); T-03 (threshold-hunt methodology); X-03 r03 (direct-krkn recipe)

## 2. Objective and hypothesis

**Objective:** latency/loss sensitivity curve of the RBD copy.

**Hypothesis:** copy time scales with added RTT (each 4MiB-ish write chunk pays replication acks); ~100ms adds measurable but <2× inflation; 500ms should cross the ≥2× degradation bar; 10% loss forces retransmit storms with non-linear slowdown.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD + node Ready + no pre-existing tc rules on ovn-k8s-mp0 (the plugin aborts on complex qdiscs unless force).
2. Background full backup; resolve VM node at gate.
3. Direct-krkn node_network_chaos scenario: id=node_network_chaos, target=<vm-node>, interfaces=["ovn-k8s-mp0"], latency="100ms"|"500ms" or loss="10" (NO % sign — schema rejects it), egress=true ingress=false, test_duration=120.
4. Measure: backup wall from gate; compare against the O-01 baseline-full-seconds CHECK line.
5. Follow-up incremental + restore verify on success.

## 4. Target and validated disruption

- **Mechanism (source-verified):** NodeNetworkChaosModule builds `tc qdisc add dev <iface> root handle 100: htb default 1` + class + `netem delay <d> loss <l>%` via a hostNetwork privileged helper on the target node; cleanup deletes the root handle. Refuses to run over existing complex qdiscs unless force.
- **Blast radius:** all egress traffic shaping on that node's ovn-k8s-mp0 for 120s — kubelet/API use br-ex, unaffected. Node stays Ready.

## 5. Verification criteria

- tc tree created/removed (krkn log lines "created tc tree in pod" / "removed egress shaping rule").
- Duration verdict: NO_EFFECT (<2× baseline) / DEGRADED (≥2×) / FAILED (terminal backup failure or workflow timeout) — same classes as the T-family.
- Node Ready post-chaos; tracker advances once; incremental + restore verify on success.

## 6. Pre-run guards

Standard; ceph HEALTH_OK; verify clean qdisc on the target interface pre-run (`oc debug node -- tc qdisc show dev ovn-k8s-mp0` — no htb/netem residue).

## 7. Uncertainties

- Baseline ODF duration unknown until O-01 runs; the ≥2× math keys off the recorded CHECK line, not the HPP 52-58s numbers.
- loss=10 with msgr2 (CRC + retransmit) may be absorbed better than raw UDP math suggests — a no-effect ceiling is a valid result.
- The plugin's ingress path uses ifb devices; we deliberately avoid it (egress-only legs).

## 8. Evidence

krkn log (tc lines), backup duration + Done reason, node Ready samples, trigger-checks.txt with leg-verdict classification.
