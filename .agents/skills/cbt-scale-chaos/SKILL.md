---
name: cbt-scale-chaos
description: >
  Scale-and-chaos harness for CBT backup testing on the fixed execution host
  `ssh cloud05` (checkout /root/v2/virt-cbt-lab, kubeconfig /root/mno/kubeconfig
  — all make/oc commands run there). Creates N parallel VMs (density pool),
  drives all-at-once full and incremental CBT backups with the parallel driver,
  provides a chaos-injection window mid-backup (delegating injection design to
  the cbt-chaos-simple skill), and verifies the fleet after backups complete:
  per-vmbackup Done-reason and tracker validation plus a Prometheus health
  sweep (error-rate spikes, controller restarts, storage latency, node
  pressure). Use when the user wants parallel/density backup testing with many
  VMs, optionally with a chaos injection landing during the full or incremental
  copy window. Phase 0 intake asks (only when not already stated): whether to
  clean up previous runs, OS profile (rhel9 | rhel9-light, the right-sized
  10Gi-root RHEL 9 | windows | a mixed fleet), VM count, chaos or not (with
  scenario/fire-point/blast-radius if yes), and confirms remaining defaults
  (wave size, backup StorageClasses, keep-after-run) in a single form before
  anything runs.
user_invocable: true
arguments:
  - name: n_vms
    description: >
      Number of parallel VMs, e.g. "50" or "200". When omitted the skill asks.
    required: false
  - name: os_profile
    description: >
      "rhel9" (80Gi root), "rhel9-light" (right-sized RHEL 9: 10Gi root,
      12Gi full / 2Gi incremental backup PVCs; needs `make rhel-light-golden`
      once), "windows", or "both" (mixed fleet: concurrent pools, one
      parallel backup wave across OSes). When omitted the skill asks.
    required: false
---

# cbt-scale-chaos — density backup + mid-flight chaos + fleet verification

## Phase 0 — Intake (FIRST, before anything else)

On invocation, silently check state on cloud05 (fleet exists? groups?
leftover objects in `vm-cbt-demo`?), then ask ONE `ask` form containing ONLY
the questions the user's request has not already answered. Never re-ask what
was stated; never run anything mutating before the form is answered.

| # | Question | Ask only if | Options / default |
|---|---|---|---|
| 1 | Fleet or throwaway? | not stated | **fleet mode (preferred, repeatable)** — persistent VM pool, per-run logical groups, ~zero setup cost per run / **throwaway mode** — per-run pool + full wipe (density-e2e.sh) |
| 2 | Fleet exists? (fleet mode) | no fleet in `artifacts/fleet.yaml` | build it: `--rhel N [--rhel-light K] [--windows M]` (expensive, once) — confirm sizing and RHEL variant |
| 3 | Group selection (fleet mode) | fleet mode chosen | **new slice**: OS (`rhel9`/`rhel9-light`/`windows`) + count (+ offset) / **retry group**: `<group-id>` all or only-failed / list recent groups if user unsure |
| 4 | Cleanup previous run? | leftover objects AND not fleet-scoped | fleet runs self-clean per group (reset); throwaway mode: wipe everything (default) / keep |
| 5 | Chaos? | not stated | **none** (default) / with chaos → **scenario ID** (from `cbt-chaos/scenarios_v2/`), **fire point** (e.g. at 50% fulls Done), **blast radius** (per-VM name-pattern vs fleet-wide). Rule 3 approval still happens before arming. |
| 6 | Defaults OK? | always (catch-all) | wave 25 (workload SSH parallelism; 50–100 for N≥500), backup SCs (all OSes→replica-1 cbt-scale-pool, test data only; durable ODF for Windows only on request), keep VMs after verify (default: leave). If RHEL: stock `rhel9` (80Gi, heavy) vs **`rhel9-light`** (~25Gi per VM) — recommend `rhel9-light` unless the scenario needs the large disk |

Run/group ids are auto-generated `<os>-<dd-mm-yyyy-HH-MM-SS>` (UTC) so runs
are easy to identify by timestamp. Group state lives in
`artifacts/groups/<group-id>.yaml` (per-VM: state, backup names, result);
the fleet registry is `artifacts/fleet.yaml`.

Not asked (fixed defaults, never prompt): light incremental profile only,
storage snapshots always taken, ROOT disks on durable 3-copy ODF unless the
user explicitly asks for replica-1 roots (`ROOT_SC=cbt-scale-pool`).

After the form: run the ONE deterministic command from Phase 1 (fleet or
throwaway mode), then continue with Phase 2/3.

## Overview

**Where the code lives:** tooling is the tracked `cbt-scale/` folder at the
repo root; runtime state and evidence (`artifacts/fleet.yaml`,
`artifacts/groups/`, `artifacts/density-scale-<pool>/`) stay in gitignored
`artifacts/` (override with `SCALE_STATE_DIR`).

Three phases, one run: **scale → chaos (optional) → verify**. The parallel
driver is the backup executor; `cbt-chaos-simple` is the chaos sub-skill;
Prometheus is the fleet health oracle.

## Execution environment (fixed — same as cbt-chaos-simple)

- Everything runs on `ssh cloud05`; checkout `/root/v2/virt-cbt-lab`;
  `export KUBECONFIG=/root/mno/kubeconfig`.
- Required on cloud05: `oc`, `jq`, `kube-burner` (bundled via repo), `make`.
- `cbt-scale/density-e2e.sh` — **PREFERRED entry point**: deterministic
    end-to-end wrapper. Single-OS: `--os rhel9|rhel9-light|windows --count N`
    (`rhel9-light` = right-sized RHEL 9, pools `rhl-<ts>`, driver backup PVCs
    12Gi full / 2Gi incremental). Mixed
    fleet (both pools created concurrently, all fulls/incrementals in one
    parallel wave across both OSes): `--mixed rhel9=N,windows=M [--wave 25]
    [--pool <prefix>]` (dispatches to `cbt-scale/density-e2e-mixed.sh`;
    RHEL and Windows backups → cbt-scale-pool by default; **`rhel9-light`
    is not supported in `--mixed` — use fleet mode with `--windows-count`
    for a light+Windows wave**). Both modes
    preflight the backup StorageClass, do cleanup (finalizer force-unstick +
    PV purge), pool creation, storage snapshots, driver phases A–D,
    live-cluster validation (Done reasons + tracker checkpoints, immune to
    the windows driver-log artifact), and write `summary.json`. Consume the
    verdict from `summary.json` (rule 6). Light incremental profile only.
    Run as:
    `KUBECONFIG=/root/mno/kubeconfig cbt-scale/density-e2e.sh --os <os> --count N`
    or `... --mixed rhel9=N,windows=M`. Gates (cleanup + OS profile) are
    still asked BEFORE invoking; the script refuses `--keep` when objects
    exist.
  - `cbt-scale/fleet-e2e.sh` — **FLEET MODE entry point (preferred for
    repeat runs)**: persistent fleet + per-run logical groups.
    - Build once: `fleet-e2e.sh fleet-setup --rhel N [--rhel-light K]
      [--windows M]` (pools `fleet-rhel`/`fleet-rhl`/`fleet-win`; refuses if
      fleet already exists). `--rhel-light` needs the golden DataSource from
      `make rhel-light-golden` (run once on cloud05; idempotent). Grow later
      with `fleet-extend` (same flags).
      Optional `ROOT_SC=<sc>` in the environment (e.g. `cbt-scale-pool`) puts
      ROOT disks on the replica-1 pool too — fully 1-copy fleet, test data
      only; cross-pool clone from both golden DataSources verified
      2026-11-19. Default keeps roots on durable 3-copy ODF.
    - Run: `fleet-e2e.sh run --os rhel9|rhel9-light|windows --count N
      [--offset M] [--windows-count M2] [--wave 25]` — creates group
      `artifacts/groups/<os>-<dd-mm-yyyy-HH-MM-SS>.yaml`, resets the group's
      backup objects (vmbackups/trackers/backup PVCs+PVs — VMs and roots are
      NEVER touched), runs full+incremental backups for just the group,
      validates from live cluster state, writes per-VM results + summary.
      The `rhel9-light` family is driven with 12Gi full / 2Gi incremental
      backup PVCs (`RHEL_LIGHT_FULL_BACKUP_SIZE` /
      `RHEL_LIGHT_INCREMENTAL_PVC_SIZE` override); per-OS driver logs and
      evidence land in `artifacts/groups/<group-id>/{rhel,rhl,win}/`.
    - Retry: `fleet-e2e.sh run --retry <group-id> [--only-failed]`.
    - Manual reset: `fleet-e2e.sh reset <group-id>`.
    Saves the full VM-provisioning cost on every run after the fleet build;
    per-run wall ≈ backup walls + ~2min group reset.
  - `cbt-scale/density-scale-test.sh` — manual entry: asks cleanup + OS profile
    (`rhel9|windows` only — no `rhel9-light`; use density-e2e.sh/fleet-e2e.sh
    for that), creates the pool, drives the phases, snapshots storage.
    Supports `--keep`, `--skip-setup --pool <id>`, `--backup-sc <sc>`,
    `--wave <n>`.
  - `cbt-scale/ns-wipe.sh` — **deterministic namespace wipe** for the cleanup
    gate (rule 1). `KUBECONFIG=... cbt-scale/ns-wipe.sh --yes
    [--namespace vm-cbt-demo]`: snapshots counts, deletes all workflow-managed
    objects (vmbackups/trackers/VMs/PVCs/Services) with `--wait=false`, polls
    drain, force-strips stuck finalizers after a 15-min grace, purges
    namespace-scoped Released/Available PVs until zero, exits nonzero if PVs
    remain. NEVER use it for fleet group reset (that is fleet-e2e's
    group-scoped reset); it exists for pre-fleet-build wipes and throwaway
    cleanup. Refuses without `--yes`.
  - `cbt-scale/scale-pool-gc.sh` — **orphan RBD image GC** for the replica-1
    backup pool. `KUBECONFIG=... cbt-scale/scale-pool-gc.sh [--pool P]
    [--delete] [--jobs 8]`: lists images with no referencing PV (report
    only by default); `--delete` removes them + CSI omap keys and re-verifies.
    Called automatically by fleet-e2e/density-e2e/ns-wipe (see Known traps).
  - `cbt-scale/fleet-verify.sh` — **deterministic Phase-3 verification + report**
    for a fleet group. `KUBECONFIG=... cbt-scale/fleet-verify.sh <group-id>
    [start-UTC end-UTC]`: cross-checks the group verdict against live cluster
    state (per-vmbackup full+incremental Done reasons, tracker
    latestCheckpoint per VM) writing `verify.tsv`, runs the Prometheus sweep
    when a window is given, and writes
    `artifacts/groups/<group-id>/run-report.md`. Exit 0 = all pass.
  - `cbt-scale/prom-sweep.sh` — **deterministic Layer-2 Prometheus sweep**.
    `KUBECONFIG=... cbt-scale/prom-sweep.sh <start-UTC> <end-UTC> [report.md]`:
    queries thanos-querier (token via `oc create token prometheus-k8s`,
    route cert not in cloud05 CA bundles → curl `--insecure` is expected)
    for ceph health vs pre-window baseline, ceph utilization, OSD read
    latency, CNV restarts delta, apiserver errors, node memory; prints a
    concern→observed→verdict table, optionally appends it as markdown, exits
    nonzero on FAIL. ceph WARN that already existed pre-window is reported
    `PASS (pre-existing)`, not a run finding.

## Non-negotiable rules

1. **Cleanup gate**: before creating a new pool, ALWAYS ask whether to wipe the
   previous run's VMs/backups/trackers/PVCs (destructive confirm). Never wipe
   unprompted; never delete golden images or infra namespaces.
2. **OS profile gate**: if `rhel9`/`rhel9-light`/`windows` was not provided,
   ALWAYS ask.
   rhel9 = large-odf profile (80Gi root / 90Gi full / 30Gi incr).
   **rhel9-light = right-sized RHEL 9** (same guest; 10Gi root / 12Gi full /
   2Gi incr ≈ 25Gi per VM, measured: the guest image is a 10GiB virtual
   disk so 10Gi is the floor and a full backup writes the whole disk).
   Prerequisite: the `rhel9-light` DataSource (`make rhel-light-golden`, once,
   idempotent). Check first: `oc get datasource rhel9-light -n vm-cbt-images`;
   if missing, run `make rhel-light-golden` (confirm with the user — it
   creates a 10Gi PVC and an image import). The scale driver writes its own
   small workload (8 files × 4–12 MiB; `.env` `GUEST_*` values do not apply),
   which fits the 10Gi root.
   windows = windows-odf profile (60Gi Block root / 70Gi full / 30Gi incr,
   OOBE ~20–25 min, GUEST_EXEC_POLL_ATTEMPTS=450). Windows backups now
   default to the replica-1 `cbt-scale-pool` too (test data only, user
   decision 2026-11-18); set `WIN_SC=ocs-storagecluster-ceph-rbd` (fleet-e2e /
   `--mixed`) or `--backup-sc` (single-OS) for durable 3-copy backups.
3. **Chaos gate** (from cbt-chaos-simple): never arm or fire an injection
   before the user approves the exact command, target, and blast radius.
4. One driver instance per pool; never run two mutating drivers concurrently.
5. Backups on the replica-1 `cbt-scale-pool` (default) have zero durability —
   acceptable for scale testing only; never point durable workloads there.
6. Report honestly: pass/fail comes from per-vmbackup Done reasons + tracker
   checkpoints (the pipeline's own semantics), never from exit codes alone.

## Phase 1 — Scale (setup + backups)

**Default path — use the deterministic scripts** (do NOT reinvent commands
when a script covers the scenario):

1. Resolve mode (fleet vs throwaway), group/N, OS profile, wave size.
2. Gates (rules 1–2 + Phase 0 intake) — ask BEFORE invoking.
3. Run ONE command on cloud05 (`cd /root/v2/virt-cbt-lab`):
   - **fleet mode (preferred for repeat runs)**:
     - once, expensive: `KUBECONFIG=/root/mno/kubeconfig
       cbt-scale/fleet-e2e.sh fleet-setup --rhel N [--rhel-light K] [--windows M]`
     - per run, cheap: `KUBECONFIG=/root/mno/kubeconfig
       cbt-scale/fleet-e2e.sh run --os rhel9|rhel9-light|windows --count N [--offset M]
       [--windows-count M2] [--wave 25]` — group id auto
       `<os>-<dd-mm-yyyy-HH-MM-SS>`; resets the group's backups only,
       VMs/roots untouched
     - retry: `... run --retry <group-id> [--only-failed]`
   - **throwaway mode**:
     - single OS: `... density-e2e.sh --os <rhel9|rhel9-light|windows> --count N
       [--wave 25] [--backup-sc <sc>]`
     - mixed: `... density-e2e.sh --mixed rhel9=<N>,windows=<M> [--wave 25]
       [--pool <prefix>]`
   All modes preflight StorageClasses, snapshot storage, run driver phases
   A–D, validate from live cluster state, and write a summary (fleet:
   `artifacts/groups/<group-id>.yaml` + `.summary`; throwaway:
   `artifacts/density-scale-<pool>/summary.json`). Consume the verdict from
   the summary (rule 6), not driver stdout.
4. Layer 1 validation is done by the script; proceed to Phase 2 (chaos,
   optional) or Phase 3 (Prometheus sweep + report).

**Manual path** (only when deviating from the validated procedure):

1. Resolve N, OS profile, pool id, backup SC, wave size (defaults: 25).
2. Cleanup gate (rule 1). Cleanup procedure: delete vmbackup, vmbackuptracker,
   vm, pvc, svc in `vm-cbt-demo`, wait for namespace drain, then purge
   Released/Available PVs until zero so storage returns to baseline.
3. Create the pool: `make density-setup VM_OS=<rhel9|rhel9-light|windows>
   MANIFEST_VARIANT=large-odf
   DENSITY_VM_COUNT=N DENSITY_INCREMENTAL_PASSES=1 DENSITY_QPS=50 POOL=<id>`;
   wait for N/N ready. Snapshot storage (post-setup).
4. Run `cbt-scale/scale-driver2.sh <pool> 1 <N> <wave>` (for rhel9-light set
   `FULL_DEST_SIZE=12Gi INCR_DEST_SIZE=2Gi` in the environment — the driver
   defaults to 90Gi/30Gi): phase A baseline
   workload (SSH waves) → phase B ALL full backups at once → phase C
   incremental workload → phase D ALL incremental backups at once.
   Wall-time expectations measured on this cluster: 50 VMs ≈ 191–220s full /
   39–40s incr; 100 ≈ 321s / 110s; 200 ≈ 553s / 190s (linear-ish scaling,
   ~40–47 GiB/s aggregate on the 256-PG scale pool). Windows driver logs
   report `pass=0` (workload step fails: no vm-ssh Service on windows pools)
   — judge windows runs from cluster state/summary.json, not driver tally.

## Phase 2 — Chaos window (optional; delegate to cbt-chaos-simple)

The chaos opportunity is exactly the user's stated goal: **while VMs are
provisioned and full or incremental backups are copying, an injection can be
landed mid-flight.**

- The driver's phase-B and phase-D windows are the injection windows. Fire
  triggers when `scale-status.sh` shows the family progressing (>0 in-flight)
  — or gate on a specific count (e.g. fire when 50% Done) for reproducibility.
- For the injection itself, LOAD the `cbt-chaos-simple` skill and follow it:
  read the scenario under `cbt-chaos/scenarios_v2/<ID>/`, derive the krknctl
  command via `krkn-scenario`, use tested trigger-library conditions, get
  explicit user approval for the exact command/blast radius, precheck, arm
  before the phase starts, and verify from the driver's own validation.
- Blast-radius notes at scale: an injection aimed at "the backup" is now aimed
  at N backups — prefer per-VM targeted faults (name-pattern, not labels that
  select the whole fleet) unless fleet-wide stress is the point. Pods to know:
  `hp-volume-*` (attachment), `virt-launcher-vm-<rid>-*` (per-VM),
  virt-controller leader (Lease holder), OSDs.
- Record: injection fired-at (timestamp), how many backups were in-flight,
  which VMs were in the blast radius, injector exit code and log path.

## Phase 3 — Verify (fleet + Prometheus)

Verification has two layers; run both.

**Layer 1 — object-level fleet validation**: the driver/wrapper does this,
but ALWAYS cross-check with the deterministic script (log writes can race
driver exit):

```sh
KUBECONFIG=/root/mno/kubeconfig cbt-scale/fleet-verify.sh <group-id>
```

It counts per-vmbackup full+incremental Done reasons and tracker
latestCheckpoint per VM directly from live cluster state (`verify.tsv`),
writes `artifacts/groups/<group-id>/run-report.md`, exits 0 only when all
VMs pass. Expected per full backup: ~78GiB written for `rhel9` (the whole
80Gi virtual disk) vs **~10GiB for `rhel9-light`**; light-profile
incrementals ~45MiB/VM (check `storage-snapshot.sh` rows). Measured
`rhel9-light` fleet run (3 VMs, 2026-11-19): full wall 272s, incr 91s, per-VM
PVCs 11Gi root / 12Gi full / 2Gi incr.

**Layer 2 — Prometheus health sweep**: run the deterministic script over the
run window (wrapper log lines `RUN: driving group ...` → `DONE group=...`
give the timestamps):

```sh
KUBECONFIG=/root/mno/kubeconfig cbt-scale/prom-sweep.sh <start-UTC> <end-UTC>
# or let fleet-verify.sh run it and append the table into run-report.md:
KUBECONFIG=/root/mno/kubeconfig cbt-scale/fleet-verify.sh <group-id> <start-UTC> <end-UTC>
```

Checks (concern → PromQL): ceph health (`ceph_health_status` vs pre-window
baseline), pool full pressure
(`sum(ceph_osd_stat_bytes_used)/sum(ceph_osd_stat_bytes)`), OSD read latency
(latency_sum/latency_count peak), CNV restarts delta
(`kube_pod_container_status_restarts_total{namespace="openshift-cnv"}`),
apiserver errors
(`rate(haproxy_backend_http_responses_errors_total{backend="kube-apiserver"}[5m])`),
node pressure (`min(node_memory_MemAvailable_bytes)`).

Report any spike with: metric, window, magnitude vs baseline, and the
corresponding object-level evidence (which VMs/backups were affected). Layer 1
and Layer 2 must agree — if Prometheus shows an error spike but all backups
passed, call it out as a resilience finding, not silence it.

## Report

**Generated, not hand-written**: `fleet-verify.sh <group-id> [start end]`
writes `artifacts/groups/<group-id>/run-report.md` (fleet mode; throwaway
mode keeps `summary.json` from density-e2e.sh). The agent's job is only to:
- pass the correct run window (from the wrapper log) so the Prometheus table
  lands in the report,
- add anything the script cannot know: run parameters context, chaos
  scenario id / injection window / blast radius (if any), and an attempt
  history table when re-running after failures,
- present the verdict with the evidence files: `verify.tsv`,
  `prom-sweep.log`, driver `summary.txt`/logs, group `.yaml`/`.summary`,
  storage snapshot rows.

## Known traps (from live runs on this cluster)

- **`VM_OS=... make density-setup` is silently ignored — pass it as a make
  ARGUMENT.** The repo `.env` sets `VM_OS=rhel9`, and make lets variables
  from `.env` override the environment, so `VM_OS=rhel9-light POOL=x make
  density-setup` built stock `rhel9` VMs (80Gi/85Gi roots, stock DataSource)
  and every 12Gi backup then failed `No space left on device` (2026-11-19,
  group `rhel9-light-19-11-2026-10-57-52`, 0/3). The deployed
  `fleet-e2e.sh`, `density-e2e.sh` and `density-e2e-mixed.sh` now all use
  `make density-setup VM_OS=... POOL=...`. After any pool build,
  confirm the roots: `oc get pvc -n vm-cbt-demo | grep vm-disk` should show
  ~11Gi for `rhel9-light`, ~85Gi for `rhel9`.
- **`rhel9-light` golden is a prerequisite and is backend-specific.**
  `make rhel-light-golden` builds the DataSource on the storage class that
  matches `MANIFEST_VARIANT` (RBD for `large-odf`); cloning it to a 10Gi root
  works (the 10Gi request is granted as 11Gi). A missing DataSource fails
  preflight with "run make rhel-light-golden". Do NOT clone the stock
  `rhel9` golden to a small root — a clone cannot be smaller than its
  source PVC (~32Gi).
- **GC warning after a wipe is not a run failure.** `scale-pool-gc.sh` may
  print `deleted=0 failed=N` for images that still have watchers (an
  attached/mapped volume on some node); it leaves them and the run
  continues. Investigate only if the count grows.
- **The registry can be stale after a manual wipe.** `artifacts/fleet.yaml`
  is regenerated by `fleet-setup`, which refuses only when VMs exist in the
  pools; `fleet-extend` dies on registry/cluster drift. Check
  `oc get vm -n vm-cbt-demo -l virt-cbt-lab/pool=...` against the registry
  after any cleanup outside fleet-e2e.
- **Backup StorageClass can vanish when the ceph pool is recreated**. The
  `cbt-scale-pool` SC was deleted when its CephBlockPool was recreated
  (2026-11-18): backups stalled ~25min in `Initializing — PVC being attached
  to VMI` with `hp-volume-*` pods Pending and only PVC
  `ProvisioningFailed: storageclass not found` events. The live pool's
  companion SC is `ocs-storagecluster-ceph-rbd-scale` (same
  `pool=cbt-scale-pool`); fix by recreating the `cbt-scale-pool` SC as an
  alias (see the fix hint printed by `density-e2e.sh` preflight). Stalled
  PVCs recover automatically once the SC exists. `density-e2e.sh` preflights
  SC existence and fails fast instead of stalling.
- **Orphan RBD images in `cbt-scale-pool`** (found 2026-11-18: 585 images /
  ~22 TiB written, no PV/PVC behind them, from a wipe that force-stripped PV
  finalizers). They eat raw capacity and are invisible to Kubernetes.
  `cbt-scale/scale-pool-gc.sh` detects them (image with no PV referencing
  its `imageName`; VM roots live in `ocs-storagecluster-cephblockpool` and
  are never in scope) and `--delete` removes them plus their CSI omap
  entries. It runs automatically in `fleet-e2e.sh run` (after group reset),
  `density-e2e.sh` (single + mixed, after cleanup) and `ns-wipe.sh`. **Rule:
  whenever any deterministic script reports `GC: ... orphans=N` with N>0,
  let it delete them (it refuses while a PVC is Pending); if it fails or
  orphans remain, run `scale-pool-gc.sh` manually and report the count/GiB
  reclaimed. Never `rbd rm` by hand or touch images a PV references.**
  Report-only: `KUBECONFIG=... cbt-scale/scale-pool-gc.sh`.
- **ODF capacity layout (2026-11-18)**: 28 workers carry 83 OSDs (3 disks
  each, 162 TiB raw); control-plane node `d38-h09-000-r660` was added with
  3 OSDs (+5.8 TiB) via a second storageDeviceSet
  `ocs-deviceset-controlplane` (master toleration; rack2 label; its
  prepare/OSD placement uses hostname spread only because the default
  rack-spread `DoNotSchedule` leaves prepare pods Pending). Control-plane
  `d38-h07`/`d38-h08` have identical blank disks but **no egress to
  registry.redhat.io/quay.io** (curl times out; h09 and workers are fine), so
  diskmaker/OSD images cannot be pulled there — they are NOT ODF-labelled
  (label them only after egress or an image mirror is fixed). `d38-h18`
  `/dev/sdb` serves the `cbt-demo-hpp` pool; leave it.
- vmbackup deletion is a 4-hop finalizer chain (VMI hotplug status →
  volumeattachment → PV external-attacher → RBD image). If deletion stalls
  with no error events, check virt-handler logs for cert errors and
  launcher-socket SyncVMI timeouts; the reliable unblock for stale VMI hotplug
  status is deleting the affected virt-launcher pods (guest hard reboot).
- Storage-full events can break virt-handler cert rotation cluster-wide —
  after any full event, expect SyncVMI storms until handlers restart.
- Per-VM `oc wait` does not scale to hundreds of backups — always the
  poll-based `wait_family` approach (scale-driver2.sh), never oc-wait storms.
- `--force` VM deletion skips graceful shutdown; use the normal delete first
  and force only for stuck objects.
- **Fleet group mode is fixed as of 2026-11-18** — before that,
  `fleet-e2e.sh run` crashed on empty grep under `set -euo pipefail` and
  `scale-driver2.sh` had no group mode (hardcoded `<pool>-NNNN` names), so
  every group run failed with 0/10. The deployed versions use
  GROUP_FILE/GROUP_ID; if a group run suddenly reports all-missing backups,
  check for a stale checkout on cloud05 missing these fixes. The fixes
  ship in the tracked `cbt-scale/` folder of the checkout.
- **Thanos route TLS**: the thanos-querier route cert is not in cloud05's CA
  bundles — `curl --insecure` (as `prom-sweep.sh` does) is expected; token
  auth still enforces identity. PromQL `@` modifiers must attach to the
  selector (`metric{...} @ <ts>`), not the aggregation.
