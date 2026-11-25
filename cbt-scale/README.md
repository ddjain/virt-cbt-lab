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
| `win-workload-agent.sh` | sourced by `scale-driver2.sh`; Windows guest mutation via qemu-guest-agent (no SSH in the image) |
| `prom-sweep.sh <start-UTC> <end-UTC> [report.md]` | Layer-2 Prometheus sweep |
| `storage-snapshot.sh <label>` | append a ceph/PVC usage row to `storage.csv` |
| `scale-status.sh [pool] [interval]` | live read-only backup fleet status |
| `rbd-orphan-gc.sh [--pool P] [--delete]` | orphan RBD image report / GC for an ODF pool (default `ocs-storagecluster-cephblockpool`; destructive with `--delete`); image list from `rbd ls`, sizes from best-effort `rbd du` (a dangling-parent image makes `rbd du` exit 2); refuses while any PVC is Pending cluster-wide |
| `ns-wipe.sh --yes` | destructive namespace wipe; refuses without `--yes` |
| `backup-wipe.sh --yes` | fleet-safe backup-objects-only cleanup (all groups' vmbackups/trackers/backup PVCs+PVs, GC, finalizer escalation, full-OSD unblock); VMs/roots untouched; refuses without `--yes` |
| `lib-naming.sh` | sourced; the only place fleet group object names are built (`scale_full_name`, `scale_incr_name`, `scale_tracker_name`, `scale_group_object_regex`) |

Group object names: VM `vm-fleet-rhl-0001` in group `G` yields
`vm-backup-G-fleet-rhl-0001`, `vm-incremental-G-fleet-rhl-0001-p01`,
`vm-tracker-G-fleet-rhl-0001`. The driver, `fleet-e2e.sh` and `fleet-verify.sh`
all use `lib-naming.sh`; never build these names inline. `fleet-e2e.sh reset
<group>` deletes only objects matching that group's anchored names.

`ns-wipe.sh`, `backup-wipe.sh` and `rbd-orphan-gc.sh --delete` are destructive; do not run them
as tests. Offline checks: `bash tests/test-cbt-scale-tools.sh`,
`bash tests/test-fleet-naming.sh`, `bash tests/test-rbd-orphan-gc.sh`.

## Storage classes and durability

Backups and roots default to durable 3-copy ODF (`ocs-storagecluster-ceph-rbd`;
Windows roots `ocs-storagecluster-ceph-rbd-virtualization`). Override with
`RHEL_SC`/`WIN_SC` (fleet backups), `--backup-sc` (single-OS density drivers) or
`ROOT_SC` (roots; see `.env.example`). The replica-1 `cbt-scale-pool` was removed
on 2026-11-25: its CRUSH root (`default`) overlapped the ODF pools' `default~ssd`
root and disabled the PG autoscaler cluster-wide.

## Guest mutation transport

The driver's workload phases (A/C) mutate guests before backups: **rhel** VMs
over SSH through their `vm-ssh-<rid>` Services; **windows** VMs via the QEMU
guest-agent (`win-workload-agent.sh` runs PowerShell through
`virsh qemu-agent-command` inside the virt-launcher pod — the fleet Windows
images run no SSH server). Windows mutation requires the guest-agent connected
(`AgentConnected=True`); agent-less VMs also skip the backup freeze.
