# Scenario: Block the backup controller leader's access to the Kubernetes API during a full backup

## 1. Identity

- **Scenario ID:** CBT-F-12
- **Jira issue:** CBT-F-12 — "Block controller access to the Kubernetes API during a full backup" (P2, technical scenario: pod-network-filter, phase: operation start)
- **Run family:** full-backup workflow, controller-plane disruption

## 2. Objective and hypothesis

**Jira objective:** verify that controller failover can recover from loss of API connectivity to the current controller leader without creating duplicate checkpoint state. Expected: the isolated leader loses its lease, a standby takes over, and the backup completes with exactly one checkpoint and no duplicate state.

**Product question:** does a 60 s network block between the *current* virt-controller leader and the API server (while the backup is being reconciled) cause lease failover cleanly, with the backup completing correctly and the tracker recording exactly one checkpoint per backup?

## 3. Workflow and prerequisites

Same managed lifecycle as F-07/F-09/F-10: `make e2e TYPE=full` with `RUN_ID`, RHEL 9 guest, host-path (`default`) storage variant so the backup destination is node-local (the controller-plane disruption is independent of storage, but the variant keeps node determinism and the measured 52–55 s baseline). 1000-file × 15–20 MiB baseline workload, 1 planned incremental pass, restore verification in the final pass.

Prerequisites:

- `virt-controller` deployment runs ≥2 replicas (verified: 2 running, one leader per the `virt-controller` Lease in `openshift-cnv`).
- The trigger resolves the CURRENT leader at satisfaction time from the Lease (`holderIdentity`) — leader may change between triage and run; never hard-code it.
- krknctl pod-network-filter with `--pod-name <leader>` and `--egress` filtering of TCP 443.

## 4. Target and validated disruption

**Network model (triaged live on this cluster, 2026-10-13):** the leader pod's only API-server connection is to `172.30.0.1:443` — the `kubernetes` service ClusterIP, which load-balances to the three API servers (`198.18.0.5/6/7`, the etcd/API node addresses). The controller does not talk to etcd directly. Its other established connections are inbound (its own 8443 metrics/webhook port serving scrapers and the API server's watch proxy). Therefore blocking **egress TCP 443** on the leader pod removes exactly its API connectivity (watch streams, lease renewal, and object writes) while leaving inbound traffic and all other ports untouched.

```sh
LEADER="$(oc get lease -n openshift-cnv virt-controller -o jsonpath='{.spec.holderIdentity}')"
# krknctl cannot express the plugin `target` field (cbt-chaos/krknctl-bugs.md #3/#4):
# run upstream krkn directly via the official runner image with a scenario file.
cat > scenario.yml <<EOF
- id: pod_network_filter
  image: "quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos"
  wait_duration: 1
  test_duration: 60
  label_selector: ""
  service_account: ""
  taints: ["node-role.kubernetes.io/master:NoSchedule"]  # leader's node taint, resolved at runtime
  namespace: "openshift-cnv"          # TARGET pod's namespace (helper also runs here)
  instance_count: 1
  execution: serial
  ingress: false
  egress: true
  target: "\${LEADER}"
  interfaces: []
  protocols: [tcp]
  ports: [443]
EOF
podman run --rm --entrypoint bash -v "\$PWD":/work:Z quay.io/krkn-chaos/krkn:latest \
  -c "cd /home/krkn/kraken && python3.11 run_kraken.py -c /work/kraken-config.yml"
```
The compound gating (backup `Progressing=True` AND `Done≠True`, 3 s poll) is implemented by the trigger script's own watcher, which at satisfaction re-resolves the lease holder, aborts if it rotated, then writes the scenario file with the resolved leader as `target` and starts the containerized krkn run.

Notes validated at triage:

- The scenario YAML is the plugin's list-of-configs schema read by `NetworkChaosFactory`; `target` is the pod name krknctl cannot set (r03 finding: `neither node selector nor node_name (target) specified, aborting` despite `--dry-run` ✔✔✔).
- `namespace:` is the TARGET pod's namespace (r02 finding: runner error `pod … not found in namespace vm-cbt-demo`; the helper pod also runs there). In F-11 the target launcher legitimately lived in vm-cbt-demo, which masked this.
- `taints:` must carry the target node's taint toleration (r04 pre-validation: controller replicas run on master-tainted nodes; without it the helper stays Pending `FailedScheduling: untolerated taint(s)`).
- `ingress: false`/`egress: true` both explicit — the plugin schema gives booleans no defaults (r01 finding).
- The compound condition is the same live-validated F-07/F-09/F-10 form (single-quoted JSONPath for `Progressing=True` / `Done≠True`), evaluated by the trigger's own watcher; a pre-injection leader rotation aborts the run (harness-invalid) rather than blocking the wrong pod.
- The trigger's `make e2e` call passes `MANIFEST_VARIANT="$MANIFEST_VARIANT"` explicitly (r02 finding: without it the Makefile's `large-odf` default overrode the force-set `default`, invalidating duration baselines).
- RULE-LEAK GUARD (r04 dry-run finding, krknctl-bugs.md #7): if the block trips the leader's liveness probe and the container restarts mid-chaos, krkn's cleanup nsenters dead PIDs and the iptables rule survives chaos end while krkn reports success. The trigger therefore curls `https://172.30.0.1:443/healthz` from inside the target pod after krkn exits 0 and deletes the pod (fresh netns) if unreachable. Post-run controller connectivity is part of this scenario's verification criteria.

**Pre-run guards:** VMI nodeName determinism guard (as F-09/F-10), RUN_ID collision guard, hog/scenario namespace must not pre-exist.

## 5. Deterministic injection signal

Compound condition on the run's full-backup object: `Progressing=True` AND `Done≠True` (3 s poll, `--triggers-on-timeout fail` at 1800 s). At satisfaction, the trigger resolves the current leader and applies the egress block. The block outlives the copy window only if the copy exceeds 60 s; the expected failover completes well inside it.

## 6. Success criteria

- **Injection validity:** network filter applied to the leader pod named by the Lease at satisfaction time (krknctl log + pod object evidence), egress TCP 443, 60 s, then removed.
- **Controller failover:** the Lease's `holderIdentity` changes to the standby within ~60 s of the block (verified live: `leaseDurationSeconds=15`, renewal ~10 s, so the lease expires ~15 s into the block); both replicas remain Ready throughout; the isolated leader resumes as follower after the block lifts (no crash loop).
- **Backup correctness:** full backup reaches Done=True reason "Successfully completed VirtualMachineBackup", type Full, exactly one checkpoint; tracker advanced exactly once (no duplicate checkpoint state).
- **VM health:** VM/VMI unaffected (Running/Ready, CBT enabled); the copy itself is launcher-side and node-local, expected unaffected.
- **Follow-up:** same-VM incremental pass + restore verification pass (data hashes match).

## 7. Blast radius, recovery, and conflicts

One controller replica (the leader) loses API access for 60 s; standby serves reconciles. Other CNV components unaffected. Inbound 8443 on the leader stays open (webhook serving) — the API server may see failed scrapes only. Recovery: filter auto-removed at 60 s; leader election settles. Serialize with other controller-plane scenarios (F-13). Risk: if both replicas were somehow blocked, reconciles would stall — the run uses `--pod-name` on exactly one pod to prevent that.

Unresolved/uncertain: whether the standby's takeover re-reconciles the in-flight backup and how the duplicate-checkpoint protection behaves — that is precisely what the scenario validates. A backup failure with a clean error and no duplicate checkpoints would still be a FAIL for resilience purposes but must be documented without masking.
