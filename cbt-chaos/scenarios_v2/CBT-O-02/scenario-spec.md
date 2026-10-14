# Scenario: O-02 kill csi-rbdplugin node pod on the VM's node mid-copy

## 1. Identity

- **Jira issue:** CBT-O-02 (P1, technical scenario: pod-scenarios via direct-krkn pod_disruption)
- **Run family:** ODF storage-access disruption during full backup copy
- **Precedents:** F-07 (HPP CSI node plugin kill — copy survived); I-06 (virt-handler kill: clean mid-copy, leak at teardown); krknctl-bugs #4/#6 (direct-krkn recipe)

## 2. Objective and hypothesis

**Objective:** is the RBD node plugin in the copy data path or only the attach path?

**Hypothesis:** the kernel rbd device (mapped at hotplug-attach) serves QEMU's writes independent of the plugin process; pod death mid-copy is a no-op for the copy (F-07 analog). The differential risk window is attach/detach (o02c).

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD (O-01 prerequisite) + VM node resolved at gate.
2. `make e2e TYPE=full ... MANIFEST_VARIANT=odf` in background.
3. At Progressing gate: resolve VM node; render pod_disruption scenario YAML (direct-krkn; krknctl pod-scenarios cannot express name-pattern AND node-names targeting — its flags map but the plugin's selection semantics randomize across nodes; the hand-written YAML pins namespace_pattern=openshift-storage, name_pattern=`^openshift-storage\.rbd\.csi\.ceph\.com-nodeplugin-`, node_names=[vm_node], kill=1, execution=serial, force per leg).
4. Kraken config: pod_disruption_scenarios list, standard tunings (X-03 r03 shape).
5. Follow-up incremental + restore verify.

## 4. Target and validated disruption

- **Target:** the single nodeplugin pod on the VM's node (hostNetwork=true; its death does not unmap /dev/rbdN).
- **Blast radius:** one node's RBD attach capability for ~10-30s. No other node affected.
- **Sizing:** 80Gi full copy window per O-01 baseline.

## 5. Verification criteria

- Injection validity: deleted pod UID ≠ replacement UID; deletion timestamp inside the Progressing window (post-hoc event proof).
- Copy outcome: Done=True/Successfully (immune) or accurate failure reason — recorded either way.
- Replacement pod Ready on the same node before the incremental stage starts.
- Tracker advances exactly once; restore verification bit-exact on success.

## 6. Pre-run guards

Standard RUN_ID/resource collision; ceph HEALTH_OK; DataSource rhel9-rbd Bound; nodeplugin DS healthy (desired==ready on the VM's node) pre-run.

## 7. Uncertainties

- Whether pod_disruption's recovery monitor (krkn_pod_recovery_time) tolerates the DaemonSet replacement cadence — set generously (600s) or expect krkn rc=1 despite successful injection (monitor-only failure; judge from events, not krkn exit alone — krknctl-bugs #5 analog).
- If the copy is shorter than plugin replacement, the copy may finish before any effect could manifest — that IS the finding (data path not in plugin).

## 8. Evidence

krkn log, plugin pod pre/post json (UIDs, timestamps), vmbackup conditions, trigger-checks.txt (CHECK injection-clean-cycle, backup-completed, plugin-recovered, followup-incremental).
