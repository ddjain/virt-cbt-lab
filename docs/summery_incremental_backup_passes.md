# Incremental backup passes — feature summary

## Implemented behavior

The workflow supports one VM lifecycle containing one full backup and a configured sequence of incremental backups. Each pass adds deterministic workload files and modifies one deterministic baseline file on the same VM, writes a pass-specific backup and PVC, and advances the CBT tracker from the previous checkpoint.

Two run modes are supported:

- **One-shot:** `TYPE=all` (the default) performs setup, the full backup, all configured incremental passes, and verification in one `make e2e` invocation.
- **Staged:** `TYPE=full` creates the VM and baseline workload and takes the full backup. Each `make e2e-incremental VM=vm-<run-id>` invocation adds exactly the next planned pass without reinitializing the VM; `TYPE=incremental` remains equivalent. The final planned pass verifies the checkpoint chain and restored prefixes. After completion, `TYPE=extend VM=vm-<run-id> EXTEND_TO_PASS=<new-total>` adds exactly one pass to the same VM. `TYPE=verify` reruns verification without adding a pass.

`GUEST_INCREMENTAL_PASSES` is the initial planned count; it defaults to `1` and supports `1`–`99`. The full stage stores the selected profile, pass counters, backup names, and checkpoints in `runs/<run-id>/run.json`; later stages load that saved configuration. File counts, size range, and OS remain fixed for the lifecycle; `TYPE=extend` can increase the pass total by one after successful completion.

Every pass has unique resources named `vm-incremental-<run-id>-pNN` and `vm-incremental-pvc-<run-id>-pNN`. The per-run JSON report and deterministic `workload-manifest.json` record each pass's additions, baseline modification, payload bytes, per-file hashes, cumulative totals, backup/PVC details, and restore results. `make clean-all` removes workflow-managed cluster resources and marks the lifecycle record cleaned, but retains reports. Backup PVC storage grows with every pass until cleanup.

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
make e2e-incremental VM=vm-stage-demo
make e2e-incremental VM=vm-stage-demo
make e2e-incremental VM=vm-stage-demo
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

`make test` is cluster-independent. It verifies pass-specific resources, deterministic add/modify manifest plans, cumulative counters, lifecycle extension, restore-failure propagation, run-scoped evidence/logging, monitor timings, and staged-dispatch transitions.

### Cluster integration test

Run the staged commands above on a cluster that passes `make preflight`. Inspect `runs/stage-demo/run.json` after each command:

- After `TYPE=full`: `incremental_passes_completed` is `0` and `next_incremental_pass` is `1`.
- After incremental invocations one and two: the completed count advances to `1` and `2`; the same VM and explicit run ID remain in use.
- After invocation three: all passes are recorded and the lifecycle reaches verification.

After the three-pass lifecycle is complete, run:

```sh
make e2e TYPE=extend VM=vm-stage-demo EXTEND_TO_PASS=4
```

The same VM, disk, full backup, and tracker must remain in use. The lifecycle
and manifest totals become 4, `incremental_passes_completed` reaches 4,
`next_incremental_pass` returns to `null`, pass 4 gets its own backup/PVC, and
the final report verifies the full image and all four cumulative prefixes.

The final `runs/<run-id>/report.json` must have `verification.overall_passed: true`. It contains the full backup, each incremental backup and checkpoint, cumulative workload counts/bytes, and full-plus-pass restore comparisons. The monitor output reports the API-observed duration of the full backup and each incremental pass.

## Recorded integration smoke

A Windows one-shot three-pass E2E completed successfully. The merged report recorded `verification.overall_passed: true`, and the full restore plus all three cumulative incremental restores matched their manifests. That historical smoke used a deliberately small workload: 2 baseline files (4 MiB), then 2 files per pass with a 1–2 MiB range. Added payloads were 3 MiB, 4 MiB, and 3 MiB; cumulative workloads were 4 files / 7 MiB, 6 files / 11 MiB, and 8 files / 14 MiB. The pipeline took 612 seconds; the full backup took 49 seconds and the incremental passes took 8, 13, and 14 seconds. It used a 40 GiB VM disk, a 48 GiB full-backup PVC, and 30 GiB per incremental PVC. This run predated the per-pass baseline modification assertion, so it is not evidence for that behavior.

An earlier Windows smoke used add-only mutations and did not cover the staged RHEL path. The integration checks below exercise the current per-pass modification and cumulative-prefix behavior.

The RHEL 9/large-ODF one-shot run passed with 1,000 baseline files (18,277,728,256 bytes), 1,000 additions plus one modified baseline file (18,284,019,712 added bytes), and 2,000 cumulative files (36,561,747,968 bytes). Full and incremental restore manifests matched; `overall_passed` was true. The full backup took 72 seconds, the incremental took 18 seconds, and the complete pipeline took 606 seconds.

The staged RHEL run used 100 baseline files, 50 additions per pass, one baseline modification per pass, and a 5–10 MiB range. All three `make e2e-incremental` passes passed; the full restore and each cumulative prefix matched its manifest. `TYPE=extend EXTEND_TO_PASS=4` added pass 4 to the same VM and verified all four prefixes. The report recorded cumulative counts of 150, 200, 250, and 300 files and `overall_passed: true`.

The Windows `windows-e2e` retry passed after an earlier attempt exposed a malformed PowerShell mutation list. It added four deterministic files, modified one baseline file, and restored the expected 12-file NTFS prefix with `overall_passed: true`; Windows preflight passed 110/110. Setup logged a QEMU Guest Agent status timeout, then completed its Python/file/SQLite/HTTP workload checks and backup workflow.

The first Debian compact-logging smoke used Debian/HPP with 8 baseline files and one four-file incremental pass. All 12 files, including one modified baseline, matched the full and cumulative restore manifests. The detailed trace remained in `runs/<run-id>/logs/workflow.log`.

The final Debian compact-output smoke passed the all-in-one flow with four baseline files, two additions, and one modified baseline. Full and cumulative restore checks passed; normal terminal output was 24 lines, while the detailed trace remained in `runs/<run-id>/logs/workflow.log`. Its full backup `Done` reason carried a guest-freeze warning, so this restore proof does not establish quiesced consistency.
