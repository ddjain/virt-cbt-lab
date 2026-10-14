# Scenario: O-09 per-volume RBD ENOSPC on the backup destination

## 1. Identity

- **Jira issue:** CBT-O-09 (P2, technical scenario: direct fallocate pre-fill pod — the I-05 r02 validated recipe)
- **Run family:** ODF capacity exhaustion (per-volume, vs O-08's pool-level)
- **Precedents:** I-05 r01/r02 (Multi-Attach blocker; clean ENOSPC + tracker hold); F-08 (full-dest ENOSPC)

## 2. Objective and hypothesis

**Objective:** pin the clean-failure semantics on the large-odf sizing (80Gi full / 30Gi incr PVCs).

**Hypothesis:** identical to I-05 r02 — pre-fill makes the copy hit ENOSPC ~1s in, Done=True failure with a no-space reason, tracker holds FULL (VMI alive), recovery on fresh PVC succeeds.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD.
2. Full leg (o09a/c): render `manifest_path full-backup` with the run substitutions; split off ONLY the PVC document (I-05's awk record-separator split); apply; wait Bound.
3. Filler: `kubectl run filler-<RUN_ID> --restart=Never --image=registry.redhat.io/rhel9/toolbox:latest` with overrides mounting the PVC at /data, `fallocate -l <FILL_SIZE> /data/.cbt-filler`, df before/after to fill-report; wait Succeeded; delete; wait until no pod mounts the PVC (release).
4. Incremental leg (o09b): run a clean full first (`make e2e TYPE=full`), then the same pre-fill recipe on the p01 PVC before `TYPE=incremental`.
5. Backup creation proceeds against the pre-filled PVC (stage's `oc apply` no-op merges on the existing PVC).
6. Verdict + recovery: API-level retry with pass-02 names (I-05 §3 recipe) or `TYPE=recover`.

## 4. Target and validated disruption

- **Target:** the destination PVC only. Blast radius: this run's PVC — nothing shared.
- **Sizing:** 80Gi full dest (fill 70-78G), 30Gi incr dest (fill 29G); payload ~17.5GiB per stage.

## 5. Verification criteria

- Filler Succeeded with df evidence; volume released before backup creation.
- Clean failure: Done=True no-space reason within the workflow's 20m wait (I-05: ~1s after copy start).
- Tracker holds FULL checkpoint across ≥2min of 10s samples (25 samples, I-05 pattern).
- VM unpaused, VMI Running.
- Recovery: fresh-PVC backup succeeds and chains/restores.
- UNEXPECTED-SUCCESS branch: post-backup df + file listing to distinguish fill-erased from copy-fit (I-05 caveat a).

## 6. Pre-run guards

Standard; filler-pod hygiene (name `filler-<RUN_ID>`, deleted after allocation); PVC pre-created from the stage's own template only.

## 7. Uncertainties

- o09c boundary: 10Gi slack vs 17.5GiB payload — the copy fails after landing ~10GiB; the interesting datum is whether the partial qcow2 is ever treated as valid (must not be).
- Whether the controller's failure cleanup (unplug + attachment-pod delete) behaves identically on the large-odf sizing (I-06 teardown-leak class risk — watch VolumeAttachment).

## 8. Evidence

filler pod log/yaml, PVC yaml, vmbackup conditions+events, tracker samples, VMI conditions, recovery-run result, trigger-checks.txt.
