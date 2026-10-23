# Scenario: EXP-9 — Windows coverage: node-io-hog during a full backup (CBT-F-09 cross-OS)

## 1. Identity

- **Experiment ID:** EXP-9 (user-mandated Windows coverage; cross-OS corroboration of the F-09 baseline)
- **Same mechanism as CBT-F-09** (krknctl node-io-hog on the HostPath pool path during the full-backup active copy, trigger on the compound active-copy condition), with `VM_OS=windows` (Windows Server 2022 golden image, guest-agent-based workload/mutation/restore verification).
- **v1 placement defect and its fix:** the archived run `20261014-exp09-r01` (v1 layout, `artifacts/CBT-EXP-09/`) was placement-INVALID: the stock Windows runtime manifests hardcoded Ceph RBD storage, so the Windows VM scheduled to `d39-h01-000-r660` while the hog ran on `d38-h18-000-r660` — no contention on the copy path. The v2 bundle moves the three Windows runtime manifests (`manifests/windows-vm.yaml`, `manifests/windows-full-backup.yaml`, `manifests/windows-incremental-backup.yaml`) to the HostPath pool (`cbt-demo-hpp`, Filesystem, explicit `nodeSelector` to `d38-h18-000-r660`), giving `MANIFEST_VARIANT=default` the same HostPath meaning it already has for every other OS profile. This deterministically co-locates the Windows VM, its root disk, and both backup destinations with the hog's node and `/dev/sdb` pool disk — the only cluster topology where the Jira target ("CBT storage filesystem on the worker node") is the node-local disk. Cross-volumeMode clone of the Block Ceph golden image to a Filesystem HPP root is host-assisted CDI clone (kubevirt content type both sides; HPP storage profile `cloneStrategy: copy`, verified live 2026-10-17); clone RBAC already exists.

## 2. Objective

Establish the Windows-side behavior of the I/O-contention baseline (duration degradation vs the RHEL baseline, correctness preservation) and collect the Judge-mandated ride-alongs on a Windows guest:
1. **Natural ghost-event rate** (high-cadence events watch): does the "VMI backup status was lost" transient fire with the Windows guest agent? (Localizes the propagation source; free finding either way. RHEL reference: 7/9 runs; v1 Windows run: 0/1.)
2. **Guest-unfreeze assertion**: post-backup guest-side write/read (agent exec) — closes the freeze-leak question EXP-2's VMI-level check couldn't.
3. **Destination-size sanity check** (backup duration vs target PVC usage growth vs workload): the proven-cheap silent-corruption discriminator (EXP-7 class).

## 3. Workflow
`make e2e TYPE=full`-equivalent stage sequence with `VM_OS=windows`, `MANIFEST_VARIANT=default` + a run-owned direct hostPath stress pod (user-directed iteration-3 mechanism change replacing krknctl node-io-hog, whose v0.14.2-beta silently ignores `--node-mount-path` — see `bugs/krknctl-node-io-hog-ignores-node-mount-path-writes-to-tmp-tmpfs.md`): same parameters as F-09 (8 workers × 2g × 1m, 90 s, node d38-h18-000-r660, pool path /mnt/local-storage/cbt-demo-local-pool), same compound active-copy trigger (3 s poll, 2400 s timeout, fail-closed), pinned krkn-hub workload image running stress-ng directly into a run-scoped subdirectory → planned incremental + restore verification. Observer watches backup/tracker/VMI/events/hog-pod; ride-along measurements extracted from the same streams + a post-run agent-exec write test.

One fresh Windows VM lifecycle in `vm-cbt-demo` (`VM_OS=windows`, `MANIFEST_VARIANT=default`, 1000-file 15–20 MiB baseline ≈ 17.4 GiB, 1 incremental pass, full inventory). The scenario entrypoint (`run.sh`) owns every stage; the Lead only starts it:

1. `make preflight VM_OS=windows` (read-only guards incl. pool/node/disk headroom).
2. Arm observers (backup/tracker/VMI/events/hog-pod watches), create the hog namespace, and start the run-owned direct trigger loop (`direct-trigger.sh`, compound active-copy condition, fail-closed) **before** `make vm-backup`; the stress pod is created only after the condition is satisfied.
3. `make vm-setup RUN_ID=<lifecycle>` (Windows boot+OOBE 10–15 min).
4. `make vm-backup RUN_ID=<lifecycle>` — the trigger opens the injection window during the active copy; hog runs 90 s.
5. Guest-unfreeze ride-along: agent-exec PowerShell write/read/hash of a fresh guest file after full Done.
6. `make vm-cbt-backup RUN_ID=<lifecycle>` (planned incremental pass).
7. `make vm-cbt-verify RUN_ID=<lifecycle>` (checkpoint chain + restore/hash verification).
8. `make run-summary` + `make monitor` timings; destination-usage measurement via read-only node-debug `du` of the full destination PV path.

Stress parameters identical to F-09: 8 workers × 2g × 1m block, 90 s duration, node `d38-h18-000-r660`, path `/mnt/local-storage/cbt-demo-local-pool` (run-scoped subdirectory); trigger poll 3 s, fail-closed on timeout; trigger timeout 2400 s for the slower Windows boot. Mechanism: run-owned privileged pod `hog-direct-<lifecycle>` in the hog namespace, pinned krkn-hub workload image `quay.io/krkn-chaos/krkn-hub-multiarch@sha256:9b2000bb…`, running `stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --timeout 90s`; pod self-exits, is deleted after terminal phase.

## 4. Measurements / classification

- Same criteria as F-09 (injection validity, Done/success/Full/one checkpoint, tracker advance, VM health, incremental+restore PASS) on Windows.
- Ghost-event presence/absence on the Windows run (vs 7/9 RHEL rate).
- Guest write/read success post-backup (unfreeze proof).
- Target-usage vs workload-size sanity (duration-vs-size plausibility).
- Duration degradation vs the ~49 s v1 Windows uncontended baseline and the 52–55 s RHEL baseline is an observation, not a pass criterion; correctness is the criterion (per F-09 §6).

## 5. Blast radius / safety

Identical to F-09 (single-node I/O pressure 90 s on `d38-h18-000-r660`/`/dev/sdb`, run-scoped; 16 GiB transient hog writes on a 1.4T-free disk). The HPP manifest change affects only future Windows runs created from this checkout (no existing Windows VMs in the cluster; the golden image DataSource and installer workflow are untouched). Serialize with other HPP-variant scenario runs. Windows setup is slower (~10–15 min boot + OOBE); total ~40–50 min including incremental + restore verification.

## 6. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-09/runs/<chaos-id>/`: driver/trigger logs, krknctl.log, hog-pod yaml + watch streams, full-backup/tracker snapshots, observer streams (backup/tracker/VMI/events for the ghost-event check), guest write-test output, destination-usage measurement, stage exit statuses, `injection-confirmation.json`, `analysis.json` (Analyst-owned), `run-report.md`. Lifecycle originals remain in repository-root `runs/<lifecycle-id>/`.
