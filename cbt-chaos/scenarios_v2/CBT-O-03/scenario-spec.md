# Scenario: O-03 kill csi-rbdplugin ctrl-plugin (provisioner) mid-copy

## 1. Identity

- **Jira issue:** CBT-O-03 (P2, technical scenario: pod-scenarios via direct-krkn pod_disruption)
- **Run family:** ODF storage-control-plane disruption during full backup
- **Precedents:** O-02 (node-plugin kill — same trigger shape); F-13 (cleanup-window gating via hp-volume pod presence); F-12 (controller kill semantics)

## 2. Objective and hypothesis

**Objective:** is the ctrlplugin needed for (a) the streaming copy, (b) the post-Done detach?

**Hypothesis:** copy immune (device already mapped); cleanup delayed while the attacher sidecar is down. o03c (both replicas) tests whether detach stalls until the Deployment restores quorum.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD + ctrlplugin 2/2 Ready pre-run.
2. Background `make e2e TYPE=full ... MANIFEST_VARIANT=odf`.
3. Gate by leg: o03a/c on Progressing=True; o03b on the F-13 superset condition (backup exists ∧ Done≠True ∧ hp-volume-* pod present, 1s cadence).
4. Direct-krkn pod_disruption YAML: namespace_pattern=openshift-storage, name_pattern=`^openshift-storage\.rbd\.csi\.ceph\.com-ctrlplugin-`, kill=1 (o03a/b) or kill=2+parallel (o03c), krkn_pod_recovery_time=600.
5. Post-Done: poll VolumeAttachment + hp-volume pod absence for up to 10 min (bounded cleanup-grace criterion).
6. Follow-up incremental + restore verify.

## 4. Target and validated disruption

- **Target:** ctrlplugin Deployment pods (attacher/provisioner sidecars; NOT hostNetwork — regular pod networking).
- **Blast radius:** all RBD PV lifecycle ops cluster-wide for the replacement window (~15-45s); no data-path effect expected. Other tenants: the campaign namespace only for the backup under test.

## 5. Verification criteria

- Injection: ctrlplugin pod UIDs changed within window (events proof).
- Copy: Done=True/Successfully (expected) or accurate failure.
- Cleanup: no lingering VolumeAttachment for the backup PVC or hp-volume pod after a 10-min post-Done grace (F-13 criteria); if lingering, record duration — that is the finding.
- Tracker advances once; incremental + restore verify pass.

## 6. Pre-run guards

Standard; ctrlplugin Deployment Available (2/2) pre-run; ceph HEALTH_OK.

## 7. Uncertainties

- The o03b cleanup window is sub-second on HPP (F-13 measured); on RBD detach may take longer — the 1s-cadence superset gate with post-hoc event attribution is the sanctioned approach either way.
- pod_disruption recovery monitor may report unrecovered pods if the Deployment replacement is slow — krkn rc non-authoritative (same as O-02).

## 8. Evidence

krkn log; ctrlplugin pre/post pod json (UIDs); vmbackup conditions + events; VolumeAttachment/hp-volume post-Done poll log; trigger-checks.txt.
