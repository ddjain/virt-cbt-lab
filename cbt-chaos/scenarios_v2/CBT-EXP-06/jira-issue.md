# Improvement: Verify that losing one disk's checkpoint bitmap cannot silently remove backup coverage

> **Scenario-derived engineering issue; unfiled; no Jira key.** Provenance: `scenario-spec.md`, including human clarifications `cbt-exp06-control-20261016T185816Z` and `cbt-exp06-sizing-20261016T190300Z`, both relayed with answer timestamp `2026-10-17T00:00:00Z`. Structure follows `cbt-chaos/template/engineering-jira-issue-template.md`. This issue specifies an experiment; it does not import historical verdicts or assert a current product defect. No lifecycle or fault has been executed for this prepared bundle.

## What this is, in one paragraph

Changed-block tracking (CBT) uses a dirty bitmap (a per-disk map of changed blocks inside QEMU) and a checkpoint (the named disk set used as the basis of an incremental backup). Test whether losing only the data disk's full-backup bitmap, followed by one VM-instance restart, can silently exclude that disk from the next backup. A separate, undisrupted two-disk control must first complete full, incremental and root-data restore verification.

**When → then → expected**

- **When:** a fresh two-disk surgery VM has a successful Full backup covering `rootdisk` and `datadisk`, its tracker identifies that checkpoint, and no incremental exists yet.
- **And:** CBT-EXP-06 removes exactly the datadisk checkpoint bitmap via QMP `block-dirty-bitmap-remove` and restarts only that VMI once with an immutable UID precondition. This is not a krkn fault: inspected kubevirt-outage/container-scenarios metadata cannot perform that exact per-disk bitmap mutation/composite action.
- **Then (current behavior):** not recorded for this bundle. Silent disk exclusion is an unproven hypothesis from the scenario source.
- **Expected:** both disks remain protected, or the missing coverage is detected through the original scenario's explicit fallback/warning/failure alternatives; never a completed Incremental that silently omits datadisk.

## At a glance

| Field | Value |
|---|---|
| Issue type | Improvement / validation contract, not a demonstrated current Bug |
| Priority | Unassigned pending triage |
| Severity class | Data-protection coverage and status truthfulness (hypothesis) |
| Owning component | KubeVirt checkpoint/CBT backup path, suspected |
| Components proven involved | Not recorded for a new attempt; QEMU/libvirt and CBT APIs are the specified path |
| Reproducibility | Not recorded; this bundle is unexecuted |
| Status / confidence | Test intent established by scenario; product outcome/root cause unproven |
| Blast radius | Two fresh two-disk VMs; fault touches one datadisk bitmap and one surgery VMI only |
| Data at risk | Disposable run-owned data; no shared/source-image data mutation authorized |
| Related scenario/execution | CBT-EXP-06; no execution claimed by this issue |
| Affected versions | Not established; source's v1.8.4-era attribution is a hypothesis lead, not a measured affected-version verdict |

## Context

A `VirtualMachineBackupTracker` tracks the chain's latest checkpoint and volume set. A `VirtualMachineBackup` writes disks into a destination PVC (persistent volume claim). The running VMI (VirtualMachineInstance) and libvirt checkpoint XML provide different metadata surfaces; QMP queries provide the actual bitmap state. The experiment must compare these rather than treat a tracker volume list as proof that a bitmap exists. Backend errors may appear against the VMI rather than the backup, so warnings must be observed on both UID-scoped event streams.

## Environment (measured, not assumed)

| Layer | Contract / source | Attempt measurement |
|---|---|---|
| Platform / API / operators | KubeVirt CBT APIs installed; exact versions to capture at approved preflight | Not recorded for an attempt |
| Source image | RHEL9 DataSource; current preparation source disk30Gi, CDI overhead6%; 5Gi clone is not technically viable | Re-resolve source PVC/PV/CSI/geometry before setup |
| VM | Per fresh VM: 40Gi cloned root, 2Gi blank ext4 datadisk, one vCPU, 4Gi memory, CBT enabled | Not created |
| Destination | Existing RBD profile: full80Gi and incremental30Gi per VM | Not created |
| Workload | Root:8 baseline files,4 additions + one baseline modification,4–12MiB, one incremental | Not generated |
| Storage headroom | RBD pool≥400Gi MAX_AVAIL and actual approved worker kubelet filesystem free≥100Gi | Recheck before lifecycle |
| QEMU/libvirt/tools | Required QMP query/remove and checkpoint/guest read surfaces, resolved on execution host | Tool metadata is preparation evidence, not product acceptance |
| Harness | Hash all `bundle-files.txt` dependencies and effective parameters | No approved/executed bundle claimed here |

## Reproducibility

No new attempt or rate is claimed. Preconditions are two unused lifecycle identities, run-owned resources and an independent read-only witness that has actually saved the required QMP pre-state. A failed control or missing pre-state blocks surgery. Do not execute archived scripts or reuse their targets/evidence.

## Chaos Injection

Exact target chain: approved surgery VM name + live VM UID → its controller-owned running VMI UID → sole Ready launcher UID/compute container → libvirt domain → unique qcow2 format node whose filename ends `/cbt/datadisk.qcow2` → bitmap named by the successful Full checkpoint. Exclude rootdisk, storage-node siblings, the control VM and all unrelated resources.

## Injection Timing

After Full Done=True/success and both included disks, before creation of the first surgery incremental. No in-flight-copy predicate is required. Independent full raw QMP before-read and matching live UID/window revalidation are mandatory immediately before action; raw actor and separate-witness after-reads must prove the exact removal and root/sibling exclusions before the one restart.

## Steps to reproduce (exact commands and timing)

These are **unexecuted approved-bundle command shapes**, not evidence of a repro. Use only disposable, newly named resources and obtain whole-bundle approval first. The scenario-local manifest supplies the full two-disk VM/service definition; entrypoint renders fresh names and public key and reuses the supported Make stages.

**Step 1 — Prepare and prove the control.** On the approved execution host, inspect `run.sh --manifest` and `run.sh --plan` with distinct `CONTROL_LIFECYCLE_ID` and `LIFECYCLE_ID`; Lead separately allocates `CHAOS_RUN_ID` with `cbt-chaos/run-id.sh <exact-surgery-vm> bitmap-drop <iteration>`. Inspect `--parameters`, approve complete hashes/parameters, then Lead creates matching run.json and invokes:

```bash
bash cbt-chaos/scenarios_v2/CBT-EXP-06/run.sh --execute
```

The single entrypoint creates/adopts the fresh control, takes its full and incremental, checks both disks and runs normal root restore. Its exact internal stage sequence and fixed environment are specified in `scenario-spec.md`; Lead must not launch a duplicate stage.

**Step 2 — Fault only the surgery full checkpoint.** The entrypoint creates a distinct two-disk surgery VM, arms final collection and the separate witness before Full, then gates on raw presence. The product action shape is:

```bash
oc exec -n <ns> <uid-validated-launcher> -c compute -- \
  virsh qemu-monitor-command <domain> \
  '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"<datadisk-format-node>","name":"<full-checkpoint>"}}'
```

Require the named bitmap present before and absent after in complete `query-named-block-nodes` replies, with root/sibling names unchanged. The independent read-only process performs its own calls. A bare exit0/empty QMP success reply is not sufficient proof.

**Step 3 — Restart once and request the incremental.** The entrypoint uses Kubernetes DELETE body `{"apiVersion":"v1","kind":"DeleteOptions","gracePeriodSeconds":0,"preconditions":{"uid":"<original-VMI-UID>"}}` against that exact VMI API path through an owned local proxy, never an unguarded delete-by-name. It waits for a distinct replacement VMI/launcher owned by the original VM UID, then runs the incremental stage. Normal verification runs only if that stage succeeds. There is no retry/recovery/cleanup leg.

**Step 4 — Observe without repairing.** Preserve backup type/conditions/reasons/included volumes, tracker volumes, checkpoint XML, full QMP replies, UID-scoped backup and VMI events, component log window, guest actual workload reads and exact storage-ownership correlation. At the existing20-minute backup wait bound, a still-active request is `NONTERMINAL_AT_BOUND`, not proof of an infinite loop or a successful protected backup. Always-run collectors continue300s after termination/abort; time bounds are test windows, not product SLAs.

**Step 5 — Preserve.** No recovery or cleanup mutation is authorized. Keep failed backup objects/destinations and source VMs/disks for Lead's reporting and independent analysis. Stop only invocation-owned local processes.

## Current behavior (observed)

Not recorded for this prepared attempt. The original silent-drop objective remains unproven here. No historical result is substituted for current raw injection/product evidence.

## Expected Behavior / Pass-Fail Criteria

- Control full and incremental each successfully include `rootdisk` and `datadisk`; root restore matches exact baseline and cumulative file count/bytes/hash expectations.
- Fault and exclusions are proven from independently observable raw QMP/UID/action/window evidence.
- Defect signal: Done=True Incremental with datadisk missing and no warning on the approved warning surfaces.
- Resilient alternatives are the original source's both-disks coverage or detected drop (checkpoint clearing/full fallback, warning, terminal failure).
- Nonterminal-at-bound is recorded separately and cannot silently become PASS/RESILIENT. Missing mandatory evidence remains UNKNOWN for independent assessment.
- Root restore does not grade datadisk content or guest bootability; disclose that limitation. Do not add a data workload or claim both-disk content verification.
- Stock evaluator requiring recovery/clean legs is not applicable unchanged; no additional legs to satisfy it. Only the independent grading owner writes analysis.json.

## Impact, workaround and data safety

Potential impact is incomplete backup coverage concealed by completion/metadata. It is not a demonstrated current outcome. Source image and unrelated workloads are excluded. No workaround or remediation is verified or authorized; retained state is the observation, not permission to delete/repair it.

## Execution and Approval

Lead owns approval, creation of the matching fresh run root/run.json, execution, monitoring, state, reports and verified pull. Approval binds complete file hashes (including actual .env hash, never its contents), stage/action ownership, cluster/host/context, node name+UID, source PVC UID, read-only probe VM name+UID, restore-image digest, exact command/IDs, blast radius and observation scope/windows. Changed scope/files/parameters require fresh approval. The bundle author never approves or grades.

The complete approval includes bounded host-local staging of the exact pinned restore image (`podman pull`), followed by a read-only/no-network/no-host-mount local tool-inventory container using `--pull=never`. Preserve independent pull/probe statuses, keep the cached image, and remove only its own CID-identified probe container. No container or image staging was executed during preparation; this prerequisite is not a cluster inspector or additional lifecycle.

## Evidence

Contract source: `scenario-spec.md`; implementation: `run.sh`, `pipeline.py`, `observe.py`, `guest-read.sh`, `vm-2disk.json`, `bundle-files.txt`; preparation evidence/limitations: `local://exp06-engineer-retry-handoff.md` (preserved earlier state: `local://exp06-engineer-handoff.md`). Lead owns the matching pre-armed run root and canonical lifecycle-ID array; the bundle never creates or rewrites that state. Lifecycle evidence remains in repository `runs/<short-id>/`; chaos evidence is under the scenario `runs/<descriptive-chaos-id>/`. No evidence was copied from archived attempts.

## Negative results and falsifier

The silent-drop hypothesis is not supported if both disks remain included or the missing coverage is detected. A control failure, missing independent pre-state, wrong UID/window, untouched bitmap or excessive blast radius prevents valid attribution. A metadata-only check cannot falsify datadisk content loss because content is deliberately outside this scenario's workload.

## Additional feedback / unknowns

Exact lower-layer release is UNKNOWN when the PVC→PV→CSI image→node→host mount/device chain or transient restore device identity cannot be safely resolved using approved reads. VMI detach/pod deletion alone cannot prove release. No additional inspector pods, cleanup, fresh controls or recovery experiments may be added to close these evidence gaps.
