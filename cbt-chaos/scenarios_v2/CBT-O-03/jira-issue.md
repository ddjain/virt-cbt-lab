# CBT-O-03: Kill the RBD CSI ctrl-plugin (provisioner) during the backup copy

**Purpose:** Establish whether the csi-rbdplugin controller-side deployment (provisioner/attacher — the component that maps PVs, creates/deletes rbd images, and processes VolumeAttachments) is required once a backup destination is already attached and the copy is streaming.

## Workflow

Full backup

## Test Objective / Description

Delete one csi-rbdplugin ctrlplugin pod (2 replicas, openshift-storage) mid-copy. The copy path uses the kernel rbd device already mapped on the VM's node; the ctrlplugin's responsibilities (attacher, provisioner, snapshotter sidecars) are control-plane for volumes. Determine whether copy or cleanup (post-Done detach of the destination PVC) stalls when the ctrlplugin leader dies mid-copy.

## Chaos Target

openshift-storage.rbd.csi.ceph.com-ctrlplugin Deployment pod (label app=openshift-storage.rbd.csi.ceph.com-ctrlplugin)

## Chaos Action

Delete one ctrlplugin replica mid-copy

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

Immediate (single pod deletion; Deployment replaces in ~15-45s)

## Expected Behavior

Copy completes (attach already done). The post-Done detach may be delayed until the replacement ctrlplugin resumes the VolumeAttachment reconciliation. No false success; tracker advances once.

## Recovery

Automatic Deployment replacement.

## How to Verify

Backup Done reason; ctrlplugin replacement pod Ready; destination PVC detach completes (no lingering VolumeAttachment / hp-volume pod beyond a bounded grace — the F-13 cleanup criteria); follow-up incremental + restore verify.

## Expected Outcome

Separates the ctrlplugin's attach/detach role from the copy data path; quantifies any post-Done cleanup delay.

## Priority

P2

## Technical Scenario

pod-scenarios (direct-krkn pod_disruption pattern with hand-written YAML pinning the ctrlplugin name-pattern in openshift-storage — same rationale as O-02: precise targeting + the campaign's validated direct-krkn recipe)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Variant | Rationale |
|---|---|---|
| o03a | kill 1 of 2 replicas mid-copy | Baseline: leader failover while copy streams |
| o03b | kill at cleanup window (gate: Done flip imminent, hp-volume pod present) | The teardown path where detach IS ctrlplugin-dependent (F-13 window analog) |
| o03c | kill both replicas (kill: 2, parallel) | Full ctrl-plugin outage during copy+cleanup — does detach wait for quorum return? |

3 legs max.
