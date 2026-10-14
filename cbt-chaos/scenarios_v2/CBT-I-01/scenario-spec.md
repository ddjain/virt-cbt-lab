# Scenario: Restart the virtual machine between full and incremental backups

## 1. Identity

- **Scenario ID:** CBT-I-01
- **Jira issue:** CBT-I-01 — "Restart the virtual machine between full and incremental backups" (P1, technical scenario: vmi-outage, phase: post-operation / pre-incremental)
- **Run family:** incremental-backup workflow, workload-plane disruption

## 2. Objective and hypothesis

**Jira objective:** exercise Changed Block Tracking checkpoint recovery after a VM restart — the VM should restart, CBT should reinitialize and attempt checkpoint redefinition, and the next backup should either remain genuinely incremental or follow the documented full-backup fallback. A silent incorrect incremental is a failure.

**Product question:** if the VMI is deleted after the full backup's checkpoint is recorded but before the incremental pass begins, does the restarted VM's CBT state recover such that the pass-1 backup is either a genuinely correct incremental (checkpoint redefined, changed blocks relative to the full) or an explicit full fallback — with the restore chain still verifying?

## 3. Workflow and prerequisites

Two-stage managed lifecycle as F-07/F-12/F-13: `make e2e TYPE=full` (RHEL 9, default HostPath variant, 1000 × 15–20 MiB baseline, 52–55 s full baseline), then the disruption, then `make e2e TYPE=incremental VM=vm-<RUN_ID>` for the single planned incremental pass with final restore verification.

Prerequisites:

- The VMI deletion must land between the full checkpoint being recorded (full stage exit, tracker has exactly one checkpoint) and the incremental stage creating its backup object. The trigger runs the full stage to completion, deletes the VMI, waits for the VM's run strategy to recreate it (Running/Ready + agent ready), and only then starts the incremental stage — the window is minutes wide, no race needed.
- `oc delete vmi <name>` on a VM with a running strategy recreates the instance automatically (no manual restart needed).

## 4. Target and validated disruption

**Target:** `vmi/vm-<RUN_ID>` in vm-cbt-demo (the workload VM's instance object — NOT the VM object; deleting the VM would tear down the lifecycle).

**Action:** `oc delete vmi vm-<RUN_ID> -n vm-cbt-demo --wait=false`. This is the vmi-outage-equivalent direct action; krknctl's kubevirt-outage plugin targets VMs by label/namespace on a timer, not "the VMI of run R between its full and incremental stages" — the direct deletion is the same physical disruption (pod teardown + domain shutdown + recreation) with deterministic timing.

**Expected mechanics (to verify, not assume):** VM object recreates the VMI (Running strategy); launcher pod replaced; CBT bitmap reinitialized in QEMU; checkpoint redefinition attempted against the recorded full checkpoint. The pass-1 backup's type (Incremental vs Full fallback) is recorded as the primary observation.

## 5. Verification criteria

- Injection validity: VMI deleted after full stage exit (full Done + checkpoint recorded) and before incremental object creation; new VMI UID differs from the old (proof of restart); launcher pod replaced.
- CBT recovery: pass-1 backup `Done=True`; its type recorded (Incremental or Full fallback) with the reason; if Incremental, it must be genuinely incremental (changed blocks vs full — data content correct per restore) — a silent wrong-content incremental is FAIL.
- Backup correctness: exactly one checkpoint for the incremental pass; chain full → p01 valid; restore hashes PASS (full-only and cumulative).
- VM recovery: VMI Running/Ready with new UID before the incremental stage starts; guest workload intact (the incremental stage re-validates the baseline manifest before mutating).
- Duration: full baseline 52–55 s; incremental baseline 16–21 s (a Full fallback after restart will be visibly longer, ~52–55 s — that is a legitimate documented outcome, not a failure).

## 6. Pre-run guards

RUN_ID collision guard (observer pre-create allowed), VMI nodeName determinism guard (informational), full-stage must exit 0 before the deletion is issued (checkpoint recorded), VMI recreation must reach Running/Ready before the incremental stage starts (poll with timeout).

## 7. Uncertainties

- Whether the backup type after restart is Incremental or Full fallback is the experiment's subject; both are acceptable if data-correct and explicit. The decisive check is the restore content matching the mutated workload, plus absence of "silent incremental with wrong data".
- Checkpoint redefinition details live in virt-launcher logs (libvirt domain events) and the vmbackup controller logs; the observer captures launcher logs and events for the redefinition evidence.
