# CBT-EXP-06 — Multi-disk checkpoint-bitmap loss between full and incremental

## Identity and provenance

This is the original EXP-6 hypothesis: losing one disk's checkpoint bitmap (QEMU's per-disk changed-block map) might silently exclude that disk after checkpoint redefinition. It is a hypothesis, not a predicted verdict. The original source cited KubeVirt v1.8.4-era `RedefineCheckpoint` / `findDisksWithCheckpointBitmap`; that source attribution is not a current-run finding.

Preparation corrections preserve the original control requirement and exact full-to-incremental fault window:

- Human clarification `cbt-exp06-control-20261016T185816Z`, relayed by Main to Lead, answered at `2026-10-17T00:00:00Z`: **two fresh two-disk VMs**. Control: full + incremental + restore. Surgery: setup + full, remove datadisk full-checkpoint bitmap, restart VMI once, incremental + normal final verification if reached. No recovery/cleanup leg.
- Human clarification `cbt-exp06-sizing-20261016T190300Z`, same relay timestamp: **40Gi cloned root + 2Gi blank datadisk per VM**, existing full80Gi and incremental30Gi destinations, at least400Gi RBD pool headroom and100Gi actual node ephemeral free space, default small workload. This replaces the original technically impossible5Gi clone: the currently resolved source image is30Gi; CDI reports6% filesystem overhead. No source shrinking or alternate image is authorized.
- Executing Make semantics: `TYPE=full` means setup/adoption + full only, not full + incremental + restore. This bundle uses the exact individual stage targets, with one owner, and explicitly runs control incremental and verification. Adoption validates pool/run labels and profile/pass annotations, not root-size equality.

These clarifications authorize preparation only. A complete hash/parameter approval is still required before any lifecycle/action.

## Objective and workflow

Both fresh VMs have `rootdisk`/vda and `datadisk`/vdb, plus a non-backup cloud-init disk. The datadisk is blank2Gi, initialized as ext4 and mounted by cloud-init; it has no generated workload. Root workload defaults are8 baseline files,4 new files plus one baseline modification per incremental,4–12MiB per file, one incremental pass per VM.

`run.sh` owns creation, adoption, every stage, waits, original exit statuses, the sole injection, and read-only collection. Lead must not launch these stages in parallel or duplicate them:

| Leg | Exact target sequence after scenario-local VM/service creation | Owner |
|---|---|---|
| Control | `make vm-setup RUN_ID=<control> EXISTING_VM=vm-<control>`; `make vm-backup RUN_ID=<control>`; `make vm-cbt-backup RUN_ID=<control>`; `make vm-cbt-verify RUN_ID=<control>` | `run.sh` |
| Surgery | `make vm-setup RUN_ID=<surgery> EXISTING_VM=vm-<surgery>`; arm collectors/witness; `make vm-backup RUN_ID=<surgery>`; exact composite fault; `make vm-cbt-backup RUN_ID=<surgery>`; `make vm-cbt-verify RUN_ID=<surgery>` only if incremental succeeds | `run.sh` |

Every Make call explicitly fixes RHEL9/large-ODF, namespace, small workload, one pass, full inventory, selected kubeconfig and pinned restore image. No preflight bypass is used. Lifecycle evidence stays under repository `runs/<short-lifecycle>/`; the descriptive chaos ID never becomes a Kubernetes name.

## Chaos Injection

- Target: exactly the **surgery VM's full-checkpoint bitmap on datadisk/vdb**, selected live from the completed full and tracker; the unique qcow2 format node whose filename ends `/cbt/datadisk.qcow2`. Never select its storage-node sibling or a historical node name.
- First action: one `oc exec` to the live, UID-validated launcher's `compute` container, `virsh qemu-monitor-command <resolved-domain> '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"<resolved-format-node>","name":"<full-checkpoint>"}}'`.
- Second action: exactly one VMI restart, using a Kubernetes DELETE with `DeleteOptions.preconditions.uid=<original-VMI-UID>` and `gracePeriodSeconds:0`, through an invocation-owned loopback `oc proxy`. No unguarded delete-by-name, VM deletion or restart retry. Replacement must have a new VMI UID and launcher UID, be Running/Ready with CBT Enabled, and be owned by the unchanged surgery VM UID.
- Fallback rationale: installed `krknctl v0.14.2-beta` availability, `kubevirt-outage` and `container-scenarios` describe/help were inspected. Kubevirt outage deletes VMIs; container scenarios send container signals. Neither expresses a QEMU node/bitmap mutation paired with that immutable VMI. Native trigger support exists (timeout behavior `skip|fail|run_anyway`, default skip); it does not add the missing fault primitive. Pattern C is used for the composite fault, not because triggers are absent. A supported exact-name kubevirt-outage `--dry-run` was rehearsed without executing it.

## Injection Timing

Between **surgery full completion and surgery incremental creation**; no active-copy predicate or arbitrary startup sleep.

Before action, require completed Full, both included volumes, tracker at that full checkpoint, no surgery incremental object, exact VM→VMI→launcher UID chain, both persistent non-busy recording bitmaps, collector readiness/liveness, and a separate read-only witness's saved full raw QMP snapshot proving datadisk presence. Revalidate the full window and identity immediately before QMP removal. Before restart require actor and witness raw after-snapshots showing only that bitmap gone and root/sibling bitmap names unchanged, then revalidate identity/window again. Fail closed on ambiguity, missing evidence or lost readiness. Never overwrite raw QMP with a projected empty array.

The read-only witness process is separate from the mutating process and performs its own live queries; it does not copy the injector's files. Both are authored in this bundle and use the Lead's credentials, so this is not an independently administered trust principal. The independent Analyst audits raw snapshots/statuses, not the author's assertions.

## Expected Behavior / Pass-Fail Criteria

Mandatory control: full and incremental complete successfully, their `includedVolumes` each contains exactly `rootdisk` and `datadisk`, and normal root restore reconstructs baseline and cumulative incremental file sets/bytes/hashes. A failed control aborts before surgery. The Linux verifier selects exactly one `*-rootdisk.qcow2` in each backup PVC, rejecting missing/ambiguous root images rather than selecting datadisk by ordering; other reconstruction/hash checks are unchanged.

Mandatory injection evidence: independent full raw QMP before/after, exact UID/state/action/status/timestamps, same-VM-owned replacement and root/sibling exclusions. Script machine checks are not an injection grade.

Surgery observations: capture backup UID, type, Done/other conditions/reasons, included volumes, tracker volume set, redefined checkpoint XML and controller log window. Compare VMI backup-status checkpoint/volumes with libvirt/QMP; capture warning events separately by backup UID and VMI UID.

- Original defect signal: completed `Done=True`, type Incremental, datadisk missing from includedVolumes **without a warning**.
- Original resilient alternatives: both disks remain included, **or** missing coverage is detected (checkpoint cleared/full fallback, warning, or terminal failure). An empty backup event list is not proof of no warning; inspect UID-scoped VMI events/conditions/logs too.
- A nonterminal backup at the existing20-minute backup-wait bound is **NONTERMINAL_AT_BOUND**, not completed, not silently PASS/RESILIENT, and not proof of an infinite hang. Preserve raw state and original stage status; the Analyst applies the approved criteria. This observation bound is a test limit, not a documented product cleanup/terminal SLA. Do not retry, reconcile, create another backup or recover it.
- Per-disk limitation: root restore grades the generated root workload only. Datadisk content/bootability is not graded; both-disk metadata is mandatory. Reports must disclose this, and must not claim whole-VM data correctness from root hashes.

The stock EXP-06 evaluator registry asks for extra same-VM recovery and clean lifecycle legs absent here; it is **not applicable unchanged**. No such legs may be added to satisfy it. Named raw checks and their evidence are supplied in the preparation handoff; only the independently assigned Analyst writes `analysis.json`.

## Blast Radius and Exclusions

Two newly created, run-owned two-disk VMs on one explicitly approved schedulable RBD-capable worker; own DVs/PVCs, trackers, backups, services, backend-state and ordinary temporary restore pods. Only one bitmap and one VMI of the surgery VM are disrupted. Root bitmap, other bitmap names/nodes, control VM and all unrelated workloads/components are excluded. No node/pod disruption, migration, shared configuration change, inspector pod, recovery, reconcile, cleanup or evidence deletion.

Nominal persistent requests: `2*(40+2+80+30)=304Gi`, before CDI clone overhead/backend-state. Full80Gi exceeds both VM disk virtual sizes. RBD `MAX_AVAIL` must be≥400Gi, actual approved node kubelet filesystem free≥100Gi; restore is sequential and uses existing helper scratch, not a new PVC. Resolve source PVC→PV→CSI and actual raw-image geometry before setup, rather than mistaking HPP pool-sized reported capacity for source-image size.

## Execution and Approval

Execution is through the approved SSH alias and executing checkout, recorded privately by Lead; no real host paths/credentials are committed here. Required tools: Bash, Make, Python3, oc, jq, OpenSSH tools and installed krkn metadata access; cluster auth, exact VM/backup/DV/PVC/service creation, UID-guarded VMI deletion, ordinary restore pod management, exec/portforward/log and approved read-only cluster/storage/node privileges. A representative existing VM is an explicitly approved **read-only tool probe**, never an action target. Native krkn runtime/container auth is not an execution dependency because no krkn scenario is run.

Approval also discloses the host-local restore prerequisite: bounded `podman pull <exact-approved-digest>` (240s), then a read-only/no-network/no-host-mount local container (90s outer,30s container limit) checking required restore binaries. It uses `--pull=never` after the explicit staging command. Keep the cached image; remove only this invocation's CID-identified probe container, never images or unrelated containers. This is not a cluster inspector or an extra workload/verification leg. Pull, probe and own-container removal statuses are independent. The Engineer inspected help/metadata only and did not pull/start it.

Lead creates the matching fresh run root/run.json before entrypoint execution. Matching pre-created roots are accepted; prior execution/action/effect/confirmation outputs and identity mismatches are rejected. Lead allocates both short lifecycle IDs and the chaos ID via `cbt-chaos/run-id.sh <exact-surgery-vm> bitmap-drop <iteration>`. `--plan`, `--manifest`, `--parameters` and `--check-root` are nonmutating interfaces; none approves or creates an attempt.

`run.json.lifecycle_ids` is the canonical ordered **array** `[<control>, <surgery>]`, compatible with Lead/pull metadata; an optional separate `lifecycle_roles` map must match those same identities. The bundle never writes Lead's run state and accepts its matching pre-armed root without requiring that directory to be absent.

Lead approval must cover `bundle-files.txt` (including spec/Jira, all invoked scripts/configs and actual executing `.env` **hash only**) and exact effective parameters from `--parameters`, cluster/host/context, worker name+UID, source PVC UID, tool-probe VM name+UID, restore digest, windows/read scope and command. Recompute immediately before execution; changed files/scope/parameters need fresh approval. Entrypoint guards approval before setup and again before stages/actions. Lead alone owns approval/run state/execution/report/pull. Author never approves or grades.

Bounds: pipeline10800s; setup2400s each; full1500s each; incremental1500s each (shared backup wait1200s); verification2100s each; readiness30s; QMP witness boundary120s per handoff; VMI replacement300s; each read typically20s and snapshot120s. Independent collectors start as soon as each submitted VM UID resolves, before setup/full, take bounded samples, and observe300s after the always-run terminal marker. Finalizer join600s plus at most120s fallback snapshot per resolved VM if its collector failed. SIGINT/TERM preserves original status and final collection; SIGKILL/host loss cannot guarantee finalization and is UNKNOWN.

## Recovery and Terminal Evidence

No rollback/recovery mutation is authorized. Preserve VM disks, failed backup/tracker/destination and all evidence. Stop only invocation-owned local processes. Normal restore stage's existing transient helper lifecycle is part of the required original verification, not added recovery.

API/control-plane, guest/workload and host/storage state are separate. Always-armed collection covers ordinary completion, stage failure, harness exceptions and interruption, only for actually submitted/resolved resources. Capture exact PVC UID→PV UID/claimRef→CSI driver/handle/image→consumer pod UID/node→VolumeAttachment/node pins→existing-handler exact mount/device correlation. Source/back-end volumes are expected retained; temporary backup attachments are evaluated separately from preserved PVC existence. Host CLEAR requires previously correlated exact mount/device identity; missing image mapping, missed baseline, denied/unsafe probe or partial/timed-out collection stays UNKNOWN. VMI volume removal, pod deletion, Ready or Done alone cannot prove lower-layer release. Residual/UNKNOWN warnings require Lead's approved read-only follow-through, never an inspector/cleanup mutation.

Guest evidence includes agent ping **and actual SSH workload reads**, datadisk mount/block inventory and root file hashes. Neither API Ready nor agent ping alone proves workload availability. Root restore scratch loop/NBD host release may remain UNKNOWN if the ordinary helper's precise transient device was not observable before its deletion; do not infer release from deletion or create another helper to recover missing evidence.

## Evidence

`runs/<chaos-id>/execution/`: independent per-command stdout/stderr/status, setup manifests, control/surgery lifecycle references, before-action full/tracker/UID/QMP, exact action request/reply, independent witness full raw samples, after/replacement raw effects/exclusions, original stage statuses, both VM read-only observations and bounded final collection. `injection-confirmation.json` contains only machine checks and raw references (UNKNOWN until proven); no `analysis.json` is authored. Lifecycle originals remain in repository `runs/<control>/` and `runs/<surgery>/`, never copied or overwritten. Lead/Analyst own final interpretation and reports.

Controller logs persist only exact-token matches for the resolved lifecycle/VM UID/name and observed backup UID/name/checkpoint, within the collector's start-to-terminal collection interval. Each log command retains operation/evidence status and input/matched/excluded line counts; unrelated controller lines are not persisted or interpreted. The 4MiB retrieval cap, unidentified messages and truncated records can leave warning coverage UNKNOWN. Each resource-chain snapshot has a hard120s cap; timed-out or partial chains cannot prove release, even when another API condition is clear.
