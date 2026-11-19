# cbt-scale — scale-and-chaos fleet tooling

Tracked tooling for running CBT backups across many VMs (fleet registry,
parallel backup driver, verification, storage and Prometheus sweeps). It is the
code behind the `cbt-scale-chaos` skill. Run everything from any directory; the
scripts resolve the repo root themselves.

**Code vs state:** code lives here (tracked). Runtime state and evidence go to
`SCALE_STATE_DIR` (default `<repo>/artifacts`, gitignored): `fleet.yaml`,
`groups/<group-id>/`, `density-scale-<pool>/`, `fleet-setup|extend-*.log`,
`storage-200b.csv`. Never commit state.

## Prerequisites

`oc`, `jq`, `make`, `kube-burner`, `KUBECONFIG` exported, a populated `.env`
(see `.env.example`), and a golden image per OS (`make rhel-light-golden` once
for `rhel9-light`).

## Entry points

| Script | Purpose |
|---|---|
| `fleet-e2e.sh fleet-setup\|extend\|run\|reset` | persistent mixed-OS fleet (`--rhel N --rhel-light K --windows M`); skill entry point |
| `fleet-verify.sh <group-id> [start-UTC] [end-UTC]` | Layer-1 verification + `run-report.md` for a group run |
| `density-e2e.sh --os rhel9\|rhel9-light\|windows --count N` | throwaway single-OS pool wave (also `--mixed`) |
| `density-e2e-mixed.sh` | throwaway rhel9+windows wave (dispatched by `density-e2e.sh --mixed`) |
| `density-scale-test.sh [N] [VM_OS]` | interactive wrapper (asks before cleaning) |
| `scale-driver2.sh <pool> <start> <end> [wave]` | poll-based driver, phases A-D; also group mode via `GROUP_FILE`+`GROUP_ID` |
| `prom-sweep.sh <start-UTC> <end-UTC> [report.md]` | Layer-2 Prometheus sweep |
| `storage-snapshot.sh <label>` | append a ceph/PVC usage row to `storage-200b.csv` |
| `scale-status.sh [pool] [interval]` | live read-only backup fleet status |
| `scale-pool-gc.sh [--delete]` | orphan RBD image report / GC (destructive with `--delete`) |
| `ns-wipe.sh --yes` | destructive namespace wipe; refuses without `--yes` |

`ns-wipe.sh` and `scale-pool-gc.sh --delete` are destructive; do not run them
as tests. Offline checks: `bash tests/test-cbt-scale-tools.sh`.

## Storage classes and durability

Backups always default to the replica-1 `cbt-scale-pool` (test data only).
Root disks default to durable 3-copy ODF; set `ROOT_SC=cbt-scale-pool` (env,
see `.env.example`) at `fleet-setup`/`fleet-extend`/`make density-setup` time
for fully 1-copy fleets (~3x less raw per root). Cross-pool CDI clone from
the `rhel9-light` and `windows-server-2022` golden DataSources verified
2026-11-19 (full+incremental backups PASS on both OSes with 1-copy roots;
CNV's per-VM `persistent-state` PVCs stay on the profile default — moving
those is a cluster-wide change, not per-fleet).
