# Incremental backup passes — feature summary

## Implemented behavior

The workflow supports one VM lifecycle containing one full backup and a configured sequence of incremental backups. Each incremental pass adds a new deterministic workload-file set to the same VM, writes a pass-specific backup and PVC, and advances the CBT tracker from the previous checkpoint.

Two run modes are supported:

- **One-shot:** `TYPE=all` (the default) performs setup, the full backup, all configured incremental passes, and verification in one `make e2e` invocation.
- **Staged:** `TYPE=full` creates the VM and baseline workload and takes the full backup. Each `TYPE=incremental` invocation adds exactly the next planned pass without reinitializing the VM. The final planned pass verifies the checkpoint chain and restores. After that lifecycle is complete, `TYPE=extend VM=vm-<run-id> EXTEND_TO_PASS=<new-total>` adds exactly one pass to the same VM. `TYPE=verify` reruns verification without adding a pass.

`GUEST_INCREMENTAL_PASSES` is the initial planned count; it defaults to `1` and supports `1`–`99`. The full stage stores the selected profile, initial pass count, completed count, next pass, report ID, backup names, and checkpoints in `report/vms/<run-id>/vm-info.json`. Later stages load that saved configuration. File counts, size range, and OS remain fixed for the lifecycle; an explicit `TYPE=extend` can increase the pass total by one after successful completion.

Every pass has unique resources named `vm-incremental-<run-id>-pNN` and `vm-incremental-pvc-<run-id>-pNN`. Per-run JSON reports and the deterministic `workload-manifest.json` record the files and payload bytes added by each pass, cumulative totals, hashes, backup/PVC details, and restore results. `make clean-all` removes workflow-managed cluster resources and marks the lifecycle record cleaned, but retains reports. Backup PVC storage grows with every pass until cleanup.

See the [workflow guide](vm-cbt-workflow.md) for the full sequence, resource contract, report schema, and storage details.

## How to run it

### One command

```sh
make e2e GUEST_INCREMENTAL_PASSES=3
```

This uses the default OS profile and workload settings. Override `VM_OS`, file counts, or the file-size range as needed at lifecycle creation.

### Separate staged commands

Use a fresh, unique VM name. The following creates one full backup and a lifecycle configured for three incremental passes:

```sh
make e2e TYPE=full VM=vm-stage-demo VM_OS=rhel9 GUEST_INCREMENTAL_PASSES=3
```

Then invoke the incremental stage **three times**, sequentially:

```sh
make e2e TYPE=incremental VM=vm-stage-demo
make e2e TYPE=incremental VM=vm-stage-demo
make e2e TYPE=incremental VM=vm-stage-demo
```

The third invocation verifies the checkpoint chain and every restored workload prefix. To rerun verification later without adding a pass:

```sh
make e2e TYPE=verify VM=vm-stage-demo
```

### Extend a completed lifecycle

After a lifecycle configured for three incremental passes is complete, add
pass 4 without recreating the VM or full backup:

```sh
make e2e TYPE=extend VM=vm-stage-demo EXTEND_TO_PASS=4
```

`EXTEND_TO_PASS` is the new total and must be exactly one greater than the
current total (maximum 99). The extension reuses the saved file count and
size range, adds the next deterministic file set and a pass-specific backup
PVC, then verifies the full restore and every incremental prefix. Repeating
the same target after it is complete creates no additional pass. Each ODF
extension adds another 30Gi incremental PVC until `make clean-all`.


Use `VM=vm-<run-id>` for staged commands. Run lifecycle commands sequentially from one checkout; the E2E lock rejects concurrent commands. Do not run `make clean-all` unless you intend to delete all resources managed by this workflow in the namespace.

## How to test it

### Offline regression and syntax checks

```sh
make test
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
make help
```

`make test` does not contact a cluster. It checks pass-specific backup/PVC naming, rejects out-of-order manifest appends without modifying the manifest, validates per-pass and cumulative file/byte totals, checks VM lifecycle state transitions, exercises completed-lifecycle extension and one-pass target validation, and drives the staged E2E dispatcher with isolated state. The dispatcher tests verify one-pass advancement, verification after the final pass, failure without counter advancement, and the extension path's `vm-cbt-extend` → backup → verification sequence.

### Cluster integration test

Run the staged commands above on a cluster that passes `make preflight`. Inspect `report/vms/stage-demo/vm-info.json` after each command:

- After `TYPE=full`: `incremental_passes_completed` is `0` and `next_incremental_pass` is `1`.
- After incremental invocations one and two: the completed count advances to `1` and `2`; the same VM and report ID remain in use.
- After invocation three: all passes are recorded and the lifecycle reaches verification.

After the three-pass lifecycle is complete, run:

```sh
make e2e TYPE=extend VM=vm-stage-demo EXTEND_TO_PASS=4
```

The same VM, disk, full backup, and tracker must remain in use. The lifecycle
and manifest totals become 4, `incremental_passes_completed` reaches 4,
`next_incremental_pass` returns to `null`, pass 4 gets its own backup/PVC, and
the final report verifies the full image and all four cumulative prefixes.

The final `report/<REPORT_ID>/report.json` must have `verification.overall_passed: true`. It contains the full backup, each incremental backup and checkpoint, cumulative workload counts/bytes, and full-plus-pass restore comparisons. The monitor output reports the API-observed duration of the full backup and each incremental pass.

## Recorded integration smoke

A Windows one-shot three-pass E2E completed successfully. The merged report recorded `verification.overall_passed: true`, and the full restore plus all three cumulative incremental restores matched their manifests. That smoke used a deliberately small workload: 2 baseline files (4 MiB), then 2 files per pass with a 1–2 MiB range. Added payloads were 3 MiB, 4 MiB, and 3 MiB; cumulative workloads were 4 files / 7 MiB, 6 files / 11 MiB, and 8 files / 14 MiB. The pipeline took 612 seconds; the full backup took 49 seconds and the incremental passes took 8, 13, and 14 seconds. It used a 40 GiB VM disk, a 48 GiB full-backup PVC, and 30 GiB per incremental PVC.

This smoke exercised the one-shot path. It did not run the staged `TYPE=full` plus separate `TYPE=incremental` commands on a live cluster, did not test RHEL, and did not use the separate 100/50-file, 5–10 MiB workload profile. Use the staged cluster integration procedure above to validate that exact path and profile.
