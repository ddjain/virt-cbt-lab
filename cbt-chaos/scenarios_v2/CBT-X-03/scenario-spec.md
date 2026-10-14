# Scenario: Block all network traffic to the virtual machine during the backup copy

## 1. Identity

- **Jira issue:** CBT-X-03 — "Block all network traffic to the virtual machine during the backup copy" (P2, technical scenario: application-outages, phase: active operation)
- **Run family:** pod-network isolation during backup copy
- **Precedents:** F-12 (pod-network filter: krkn direct-run with `target` field; iptables rule-leak bug #7 when the target container restarts mid-chaos); I-08 (Progressing gate); X-01 (background workflow + armed chaos)

## 2. Objective and hypothesis

**Jira objective:** confirm that blocking IP traffic to the launcher does not interrupt the node-local backup copy, and identify the effect on guest access used by the test harness. 45s duration. Expected: backup continues; guest SSH may stop temporarily; recovery automatic.

**Mechanics:** krkn application-outages blocks namespace/pod-selector traffic via netfilter rules (Ingress/Egress). The backup copy path is launcher-process → hostPath filesystem (node-local), NOT pod networking — the copy should be immune. The guest-SSH path (used by the workflow for workload mutation, not for the copy itself) goes through pod networking and may drop.

**F-12 lesson applied:** krkn's cleanup nsenters into the target container's PIDs captured at apply time — if the container restarts mid-chaos, the rule LEAKS (bug #7). The launcher container will NOT be restarted by this scenario (no kill), so the leak risk is low, but post-chaos connectivity verification is mandatory.

## 3. Design

1. Background `make e2e TYPE=full` + krknctl application-outages with `--namespace vm-cbt-demo --pod-selector kubevirt.io/domain=<VM>` (the launcher pod label; verify exact label from the live launcher pod), `--block-traffic-type "[Ingress, Egress]"`, `--chaos-duration 45`, gated on the backup Progressing-by-type.
2. The copy proceeds while the launcher is network-isolated. The workflow's own SSH-based steps for the FULL stage happen BEFORE backup creation (workload init), so the copy window has no SSH dependency — perfect isolation of the data path.
3. After chaos: verify launcher connectivity recovered (post-chaos `oc exec`/SSH check), backup Done=True success, then the clean incremental pass (whose guest mutation DOES need SSH — proving guest access recovered) + workflow verify.

## 4. Target and validated disruption

**Target:** the launcher pod's network namespace (ingress+egress).
**Action:** iptables DROP rules on the launcher pod for 45s.
**Window:** full backup Progressing.
**Blast radius:** single pod network namespace; the VM's guest network (SSH) blocked; VNC/console also blocked; the backup copy unaffected (node-local file I/O).

## 5. Verification criteria

- Block active during copy (trigger satisfied; krkn applied rules; 45s).
- Backup Done=True success, type Full, duration ~baseline (53-58s) — the copy must not even slow.
- Launcher pod identity unchanged, container NOT restarted (avoids the F-12 leak path).
- Guest access recovered post-chaos (incremental pass's SSH mutation works).
- Tracker advances exactly once; workflow verification bit-exact.
- Post-chaos launcher connectivity explicitly verified.

## 6. Pre-run guards

Standard. Verify the launcher pod label at trigger time. Confirm no stale iptables rules from F-12-era runs.

## 7. Uncertainties

- krknctl application-outages may target routes/pods broadly by namespace — the pod-selector must be exactly the launcher. If krknctl's selector semantics don't isolate the launcher (block includes OTHER run VMs in the namespace — 11 prior VMs share vm-cbt-demo!), fall back to the F-12 direct-krkn pattern with `target:` = this run's launcher pod. CRITICAL: the namespace has 11 other VMs' pods; a namespace-wide block would disrupt them. Prefer direct-krkn with target from the start.
- The 45s window must sit inside the ~53s copy: gate on Progressing with 2s poll (I-08: gate satisfaction to injection is ~6-8s including krkn startup — the copy is long enough).

## 8. Evidence

krkn log, applied rule evidence (krkn log prints rules), backup object + timing, launcher pod status pre/during/post, SSH recovery proof (incremental mutation success), tracker, workflow verify outputs.
