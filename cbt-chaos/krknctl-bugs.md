# krknctl/krkn bugs found during the CBT chaos campaign

Live-proven tooling defects encountered while running `cbt-chaos/scenarios_v2/*` on OpenShift 4.22.15 / CNV 4.22.12 via `krknctl` on cloud05. Each entry: symptom, root cause (source-verified where noted), workaround, and the campaign runs it burned. Append-only; newest last.

---

## 1. cpu-hog (and memory-hog) workload image crashes: readOnlyRootFilesystem

- **Symptom (CBT-F-10 r01):** krknctl cpu-hog run fails immediately; run dir archived `20261012-cbtf10-r01-invalid-hog-readonly-fs`.
- **Root cause:** the hog workload container writes its job file under the read-only root filesystem (`securityContext.readOnlyRootFilesystem: true`) and dies before starting workers.
- **Workaround (used in F-10 r02, PASS):** direct injection with the same pinned image and parameters via `kubectl run`:
  `quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog`, command `bash -c "cp /stress-ng/*.template /stress-ng/run.sh /dev/shm/ && cd /dev/shm && HOG_TYPE=cpu WORKERS=32 LOAD_PERCENTAGE=60 CPU_METHOD=all DURATION=90 ./run.sh"`, securityContext `{"privileged":true,"readOnlyRootFilesystem":true}` (copy-to-/dev/shm pattern avoids the ro-rootfs write). Documented in the F-10 spec §4 as a sanctioned fallback (krkn cannot preserve action/target/timing otherwise).

## 2. Boolean flags have no defaults — both `--ingress` and `--egress` required

- **Symptom (CBT-F-12 r01):** `krknctl run pod-network-filter` fails config validation before any cluster action: `field egress doesn't have a default and cannot be nil or empty for type boolean` (same for `ingress` if omitted). Run archived `20261013-cbtf12-r01-invalid-missing-egress-flag`.
- **Root cause:** krknctl CLI boolean flags are optional at parse time but the scenario schema validation treats unset booleans as nil; no schema default exists. NOTE: `--dry-run` only catches this when the flag set being validated is the exact one used live.
- **Workaround:** always pass BOTH flags explicitly (`--ingress=false --egress=true`).

## 3. `--namespace` is the TARGET pod's namespace, not a workload namespace

- **Symptom (CBT-F-12 r02):** runner error `pod virt-controller-6f7bc6b44c-srskv not found in namespace vm-cbt-demo`; no helper, no filter. Run archived `20261013-cbtf12-r02-invalid-wrong-namespace`.
- **Root cause:** for pod-* scenarios the `--namespace` value is passed straight into the plugin config as the namespace where the TARGET pod is looked up (and where the helper `pod-filter-*` pod is created). The CLI help text ("Namespace where the scenario container will be deployed") is misleading.
- **Why F-11 masked it:** in F-11 the target (virt-launcher pod) legitimately lived in vm-cbt-demo, so the same value was correct for both meanings.
- **Workaround:** pass the target pod's namespace (e.g. `--namespace openshift-cnv` when targeting virt-controller).

## 4. `--pod-name` does not populate the plugin's `target` field → "neither node selector nor node_name (target) specified, aborting"

- **Symptom (CBT-F-12 r03):** krknctl accepted the invocation (and `--dry-run` passes ✔✔✔) but the plugin aborts at target resolution: `neither node selector nor node_name (target) specified, aborting.` Run archived `20261013-cbtf12-r03-invalid-missing-node-name`. Generated scenario params show `"target": ""` even though `--pod-name virt-controller-…` was given.
- **Root cause (source-verified, krkn main @ 2026-10):** `AbstractNetworkChaosModule.get_pod_targets()` resolves targets from `config.label_selector` OR `config.target` only. krknctl maps `--pod-name` to a different field (`pod_name`) that the network_chaos_ng plugin never reads; the `NetworkFilterConfig.target` field is what `get_pod_targets` needs, and krknctl exposes no `--target` flag in `pod-network-filter --help` (121 flags dumped; no plain `--target`, `--node-name`, or `--node-selector`). The plugin and the CLI disagree on the config schema.
- **Why F-11 masked it:** F-11 ran krkn via the same CLI but on krkn-hub container-scenarios-era code path where the target resolution differed / target was derived. (Exact F-11 code path TBD — same plugin family, different scenario invocation shape.)
- **Status:** possible workaround under test — the `--target` flag, though undocumented in `--help`, is ACCEPTED by `krknctl run pod-network-filter` (dry-run ✔✔✔ with `--target <name>`, and with both `--pod-name X --target Y`, suggesting both map into the config). Pending live validation in F-12 r04; if `--target` reaches `NetworkFilterConfig.target`, `get_pod_targets` → `check_if_pod_exists(target, namespace)` succeeds and the module runs with `target` as the pod name.
- **Fallback if `--target` doesn't reach the plugin:** bypass krknctl for this scenario — direct injection reproducing the plugin's mechanism (source-verified): privileged hostPID helper pod in the target's namespace on the target's node, resolve target container PIDs via /proc cgroup scan, `nsenter --target <pid> --net -- iptables -I OUTPUT 1 -p tcp --dport 443 ... -j DROP`, sleep, remove, delete helper. Or run upstream `krkn-chaos/krkn` directly via `run_kraken.py` with a hand-written scenario YAML (where `target:` can be set directly in the list-of-configs schema the plugin reads).

## 5. `--dry-run` does not validate target resolution

- **Symptom:** F-12 r03 dry-run passed ✔✔✔ for an invocation the live run rejected in <1s (bug #4); r01's dry-run also passed while the live run failed on a missing boolean (bug #2).
- **Root cause:** dry-run validates schema/required-fields/value-constraints only; it does not populate the plugin config the way the live path does, nor attempt target resolution.
- **Workaround:** treat dry-run as necessary-not-sufficient; belt-and-braces grep of the live krknctl.log for known abort strings ("not found in namespace", "neither node selector", "doesn't have a default") immediately after the watcher returns, before declaring the run valid.

## 6. WORKAROUND VALIDATED: run upstream krkn directly via `run_kraken.py` with a hand-written scenario YAML

- **Context (CBT-F-12):** krknctl cannot express the plugin's `target` field (bug #4). Per user direction, pulled `krkn-chaos/krkn` and ran it directly.
- **Recipe (all on cloud05):**
  1. `podman pull quay.io/krkn-chaos/krkn:latest` — official runner image, has krkn+krkn-lib 7.0.3 preinstalled under `python3.11` (`python3` in that image is 3.15 and lacks deps; MUST invoke `python3.11 run_kraken.py`). Host-clone of the repo + pip is a dead end on RHEL9 (system python 3.9; krkn-lib 7.0.3 requires ≥3.11 and PyPI tops out at 5.1.13).
  2. Scenario file (list-of-configs schema, same fields the factory reads) with the `target:` field set directly:
     ```yaml
     - id: pod_network_filter
       image: "quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos"
       wait_duration: 1
       test_duration: 60
       label_selector: ""
       service_account: ""
       taints:
         - node-role.kubernetes.io/master:NoSchedule   # REQUIRED when target pod runs on a tainted node (controller replicas on masters) — else helper stays Pending: "untolerated taint(s)"
       namespace: "openshift-cnv"                       # target pod's namespace (bug #3)
       instance_count: 1
       execution: serial
       ingress: false
       egress: true
       target: "virt-controller-6f7bc6b44c-srskv"       # the field krknctl can't set (bug #4)
       interfaces: []
       protocols: [tcp]
       ports: [443]
     ```
  3. Kraken config with upstream schema keys (`kraken.chaos_scenarios` list, `tunings`, `cerberus`, `performance_monitoring`, `telemetry`, `elastic` — ALL top-level sections required or KeyError).
  4. Mount work dir + kubeconfig copy with `-v /tmp/f12krkn:/work:Z` (host /root can't be SELinux-relabelled).
- **Proof it works:** run bd0562c6 — helper scheduled on the leader's node, egress tcp/443 DROP applied, lease failover srskv→m5kzb (`LeaderElection: m5kzb became leader`), krkn finished successfully with resiliency report. This is the injection F-12 wanted.

## 7. RULE LEAK: iptables filter survives chaos end when the target container restarts mid-chaos

- **Symptom (direct-krkn test, 2026-10-13 03:13–03:19Z):** krkn "Successfully finished" and deleted its helper pod, but the target pod `virt-controller-…-srskv` remained unable to reach `172.30.0.1:443` (curl exit 28, reflector `Failed to watch` errors) and crash-looped on liveness/readiness (connection refused on its own 8443). The standby renewed the lease via the same VIP fine, so the API path itself was healthy.
- **Root cause (source-verified + live-proven):** krkn's cleanup (`clean_network_rules_namespaced`) nsenters into the container PIDs captured at apply time. The liveness kill restarted the container at 03:17:39Z while the filter was active; the removal then targeted dead PIDs (pod netns persists across container restarts — the rule stayed active in the sandbox). krkn deleted the helper anyway and reported success.
- **Impact:** silent permanent isolation of the target pod: crash-loop persists indefinitely after chaos "completed successfully". Recovery: delete the target pod (new netns = clean rules). Deleting srskv restored 1/1 Running within ~60s.
- **Campaign implication:** any F-12-style run where the block itself trips the controller's liveness probe will produce this leak; it's a krkn cleanup defect to file upstream, and scenario specs must treat "target pod connectivity post-chaos" as a verification criterion.

## 8. SEMANTIC: container-scenarios `--action N` sends SIGTERM to PID N, not signal N

- **Symptom (CBT-I-08 design review, 2026-10-13):** the flag help says "kill signal to run. For example 1 ( hang up ) or 9", implying `--action 9` = SIGKILL. Source (container_scenario_plugin.py:95): `kill_action = "kill " + str(action)`, executed via `exec_cmd_in_pod` → `bash -c "kill 9"` inside the container. That is SIGTERM to the process with PID 9 — a NO-OP in containers without a PID 9 (virt-launcher compute containers run PIDs 1/8/24/25/<qemu-kvm>).
- **Impact:** `--action 9` silently kills nothing (krkn still reports "successfully injected"); `--action 1` is the meaningful "stop the container" (SIGTERM to PID 1). The validated range check (1-15) matches Linux signals, reinforcing the misreading.
- **Workaround used:** `--action 1` for container stop; document PID maps per target image before choosing an action value. Live-verified on virt-launcher compute (I-08 r01/r02).
- **Related:** krkn's container-recovery check polls the killed container's `ready` state — with restartPolicy=Never launcher pods the pod TERMINATES and is replaced by a new pod, so the check measures pod replacement (~21.6s) and is non-authoritative for launcher targets.

## 9. krknctl node-memory-hog does not create its target namespace → pod create 404

- **Symptom (CBT-X-01 r01, 2026-10-13):** `krknctl run node-memory-hog --namespace x01-hog-…` fails; krkn pod-creation step 404s because the namespace doesn't exist (krknctl never creates it).
- **Workaround:** pre-create the namespace before invoking krknctl.

## 10. krkn-hub hog image writes its jobfile to a read-only WORKDIR → instant exit 1 in-cluster

- **Symptom (CBT-X-01 r02, reproduced standalone):** hog container fails ~1s after start with `run.sh: line 41: hog-jobfile.conf: Read-only file system` (exit 1). The workload image (`quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog`, WORKDIR /stress-ng) renders `hog-jobfile.conf` + `*-hog.conf.template` in PWD; for krkn-scheduled pods on OpenShift the image layer is not writable. krkn create_pod then waits 120s for Running and aborts.
- **Impact:** node-memory-hog (and any hog variant using that image via krkn) is unusable as-is in-cluster; krknctl exposes no writable-WORKDIR mount.
- **Workaround (validated, CBT-X-01 r04):** direct pod with `command: ["/bin/bash","-c","cp -r /stress-ng/. /work/ && cd /work && bash run.sh"]` + emptyDir at /work; same image and env (HOG_TYPE/VM_BYTES/WORKERS/DURATION). Verified: stress-ng 4/4 vm workers, 90.78s, max-rss 49GiB.

## 11. pod_network_filter with `ports: []` is NODE-DESTRUCTIVE: host-netns all-ports DROP + failed cleanup = permanent node outage

- **Symptom (CBT-X-03 r02, 2026-10-13 17:22Z):** direct-krkn pod_network_filter targeting ONE launcher pod with `ports: []` (= block all traffic, per models.py NetworkFilterConfig default [] + utils_network_filter.generate_rules empty-ports branch). krkn resolved 8 pids on the node for the pod's container — evidently including host-side helper processes — and applied all-ports tcp+udp DROP INPUT/OUTPUT rules via `nsenter --target <pid> --net`. The node's host network namespace lost ALL TCP/UDP (kubelet→API dead, SSH dead; ICMP still fine). Node d38-h18-000-r660 NotReady at 17:22:49Z; ALL pods on it evicted.
- **Compounding failure:** the rule-removal step FAILED (`[ERROR] failed to execute command: (0)` at 17:24:49Z; no "removing iptables rules" line) → the leak is PERMANENT until node reboot. krkn overall exit FAIL(1).
- **Contrast (r01):** same pattern with `ports: [22,443]` leaked only those ports — node stayed Ready because kubelet/API use other ports; cleanup succeeded (rc=0).
- **Root cause (source-verified):** `apply_network_rules` nsenters into every pid returned by the pod's container-id resolution on the node; with no `--dport` constraint, any host-netns pid in that set takes down the host network. Cleanup failure is a separate defect (exec through the dead network path).
- **Impact/rule:** `ports: []` pod_network_filter is effectively a node kill switch on this stack (OCP 4.22 / cri-o). NEVER run it without out-of-band node access; prefer explicit port lists for "block all traffic" scenarios.
- **Recovery:** node reboot (in-memory rules; nothing persisted). BMH unmanaged → manual/IPMI.

## 12. Image pulls by tag fail on nodes with restricted egress; krkn-hub images are node-cached only where previously pulled

- **Symptom (EXP-5 r01c, 2026-10-14):** privileged helper pods scheduled on node d38-h07-000-r660 (virt-controller leader's node) failed with `ErrImagePull`/`ImagePullBackOff` for THREE different images — `registry.redhat.io/rhel9/toolbox:latest`, `quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog`, `registry.redhat.io/rhel8/support-tools:latest` — all with `rpc error: code = DeadlineExceeded` (pull timeout, not auth/not-found). Meanwhile the same tags pulled fine on d38-h18-000-r660 earlier the same day (the hog scenarios ran there), and `oc debug node` pods (which use a different namespace/pull path) worked on d38-h07.
- **Root cause:** node-level registry egress is unreliable/restricted on d38-h07 (infra nodes with different network policy than the worker running the campaign VMs). Not a krknctl defect per se, but it breaks any krkn-hub pod scheduled onto such nodes — krkn schedules its workload pods onto the TARGET's node, so any scenario targeting infra-node components (virt-controller leaders on masters/infra) hits this.
- **Workaround (validated, EXP-5 r01c):** use an image already cached on the target node with `imagePullPolicy: IfNotPresent`. Find cached images via `oc debug node/<node> -- chroot /host crictl images`. On d38-h07 the F-11 run had cached `quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos`; a privileged hostPID helper pod from that image ran fine. For arbitrary commands prefer images with bash (the krkn-hub multiarch images have it).
- **Related lesson (same run):** container-internal `kill` on PID 1 is silently ineffective for stopping the process (OCI runtime protects container-init from non-handled signals); `oc exec <pod> -- kill -STOP 1` reports success but state stays S. To freeze a container's main process, signal its HOST pid from a privileged hostPID helper (`crictl inspect <crid>` → `.info.pid`, then `kill -STOP <hostpid>`; verified state T/S transitions live).
