# Scenario: CBT-F-11

**Jira:** CBT-F-11 — Block network traffic to the virtual machine during backup startup
(`cbt-chaos/scenarios_v2/CBT-F-11/jira-issue.md`; row in `cbt-chaos-test-plan-v2.csv`).

## 1. Objective / Hypothesis

Verify that an IP-level network filter on the virt-launcher pod, applied after the full
backup request starts but before the live copy begins, does not interrupt the backup.
The hypothesis under test (from the issue): the backup data path (QEMU reading the local
CBT chain and writing the destination PVC) and the handler-to-launcher control path are
node-local — not dependent on the launcher pod's IP — so an IP-level filter on that pod
should have no effect on the backup's outcome.

## 2. Workflow

Full backup only (`make e2e TYPE=full`). This checkout's active `e2e` target
(`scripts/e2e-stage.sh`, confirmed identical on the local checkout and the `cloud05`
remote checkout at commit `9adb186`) consumes `TYPE`/`NAME`; `TYPE=full` creates a new
run ID (`NAME=<RUN_ID>`), sets up a fresh VM, and takes its full backup. No incremental
pass or existing managed VM is needed for this issue — a new lifecycle is created per
run and torn down by the usual scenario workflow, never `make clean-all`.

## 3. Chaos Injection

**Target:** the virt-launcher pod for the run's VM, selected by
`vm.kubevirt.io/name=vm-<RUN_ID>` in namespace `vm-cbt-demo` (the pod's generated suffix
is unknown ahead of time, so `--pod-selector` is used instead of `--pod-name`).

**Scenario:** `pod-network-filter` (`krknctl list available` confirms the tag; it matches
the issue's own "Technical Scenario" field exactly). Live-validated on `cloud05`:

```bash
krknctl run pod-network-filter \
  --namespace vm-cbt-demo \
  --pod-selector 'vm.kubevirt.io/name=vm-<RUN_ID>' \
  --ingress=true --egress=true \
  --protocols tcp,udp \
  --ports 22,53,67,68,80,111,123,179,443,2379,2380,5900,5901,6443,8080,8443,9100,9443,10250,10255,10256,30000 \
  --chaos-duration 60 \
  --trigger-command '<see §4>' \
  --trigger-expected-rc 0 \
  --triggers-interval 1 \
  --triggers-timeout 3600 \
  --triggers-on-timeout fail \
  --kubeconfig <KUBECONFIG_PATH> \
  --dry-run
```

`--dry-run` on `cloud05` returns `Scenario schema valid / All required fields present /
Values validated` for this exact invocation (ports list substituted for a placeholder VM
name). `chaos-trigger.sh` runs the same command without `--dry-run`, gated by the
trigger in §4, started before `make e2e TYPE=full` so krknctl's own container pull/init
latency is absorbed while it polls.

**A true "block all ports/protocols" filter is not reachable through krknctl's CLI —
documented gap, not a shortcut:**

- Live evidence on `cloud05` (via `oc exec ... -c compute -- ss -tulnp`/`ss -tuap` against
  an existing `virt-launcher-*` pod): the `compute` container has **zero** listening TCP
  ports, **zero** established connections, and exactly one UDP listener (`:67`, the
  guest's own DHCP service — irrelevant to backup/control traffic). This independently
  confirms the issue's own premise before any chaos is injected.
- The `compute` container's `securityContext` drops all capabilities except
  `NET_BIND_SERVICE` (no `NET_ADMIN`), so it cannot run `iptables` itself — matching why
  Krkn's own `pod_network_filter` module deploys a separate privileged helper pod and
  `nsenter`s into the target's network namespace rather than exec'ing into the target
  directly (confirmed by reading
  `krkn/scenario_plugins/network_chaos_ng/modules/pod_network_filter.py` and
  `utils_network_filter.py` inside the pulled
  `workload-krkn-network-chaos` image on `cloud05`).
- Those same source files show `generate_rules()` treats an **empty** `ports` list as
  "block all traffic on all ports" — the underlying Krkn library supports a true IP-level
  (all-port) filter. But `krknctl`'s CLI layer marks `--ports` **required** with a format
  validator; live `--dry-run` testing confirmed blank, a range (`1-65535`), and `all` are
  all rejected (`Network ports must be in the format: 8080 or a comma separated list
  8080,8081,8082`); only literal comma-separated port numbers validate.
- Given this CLI constraint, the scenario uses a deliberately broad, documented port list
  (22 ports, both `tcp`/`udp`, both directions — 22/53/67/68/80/111/123/179/443/2379/2380/
  5900/5901/6443/8080/8443/9100/9443/10250/10255/10256/30000) spanning the service classes
  (DNS, NTP, SSH, HTTP(S), BGP, etcd, VNC, kube-apiserver, webhooks, kubelet, NodePort)
  that could plausibly traverse a pod's primary interface, rather than an exhaustive
  1–65535 enumeration (which the plugin would apply as one `iptables`/`nsenter` `oc exec`
  per port × protocol × direction — thousands of sequential execs, impractical and not
  needed given the live evidence above that this pod has no real listeners in that range
  anyway). This is an intentional, user-approved compromise, not a literal "all ports"
  block; record it as a known scope limitation in the final report (see
  `cbt-chaos-issue-triage-learnings.md` for the reusable form of this finding).
- Considered and rejected: a narrow `oc debug node` + `nsenter`/`iptables -j DROP` (no
  `-p`/`--dport`) fallback would achieve a true block-all, but requires deploying our own
  privileged mechanism and reimplementing Krkn's own (already-tested) pid-resolution and
  guaranteed-cleanup logic — higher risk than the broad-port-list compromise for this P2
  architectural-isolation test. Revisit if the issue needs a literal all-ports guarantee.

## 4. Injection Timing

**Deterministic condition (r03, after r01 proved the window empty and r02 proved the missing-object trap):**

```
the vmbackup object EXISTS (--ignore-not-found name probe is non-empty)
  AND status.conditions[type=Done].status != "True"     # not yet terminal
  AND the launcher pod exists for vm.kubevirt.io/name=vm-<RUN_ID>
  AND that launcher pod has a non-empty spec.nodeName   # scheduled
```

r01 (archived `20261013-cbtf11-r01-invalid-empty-window`) never fired: its
condition required `Progressing=True` AND `virsh backup-dumpxml` FAILING
(pre-copy), but the observer's raw watch stream proved `Progressing` flips to
True at the same instant the libvirt copy starts (backup created 01:32:32Z,
`Progressing=True` + copy start 01:32:34Z, Done 01:33:26Z), and the true
pre-copy phase (`Initializing`) lasts ~2 s — shorter than krkn's helper-pod
deployment latency. r02 (archived
`20261013-cbtf11-r02-invalid-helper-unschedulable`) fired 68 s TOO EARLY:
without an existence check, `oc get` on the not-yet-created backup object
returns empty and `Done != True` is vacuously true; the launcher pod existed
but was still Pending with no node assigned, so krkn resolved the target node
as None and created its helper pod with `nodeSelector
kubernetes.io/hostname=None` — unschedulable (FailedScheduling, 0/31 nodes),
no filter ever applied ("Pod creation failed Starting pod failed" after the
300 s pod-wait). r03 adds the existence guard and the node-assignment guard:
the backup must exist and the launcher must be scheduled, which by
construction holds right after backup creation and before the copy starts;
the chaos tool's helper pod then lands on the launcher's node and the 60 s
filter spans the first ~60 s of the copy (the copy takes ~54 s, so it covers
essentially the whole live copy — a superset of the issue's window that still
contains it).

**How we watch for it:** `chaos-trigger.sh` passes this as `krknctl`'s native
`--trigger-command` with `--trigger-expected-rc 0`, `--triggers-interval 1`,
`--triggers-timeout 3600`, and `--triggers-on-timeout fail`. The exact
expanded condition string was validated with `bash -c` against live objects
before the run: missing objects → rc=1, terminal-state backup → rc=1 (only a
live pre-Done backup with a scheduled launcher yields 0). `krknctl` is
started before `make e2e TYPE=full` so its container pull/init cost is
absorbed while it polls.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass (confirms the issue's hypothesis):**
- `krknctl` reports the trigger fired and the filter was applied and removed
  automatically after `--chaos-duration 60`.
- The full backup reaches `Done=True` with reason that is not KubeVirt's terminal
  `Backup has failed: ...` wording, `status.type=Full`, a non-empty `checkpointName`, and
  `includedVolumes` still identifying the expected `vda`/`rootdisk` volume.
- The launcher pod is never replaced/restarted during or after the filter window (compare
  `.metadata.uid` before/after); `virsh checkpoint-list --tree` shows the single expected
  full checkpoint.
- The repository restore verifier reconstructs the full-only image and its file count and
  canonical manifest hash match the baseline guest workload.

**Fail (contradicts the hypothesis — requires investigation, not automatic product
failure, since a harness-side miss is also possible):**
- `Done=True` with a terminal failure reason, or the backup never reaches `Done=True`
  within its normal timeout, while the filter was confirmed applied in-window.
- The launcher pod is replaced/restarted, or CBT state regresses, coincident with the
  filter window.
- `krknctl` reports trigger timeout (`--triggers-on-timeout fail`) — this is a harness
  miss (chaos never landed), not a product result; re-run, do not record a pass or fail.

**Verification commands:**
```sh
oc get vmbackup vm-backup-<RUN_ID> -n vm-cbt-demo -o yaml
oc get vm vm-<RUN_ID> -n vm-cbt-demo -o yaml
oc exec -n vm-cbt-demo <launcher-pod> -c compute -- \
  virsh checkpoint-list "vm-cbt-demo_vm-<RUN_ID>" --tree
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp
```
Then the repository's full-only restore verification for the guest file count/manifest
hash. Read the backup object twice after reconciliation if judging a race; a transient
event can report failure before the final object settles (`docs/cbt/10-chaos-test-design.md`).

This scenario does not disrupt the backup, so the staged recovery/retry flow
(`make e2e TYPE=recover ...`) is not expected to run; only invoke it if the backup
actually fails and needs to be investigated as an unexpected regression.

## 6. Blast Radius, Prerequisites, Recovery, Known State Conflicts

- **Blast radius:** one `pod-network-filter` workload targeting exactly one launcher pod
  (selected by the run-unique `vm.kubevirt.io/name=vm-<RUN_ID>` label), 22 ports, both
  directions, both protocols, for 60 seconds. No other namespace resources are touched.
  The filter is removed automatically by the krknctl workload after
  `--chaos-duration` elapses (confirmed by reading `pod_network_filter.py`'s
  `time.sleep(self.config.test_duration)` followed by rule cleanup) — no manual recovery
  step is required by design, matching the issue's stated recovery.
- **Prerequisites:** `krknctl`, `oc`, `jq`, `make` on the execution host; a unique
  `RUN_ID`; `KUBECONFIG_PATH` set to the approved host-local kubeconfig; no existing
  cluster resources named for that `RUN_ID`.
  **Live evidence used to design this scenario:**
  - `cloud05` is the configured `REMOTE_HOST` (`cbt-setup/.env`); the remote checkout is
    at `9adb186`, with an `e2e` target matching the local checkout's `TYPE`/`NAME`
    contract.
  - Namespace is `vm-cbt-demo`; multiple other scenario runs' VMs/backups already exist
    there (e.g. `vm-20261010-cbt-f-01-*`). CBT-F-11 must use its own unique `RUN_ID` and
    must not reuse or target any existing run's resources — `chaos-trigger.sh` enforces
    this before starting.
  - `pod-network-filter`, `vmi-network-filter`, `node-network-filter`, and
    `workload-krkn-network-chaos` are all present in the configured registry
    (`krknctl list available`, snapshot 2026-10-12 — recheck for future runs).
- **Known state conflicts:** none specific to this scenario beyond the general rule of
  one lifecycle per `RUN_ID`/namespace at a time (`docs/cbt/10-chaos-test-design.md`'s
  "Cloud05-specific cautions": multiple simultaneous CBT VMs can share a worker/HPP pool,
  so attribute any anomaly carefully).
- **Unresolved uncertainty:** the actual wall-clock width of the "Progressing=True but
  copy not started" window has not been measured live for this backend/manifest
  combination; if the trigger consistently times out, narrow `--triggers-interval` further
  or capture `scripts/monitor.sh` output to confirm the real window before concluding the
  signal is unreachable. The 22-port compromise (§3) is a documented approximation of
  "IP-level", not a literal all-ports/all-protocols block — call this out explicitly when
  reporting the result.
