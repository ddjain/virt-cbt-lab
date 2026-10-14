# Scenario: Node CPU pressure during a full backup

- **Jira:** CBT-F-10 — Create CPU pressure during a full backup
- **Priority:** P2
- **Technical scenario:** node-cpu-hog
- **Chaos phase:** Active operation

## 1. Jira objective and hypothesis

Measure the effect of node CPU pressure on backup completion and data correctness. A privileged hog pod on the VM's node runs `stress-ng --cpu` workers at a controlled load percentage for 90 s, covering the active copy. Expected: the backup may take longer and the QEMU freeze/thaw during checkpoint creation may produce a warning, but the operation completes with correct backup data; node and VM remain healthy. This measures resilience to compute contention without introducing uncontrolled VM failure.

Issue fields: workflow **Full backup**; target **CBT worker node hosting the VM**; action **generate controlled CPU load on the node**; timing **during the active disk-copy period**; signal **full backup is actively copying**; duration **90 seconds**; recovery **CPU load stops automatically**; verification **node and VM healthy, record duration and any warning, validate restored data**.

## 2. Evidence and live target resolution

- **Node determinism:** every campaign VM is scheduled onto `d38-h18-000-r660` (all vm-cbt-demo launchers run there; 27/31 nodes lack `devices.kubevirt.io/kvm`; the launcher's machine-type/obsolete-host-model constraints are satisfied by a handful of nodes but the scheduler has consistently chosen `d38-h18`, which is also the only node with the HostPath pool disk). The trigger pre-checks the VMI node after VM creation and aborts as harness-invalid on mismatch (same guard pattern as F-09).
- **Hog mechanism (verified from krkn source + the workload-krkn-hog image):** `node-cpu-hog` deploys one privileged pod per selected node with `nodeSelector kubernetes.io/hostname=<node>`, env `HOG_TYPE=cpu`, `LOAD_PERCENTAGE=<--cpu-percentage>`, `CPU_METHOD=all` (default), `WORKERS` = `--cores` if set else the node's CPU count (krkn `run_scenario_worker`: "if not config.workers: config.workers = lib_k8s.get_node_cpu_count(node)"). The container's run.sh renders `cpu <workers>` + `cpu-load <percentage>` + `timeout <duration>` into a stress-ng jobfile: **N workers each pinned at LOAD_PERCENTAGE**, i.e. `--cores`/workers sets how many CPU workers run, `--cpu-percentage` sets each worker's load. (`krknctl describe node-cpu-hog` shows `--cores`, `--cpu-percentage` (default 50), `--chaos-duration` (default 60), `--node-selector`, `--number-of-nodes`, `--namespace`, `--taints`, `--image`.)
- **Sizing:** the node has 112 CPUs (110610m allocatable). Default `--cpu-percentage 50` with `--cores` unset would run 112 workers at 50% each = ~56 full CPUs of load — heavy but the node is huge and mostly idle; the VM launcher uses a fraction of one CPU. To keep controlled, measurable pressure on the copy path (QEMU + launcher + virt-handler on that node) without risking the 10 other idle campaign VMs' eviction/watchdog behavior, set `--cpu-percentage 60` and `--cores 32` (≈19–20 CPUs of sustained load): clearly observable contention, far from saturation. (Contrast: F-05's SIGKILL to virt-handler — a real outage — caused no VM death; pure CPU pressure at this level is safe.)
- **Variant:** `default` (HostPath) keeps the same deterministic placement and the same measured baseline (~52–55 s full copy on this workload) as F-07/F-09, so the duration comparison is directly interpretable. CPU pressure is storage-backend-agnostic; HostPath additionally exercises the pool disk on the same node (the copy path's I/O + CPU both contend).
- **Freeze/thaw warning expectation:** during full-backup checkpoint creation KubeVirt freezes/thaws the guest filesystem (QEMU guest agent); under CPU contention the freeze window can lengthen and virt-launcher logs may show a freeze/thaw warning. The observer captures launcher `Freezing|Frozen|Thaw` log lines and VMI `Pause`-type conditions; a warning is acceptable per the issue, a hard VMI failure is not.

## 3. Workflow and prerequisites

`make e2e TYPE=full NAME="$RUN_ID"` with `VM_OS=rhel9`, `MANIFEST_VARIANT=default` (force-set), `.env`-default guest workload (1000 × 15–20 MiB). Follow-up planned incremental pass + restore verification (success path).

Prerequisites: `d38-h18-000-r660` Ready; unique `RUN_ID`; no other CPU-sensitive campaign run in flight on that node (serialize with F-09-style node-hog scenarios); hog namespace absent.

## 4. Target and validated disruption

**Injection (direct kubectl pod; krknctl fallback — r01 finding):** the first attempt used `krknctl run node-cpu-hog --node-selector "kubernetes.io/hostname=d38-h18-000-r660" --cpu-percentage 60 --cores 32 --chaos-duration 90 --trigger-command <compound>` and the run was archived invalid (`20261013-cbtf10-r01-invalid-hog-readonly-fs`): krkn's hog pod template sets `readOnlyRootFilesystem: true` while the image's `run.sh` writes its stress-ng jobfile to the container CWD, so the cpu-hog pod died in ~1 s (`hog-jobfile.conf: Read-only file system`) and no pressure was applied. Only the io branch receives a writable volume, which is why F-09's io-hog worked. Per the run skill's sanctioned fallback ("a custom event observer followed by a direct, narrowly scoped `oc`/`kubectl` mutation is acceptable when Krkn cannot preserve the exact action/target/timing, with the reason documented"), the trigger now:

1. Polls the identical compound active-copy condition (`Progressing=True` AND `Done≠True`, 3 s) itself;
2. At satisfaction, re-reads the backup to confirm the window is still open, then creates one pod via `kubectl run` on the hog namespace: same pinned krkn hog image, `nodeSelector kubernetes.io/hostname=d38-h18-000-r660`, `privileged: true`, and the `/dev/shm` workaround (copy the image's templates + `run.sh` to tmpfs, run from there) that was live-validated on the target node (measured `cpu-usage-per-instance` ≈ LOAD_PERCENTAGE; exit 0);
3. Records a UTC action-request line with the exact pod/node/backup identity;
4. After the backup settles, verifies the hog pod reached `Succeeded`/exit 0 (else the run is harness-invalid, exit 4) and preserves its YAML + log before namespace cleanup.

Hog parameters unchanged: 32 stress-ng cpu workers at 60% each, 90 s, on `d38-h18-000-r660`.

**Pre-run guards:** VMI nodeName must equal `d38-h18-000-r660` (post-backup check; abort 3 on mismatch), hog namespace must not pre-exist, RUN_ID collision guard.

## 5. Deterministic injection signal

Command trigger on `vm-backup-${RUN_ID}`: `Progressing=True` AND `Done≠True`, 3 s poll. Hog runs 90 s from trigger satisfaction (covers the whole remaining copy window). Observer records trigger satisfaction, hog pod spec (node, env: LOAD_PERCENTAGE/WORKERS/DURATION), hog start/end, backup terminal time/reason, duration vs. ~52–55 s baseline, freeze/thaw warnings, VMI state, tracker, restore results.

## 6. Pass/fail criteria

A product **pass** requires all:

- Injection: hog pod Running on `d38-h18-000-r660` with CPU hog env, within the copy window; VM VMI node == hog node.
- Backup completes successfully: `Done=True`, reason `Successfully completed VirtualMachineBackup`, `status.type=Full`, one checkpoint, expected included volumes, tracker advanced exactly once.
- Duration and warnings: record actual duration (vs. ~52–55 s baseline) and any freeze/thaw warning (expected per issue); a longer duration is acceptable; correctness is the criterion.
- Node/VM health: node stays Ready; VM/VMI Running/Ready with CBT `Enabled` throughout; no VMI crash/restart/migration; no launcher watchdog reset.
- Post-chaos same-VM verification: planned incremental pass + restore verification pass (counts, bytes, hashes).
- Hog cleanup: pod exits at 90 s; namespace deleted; no leftover.

**Evidence:** hog pod YAML + log, vmbackup conditions/reason + duration, tracker snapshot, summary.json timings, launcher freeze/thaw log lines, VMI conditions, restore-verify log, observer streams.

## 7. Blast radius, recovery, and conflicts

~20 CPUs of load on a 112-CPU node for 90 s: affects CPU-sensitive workloads on `d38-h18-000-r660` (idle campaign VMs' launchers, storage pods on that node). No disk-space impact (CPU hog writes nothing). Recovery automatic (stress-ng timeout). Serialize with other node-hog scenarios on the same node.

Unresolved/uncertain: whether 60%×32 workers measurably lengthens the copy (the copy is largely I/O-bound; page-cache absorption may hide CPU contention — F-09 showed 68 s vs 55 s under disk pressure). Degradation magnitude is an observation; correctness is the verdict criterion.
