# CBT-F-08: Run out of space on the full backup destination

**Jira issue:** CBT-F-08 — Run out of space on the full backup destination
**Priority:** P1
**Technical scenario:** `pvc-scenarios`
**Chaos phase:** Operation start

## 1. Jira objective and hypothesis

The issue asks whether the full-backup pipeline fails safely when the destination PVC runs out of
capacity mid-copy. Fill the full-backup destination PVC to approximately 95% capacity while the full
backup is progressing and the destination is bound, and confirm the backup terminates as a clean
failure (not a false `Done=True`), the VM stays running, and the tracker does not advance.

**Issue fields:** Workflow: Full backup. Target: full backup destination PVC. Action: fill to ~95%
capacity. Timing: after the destination is bound and the backup has started, before the copy
completes. Signal: backup is progressing and destination PVC is bound. Duration: 120 seconds.
Expected behavior: insufficient-space conditions cause a clean terminal failure; VM stays running;
tracker does not advance. Recovery: remove the filler or start a fresh run with a new destination
PVC. Verification: failure reason, unchanged tracker, invalid partial image, and a fresh backup
succeeding. Expected outcome: confirms safe handling of destination capacity exhaustion and prevents
false-success backups.

## 2. Evidence and live target resolution (conflict found and resolved)

**Key conflict — destination PVC size vs. the standard profile:** the active checkout's default
`MANIFEST_VARIANT=large-odf`, and `scripts/common.sh`'s `set_manifest_variant_settings()` (lines
104–119), resolve **every** `VM_OS=rhel9` full-backup PVC to **80Gi** regardless of
`default`/`large`/`odf`/`large-odf` (`rhel9:*) LARGE_MANIFEST_DISK_SIZE=80Gi`; confirmed live —
`vm-cbt-demo` currently holds many `ocs-storagecluster-ceph-rbd`-backed PVCs at 80Gi/85Gi). Filling an
80Gi PVC to 95% within the issue's 120-second chaos duration is not practical. The small Debian
profiles are the only ones with a full-backup PVC small enough to make a 95%-capacity fill
achievable in that window: `manifests/full-backup.yaml` (`VM_OS=debian`, `MANIFEST_VARIANT=default`,
`cbt-demo-hpp`, 5Gi) and `manifests/full-backup-odf.yaml` (`VM_OS=debian`, `MANIFEST_VARIANT=odf`,
`ocs-storagecluster-ceph-rbd`, 6Gi) — confirmed in `scripts/common.sh:99-104` and the manifest files
directly. This trigger pins `VM_OS=debian MANIFEST_VARIANT=odf` and refuses `rhel9` or the
`large`/`large-odf` variants, which would reintroduce the 80Gi (or 40Gi/48Gi) destination. `odf` is
chosen over the HPP `default` variant because ODF/Ceph RBD enforces PVC capacity strictly
(`.env.example:54`: "ODF enforces PVC capacity"), which is the exact out-of-space behavior this issue
needs — HPP's thin/page-cache-backed filesystem is a weaker guarantee that the destination write
actually hits ENOSPC at the PVC boundary.

**Krkn's PVC-fill mechanism (resolved from source, not guessed):** read
`krkn/scenario_plugins/pvc/pvc_scenario_plugin.py` on `cloud05`'s installed krknctl image layer.
When only `--pvc-name` is given (no `--pod-name`), the plugin calls `get_pvc_info()` and picks one of
the PVC's **existing mounting pods** (`pvc.podNames`), then `exec`s into that pod's container to `df`
the mount, compute the exact byte count needed to reach `--fill-percentage` of total capacity from
the *currently used* bytes, and writes a single temp file (`kraken.tmp`) of that size inside the
already-running pod. It does **not** schedule a new pod. This matters because the full-backup
destination PVC is `ReadWriteOnce` (`manifests/full-backup-odf.yaml`); a separately scheduled filler
pod could hit a cross-node multi-attach conflict with the existing hotplug attachment pod, but since
`pvc-scenarios` execs into that same attachment pod instead of creating one, there is no
scheduling/node-affinity risk to design around.

**Live namespace evidence:** the `vm-cbt-demo` namespace currently holds many prior-run
resources (`vm-20261010-cbt-f-01*`, `vm-20261011-*`, `vm-20261012-cbtf06-*`, etc.) and the
`cbt-demo-hpp` / `ocs-storagecluster-ceph-rbd` storage classes (`WaitForFirstConsumer` /
`Immediate` binding, respectively — confirmed live via `oc get sc`). The trigger uses a fresh,
unique `RUN_ID` and refuses to start if any existing resource name already contains it, consistent
with CBT-F-06/CBT-F-02.

The destination PVC and `VirtualMachineBackup` names are deterministic from `RUN_ID`
(`scripts/run-id.sh`): `vm-backup-pvc-${RUN_ID}` and `vm-backup-${RUN_ID}`.

## 3. Workflow and prerequisites

`scripts/e2e-stage.sh` (invoked by `make e2e`) supports `TYPE=full`, `TYPE=incremental`,
`TYPE=recover`, `TYPE=extend`, and `TYPE=verify` on the currently checked-out Makefile. This is a
**Full backup** issue, so the trigger uses:

```sh
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS=debian MANIFEST_VARIANT=odf \
  NAMESPACE=vm-cbt-demo \
  GUEST_BASE_FILE_COUNT=24 GUEST_FILE_SIZE_MIN_MIB=48 GUEST_FILE_SIZE_MAX_MIB=96 \
  GUEST_INCREMENTAL_FILE_COUNT=4 GUEST_INCREMENTAL_PASSES=1 \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

`TYPE=full` creates a fresh managed VM/workload and takes one full backup. The guest payload
(24 files, 48–96 MiB each, ~1.1–2.3GiB total) is deliberately larger than the repository's small
default (8 files, 4–12MiB) so there is bytes-on-the-wire for the destination write to still be in
flight when the filler lands, while staying well under the 6Gi destination PVC so Krkn's live
`df`-based sizing still has free space to compute a 95% target from. **This sizing is a starting
point, not a measured guarantee** — on fast/page-cache-absorbed backends a small payload can finish
copying before the filler executes (the same effect AGENTS.md documents for `cbt-demo-hpp`); confirm
the actual copy-vs-fill race with `scripts/monitor.sh "$VM_NAME"` and the observer timeline during the
live run, and raise `GUEST_BASE_FILE_COUNT`/`GUEST_FILE_SIZE_MAX_MIB` (keeping total payload visibly
below 6Gi) if the backup reaches `Done=True` before the fill lands.

## 4. Target and validated disruption

**Primary (krknctl, native trigger):**

```sh
krknctl run pvc-scenarios \
  --namespace vm-cbt-demo \
  --pvc-name "vm-backup-pvc-${RUN_ID}" \
  --fill-percentage 95 \
  --duration 120 \
  --trigger-command '<compound trigger — see below>' \
  --trigger-expected-rc 0 \
  --triggers-interval 3 \
  --triggers-timeout 1800 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH"
```

Validated with `krknctl run pvc-scenarios --dry-run` against the exact flags and compound trigger
command below on `cloud05` on 2026-10-12 (`✔ Scenario schema valid`, `✔ All required fields present`,
`✔ Values validated`). `krknctl describe pvc-scenarios` / `krknctl run pvc-scenarios --help` confirm
`--pvc-name`, `--fill-percentage` (default 50), `--duration` (default 60), and the `TRIGGERS`
flag group (including `--trigger-command`/`--trigger-k8s-*`) are real, supported flags on this
krknctl build.

No `oc`/`kubectl` fallback is needed: `pvc-scenarios` performs the fill directly and its native
`--trigger-command` can express the issue's exact signal.

## 5. Deterministic injection signal

The issue's literal signal is "backup is progressing and destination PVC is bound." A single
`--trigger-k8s-*` condition cannot express both clauses, so `chaos-trigger.sh` builds one compound
shell command for `--trigger-command` (evaluated inside the krkn container, `oc` available there),
combining the PVC-bound check with the launcher-log-based live-copy signal from
`docs/cbt/08-operations.md`/`docs/cbt/10-chaos-test-design.md` (CR creation includes PVC binding,
not the start of the QEMU block-copy; the launcher's `Backup started` log line is the live-copy
boundary — the same boundary CBT-F-02's `virsh backup-dumpxml` poll and the v1
`02-backup-destination-pvc-fill` scenario target):

```sh
test "$(oc get pvc vm-backup-pvc-${RUN_ID} -n vm-cbt-demo -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound \
  && pod=$(oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-${RUN_ID} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
  && test -n "$pod" \
  && test "$(oc get vmbackup vm-backup-${RUN_ID} -n vm-cbt-demo -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True \
  && oc logs -n vm-cbt-demo "$pod" -c compute --tail=2000 2>/dev/null | grep -F -- vm-backup-${RUN_ID} | grep -F -- 'Backup started'
```

This is true only once the destination PVC has reached `Bound` **and** the launcher log shows the
backup actively copying (`Done` not yet `True`). `krknctl` polls this every 3 seconds (`--triggers-interval 3`)
with `--triggers-timeout 1800` and `--triggers-on-timeout fail`, so a missed window fails loudly
instead of silently skipping. `chaos-trigger.sh` starts this `krknctl run` in the background before
`make e2e TYPE=full`, per the triage timing rule, so krknctl's own startup/image-pull latency is
absorbed before the condition can become true.

**Chaos duration:** `--duration 120` matches the issue's stated 120-second chaos duration; Krkn holds
the filler file in place for that long before removing it (recovery = "remove the filler," per the
issue's own recovery field).

No arbitrary sleep substitutes for this signal anywhere in the trigger.

## 6. Pass/fail criteria

A product **pass** requires all applicable checks below:

- The destination PVC `vm-backup-pvc-${RUN_ID}` reaches `Bound` and the launcher log confirms
  `Backup started` before the filler executes (confirm from the krknctl log and the observer
  timeline, not assumed).
- The full `VirtualMachineBackup` reaches a settled terminal state with `Done=True` and a reason that
  clearly indicates insufficient-space/failure — never a false `Done=True` success over a
  truncated/partial destination.
- `vm-tracker-${RUN_ID}`'s `latestCheckpoint` remains unchanged/empty after the failed attempt; the
  failed backup's checkpoint is never accepted as a valid tracker checkpoint.
- The destination PVC/backup artifact is inspected and confirmed not to be a valid, restorable image
  (e.g., `qemu-img info`/`qemu-img map` on the destination artifact, or the backup object's own
  failure condition, whichever the implementation exposes).
- The VM/VMI remain `Running`/`Ready` with CBT `Enabled` throughout — this scenario never touches
  `virt-launcher`/`virt-handler`/`virt-controller`, so no VM-side recovery step is expected.
- Krkn removes the filler file at the end of `--duration` (or the trigger script removes it/waits for
  Krkn's own cleanup) so free space is restored before the follow-up backup.

**Post-chaos same-VM backup verification (required, per the issue's own "fresh backup succeeds" check):**

- Run `make e2e TYPE=recover VM="vm-${RUN_ID}"`, which creates a distinct
  `vm-recovery-full-${RUN_ID}-rNNN`/`vm-recovery-pvc-${RUN_ID}-rNNN` through the existing tracker and
  verifies a baseline restore, without reusing or deleting the original failed backup/PVC.
- Preserve the original (partial) destination PVC/backup object; never retry by reusing a failed
  backup/destination name.

**Evidence commands:**

```sh
oc get pvc "vm-backup-pvc-${RUN_ID}" -n vm-cbt-demo -o yaml
oc get vmbackup "vm-backup-${RUN_ID}" -n vm-cbt-demo -o yaml
oc get vmbackuptracker "vm-tracker-${RUN_ID}" -n vm-cbt-demo -o yaml
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp
oc get vm "vm-${RUN_ID}" -n vm-cbt-demo -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
```

A product **fail** includes a false successful backup over a truncated/partial destination,
tracker/checkpoint advancement from a failed or incomplete copy, an indefinite `Progressing` hang
with no bound retry, an unclear failure reason, or a blocked/incorrect same-VM follow-up.

## 7. Blast radius, recovery, and conflicts

Only the single run-scoped full-backup destination PVC (`vm-backup-pvc-${RUN_ID}`) is targeted; Krkn
execs into its existing mounting pod rather than creating a new one, so no other PVC, pod, or node is
touched. The filler is removed automatically after `--duration` (or by the recovery step); no manual
CSI/controller restart is needed. The trigger refuses to start if its chosen `RUN_ID` already has
local or cluster-side resources. Never run `make clean-all`; preserve failed backup/PVC objects for
inspection.

Unresolved/uncertain: the exact guest-payload sizing in §3 is a starting point pending live
measurement — if the full backup completes before the compound trigger's launcher-log condition and
the subsequent fill land inside the live-copy window, the run must be treated as INVALID (chaos
missed the window), not a pass, and the payload size should be increased and re-run. This must be
confirmed via `scripts/monitor.sh "$VM_NAME"` and the krknctl/observer timeline on every run, not
assumed from this design.
