# Scenario: O-04 host-netns storage-network blackout on the VM's node mid-copy

## 1. Identity

- **Jira issue:** CBT-O-04 (P1, technical scenario: node-network-filter via direct-krkn network_chaos_ng)
- **Run family:** ODF data-path network disruption (the HPP-vs-RBD differential)
- **Precedents:** X-03 r02/r03 (host-netns filter mechanics, ports:[] destructiveness, explicit-port safety); campaign-final-report §3.3 (topology caveat); krknctl-bugs #7 (rule leak), #11 (node-destructive empty ports)

## 2. Objective and hypothesis

**Objective:** prove/disprove that the RBD copy depends on node→OSD networking, and characterize recovery after transient loss.

**Hypothesis:** kernel rbd client (hostNetwork csi-rbdplugin mapped the device; QEMU writes via the kernel block device) requires msgr2 OSD acks through ovn-k8s-mp0. Blocking 3300+6800-6803 egress+ingress stalls the copy within seconds; removal lets it resume or time out.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD + node Ready + **out-of-band node access confirmed** (the X-03 lesson: any host-netns iptables on a node is one cleanup failure away from an outage; IPv6 link-local escape hatch documented).
2. Background `make e2e TYPE=full ... MANIFEST_VARIANT=odf`; resolve VM node at gate.
3. Direct-krkn node_network_filter scenario (list-of-configs): id=node_network_filter, target=<vm-node>, namespace=<helper ns>, interfaces=["ovn-k8s-mp0"], protocols=["tcp"], ports=[3300,6800,6801,6802,6803], ingress=true, egress=true, instance_count=1, execution=serial, test_duration per leg.
4. During window: sample /proc/diskstats for the rbd device via oc debug (write-byte deltas → stall proof).
5. After krkn cleanup: verify rules removed (krkn log "removing iptables rules"), node Ready, then wait backup terminal; follow-up incremental + restore verify.

## 4. Target and validated disruption

- **Target:** the VM's node ONLY (never an OSD/mon node — mon quorum risk + eviction storm).
- **Mechanism (source-verified):** NodeNetworkFilterModule deploys a hostNetwork+hostPID privileged helper on the target node, generates per-port INPUT/OUTPUT DROP rules on the given interfaces, sleeps test_duration, deletes rules.
- **Blast radius:** node loses ONLY ceph msgr2 ports on ovn-k8s-mp0 — kubelet/API (br-ex) unaffected; node stays Ready.

## 5. Verification criteria

- Block active during copy (krkn log applied-rule lines + diskstats stall).
- Backup: no Done during window (stall proof); terminal state after removal — Done=True/Successfully (resumed) or accurate failure (client timeout); record which.
- No rule leak: post-chaos connectivity check from the node (oc debug curl to a mon ClusterIP:3300 or rbd device I/O resumption).
- Node Ready throughout; tracker advances once; incremental + restore verify on success.

## 6. Pre-run guards

Standard; ceph HEALTH_OK; out-of-band node access verified; no pre-existing tc/iptables residue from prior network runs.

## 7. Uncertainties

- Whether an established rbd session survives a 45s block (client retries) vs times out — that IS the measurement (o04a vs o04c).
- o04b (mons reachable): an established session may not need mon contact mid-copy — possible no-effect leg; still a valid datum.
- If the backup completes DURING the window, the copy was buffered/page-cache-served — must be classified UNEXPECTED-SUCCESS with throughput evidence, not FAIL-by-assumption.

## 8. Evidence

krkn log (rule apply/remove lines), diskstats series, vmbackup conditions+events, node Ready samples, trigger-checks.txt (CHECK block-active-during-copy, backup-terminal-state, connectivity-recovered, node-healthy, followup).
