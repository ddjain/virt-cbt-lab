# ODF (OpenShift Data Foundation) setup plan — cloud05

Planning document only. No BMC boot, node scale-out, or ODF install has been
run against `cloud05` as of this writing. Every phase below that mutates
cluster or host state requires explicit user confirmation before execution,
per the Scale Lab PXE/BMC policy already in force for this environment.

This plan is separate from the `cbt-setup` CBT demo workflow itself
(`make e2e`, `scripts/*.sh`); it documents cluster-level storage capacity
planning for the underlying OpenShift/KubeVirt cluster that the demo runs
against. Cluster access details (kubeconfig path, bastion SSH) live outside
this repo per its `.gitignore`/secret-handling rules — see the `virt-cbt`
project's `cloud5/` inventory and deployment docs for the source hardware
and Jetlag deployment records this plan is based on.

## Goal

Provision pooled, replicated block storage (ODF/Ceph) across cloud05's spare
hardware to back KubeVirt VM disks, replacing the current single-node
hostpath-provisioner (HPP) setup used by this repo's CBT demo
(`cbt-demo-hpp` / `cbt-demo-local-pool` storage classes), and to support
scaling toward ~100+ small VMs with headroom for growth.

## Starting point — corrected fleet inventory

The cloud05 QUADS allocation is 32 Dell R660 nodes total.

| Role | Nodes | Count |
|---|---|---|
| Bastion (Assisted Installer, DNS, HAProxy — not reusable for workloads) | `d38-h06-000-r660` | 1 |
| Control plane | `d38-h07-000-r660`, `d38-h08-000-r660`, `d38-h09-000-r660` | 3 |
| Existing OCP workers | `d38-h18-000-r660`, `d38-h19-000-r660`, `d39-h01`–`d39-h08-000-r660` | 10 |
| **Unused / available to add as workers** | `d39-h09`–`d39-h20-000-r660` (12) + `d40-h01`–`d40-h06-000-r660` (6) | **18** |

An earlier planning pass assumed 19 unused nodes (32 − 3 masters − 10
workers); that omitted the bastion, which is also carved out of the pool.
The correct spare count is **18**.

All 32 hosts are Dell PowerEdge R660, confirmed identical:

- CPU: Intel Xeon Gold 5420+, 2 sockets × 28 cores × 2 threads = 56
  cores / 112 logical CPUs
- Memory: ~502.9 GiB observed
- Disks: one 446.62 GiB RAID logical device (OS/boot, device letter varies
  by host), two 1,489.88 GiB RAID logical devices, one `nvme0n1` at
  2,980.82 GiB (3.2 TB marketed)
- The RAID logical devices are presented by the PERC/SAS controller as
  single-disk RAID volumes (no HBA passthrough available); this is a normal,
  supported pattern for Rook/Ceph via Local Storage Operator (LSO) discovery,
  not a blocker.

Cluster is OpenShift 4.22.15, deployed via Jetlag on the `cloud05` bastion,
kubeconfig at `/root/mno/kubeconfig` on that host.

## Current storage in this repo's demo (for contrast)

`cbt-demo-hpp` / `cbt-demo-local-pool` (see the `HostPathProvisioner` CR)
are pinned to a single node (`d38-h18-000-r660`) and a single 1.5 TB disk,
of which ~1.4 TB is currently free. This is a hard bottleneck for any
scale-out beyond the current demo scope: all HPP-backed volumes are
node-local, not pooled, and cannot survive that node's loss. ODF replaces
this with pooled, replicated, multi-node storage.

## Capacity projection

Raw disk per node available for OSDs (excluding OS RAID disk): 2× 1.49 TiB
+ 1× 2.98 TiB ≈ **5.9 TB/node**.

| Worker pool | Nodes | Raw capacity | Usable @ replica-3 | Safe practical (~75% fill) |
|---|---|---|---|---|
| Current only | 10 | ~59 TB | ~19.7 TB | ~14.8 TB |
| Current + all 18 new | 28 | ~165 TB | ~55 TB | ~41 TB |

Replica-3 is the only Red Hat-supported redundancy level for production ODF
and is the assumed target throughout this plan. Replica-2 and replica-1 were
evaluated and rejected (replica-2 unsupported, has a real data-loss window
during recovery/scrubbing; replica-1 has no redundancy at all).

### Fit against the actual workload (small VMs)

| VM disk size | 100 VMs | 500 VMs | 1000 VMs |
|---|---|---|---|
| 20 Gi | 2 TB | 10 TB | 20 TB |
| 40 Gi | 4 TB | 20 TB | 40 TB |

At the confirmed small-VM sizing (~40 Gi/VM), even 1000 VMs (~40 TB) sits at
the edge of the ~41 TB safe practical capacity from the 28-node pool — the
100-VM target uses under 10% of it. The 18-node addition is not required to
hit the 100-VM goal on its own (the existing 10 workers, ~14.8 TB safe
usable, already cover it), but it is planned anyway for redundancy headroom,
future growth, and to spread OSDs/failure domains across more nodes.

## Phase 1 — Add the 18 spare nodes as day-2 OCP workers

Jetlag (the tool used for the original cluster install) has a built-in
day-2 scale-out path (`ansible/ocp-scale-out.yml`); no reinstall or new
tooling is needed.

1. In Jetlag's `ansible/vars/all.yml` on the bastion, bump `worker_node_count`
   from `10` to `28`. Leave `ocp_inventory_override` unchanged — it already
   resolves the full 32-node QUADS-ordered host list, so the 18 new hosts
   slot in immediately after the current 10 workers.
2. Regenerate the inventory with `ansible-playbook ansible/create-inventory.yml`
   and confirm via `ansible-inventory --graph` that the `[worker]` group now
   lists 28 hosts with correct `install_disk`, `mac_address`, and `ip`
   values (expected to continue the existing `198.18.0.x` sequence).
3. Create `ansible/vars/scale_out.yml`:
   ```yaml
   current_worker_count: 10
   scale_out_count: 18
   ```
4. Syntax-check: `ansible-playbook --syntax-check ansible/ocp-scale-out.yml`.
5. Run `ansible-playbook ansible/ocp-scale-out.yml` (detached, e.g. in
   `tmux`, same pattern as the original install). This performs, per new
   node: `oc adm node-image create` (native OCP day-2 discovery ISO) →
   a **one-time BMC virtual-media boot** (`BootOnce=Enabled`,
   `FirstBootDevice=VCD-DVD` — the same mechanism used for the original
   13-node install, not a persistent boot-order change, does not touch
   Foreman/Lab PXE) → auto-approval of the joining node CSRs.
6. Verify with `oc get nodes -o wide`: expect 31 total nodes (3
   control-plane + 28 worker), all `Ready`.

**Gate:** step 5 performs a real BMC/boot action on 18 physical hosts. Do
not run it without explicit, separate user authorization at that point —
approving this overall plan is not sufficient authorization for the boot
step itself.

## Phase 2 — Deploy ODF

Jetlag's local-storage/LSO options are install-time-only ignition
configuration for the *original* cluster build (disk wiping/partitioning at
first boot) — they don't apply to already-installed nodes and aren't
ODF/Ceph. ODF is installed here as a standard day-2 operator, independent of
Jetlag.

1. Label the target worker nodes (18 new, or all 28):
   `oc label node <node> cluster.ocs.openshift.io/openshift-storage=""`.
2. Install the `odf-operator` (pulls in `ocs-operator`, `rook-ceph`,
   `mcg-operator`) via `Subscription` in the `openshift-storage` namespace.
3. Discover local disks with `LocalVolumeDiscovery` + `LocalVolumeSet` (or
   ODF's built-in device-discovery flow), targeting the two 1.49 TiB disks
   and the NVMe disk on the labeled nodes. **Device letters are not uniform
   across nodes** (e.g. one known host has its OS disk on `sdc` instead of
   `sda`) — the discovery/selector must use by-path or by-serial
   identifiers, not a blanket device-name list, to avoid accidentally
   targeting an OS disk on a subset of nodes.
4. Create the `StorageCluster` CR:
   - `replica: 3` (all pools)
   - Device sets sized to the discovered local PVs (up to 3 OSD-eligible
     disks per node × number of labeled nodes)
   - No taint by default (hyperconverged: these nodes also run VM/pod
     workloads) — see the operational note below on this choice.
5. Validate: `oc get storagecluster -n openshift-storage`,
   `oc get cephcluster -n openshift-storage`,
   `oc get storageclass | grep ocs-storagecluster`, and via the Ceph
   toolbox pod, `ceph -s` / `ceph df`. Confirm `Ready`/`HEALTH_OK` and that
   reported raw/usable capacity matches the projection above (pro-rated
   down if starting with fewer labeled nodes).

## Phase 3 — Migrate this repo's demo workloads (optional, later)

Point new `DataVolume`/`VirtualMachine` manifests (`manifests/vm.yaml`,
`manifests/full-backup.yaml`, `manifests/incremental-backup.yaml`) at the
new `ocs-storagecluster-ceph-rbd` StorageClass instead of `cbt-demo-hpp`.
This is a coordinated migration per this repo's change rules (the fixed
resource contract), not a drop-in swap — update `README.md` and
`docs/vm-cbt-workflow.md` alongside any manifest change, and add any new
environment variable to `.env.example`. Leave the existing single-node HPP
pool running untouched until ODF is validated in production use.

## Operational notes and decisions carried from planning discussion

- **Hyperconverged, not dedicated storage nodes.** ODF nodes will also run
  VM/pod workloads by default (no storage taint). This is a supported
  pattern, not a hack, but Ceph OSD recovery/rebalancing after a disk or
  node failure causes CPU/network spikes that can transiently affect VM I/O
  latency on the same (and, since Ceph is shared storage, potentially other)
  nodes. If that's observed in practice, the fix is a config change (add
  the storage taint/label to dedicate some or all of these nodes), not a
  rebuild.
- **Do not add the 3 control-plane nodes to the storage pool.** Their disks
  are physically identical and unused, but etcd on these nodes is highly
  latency-sensitive; Ceph OSD contention risks destabilizing the control
  plane for a marginal capacity gain (+~17.7 TB raw / +~6 TB usable at
  replica-3) that isn't needed for this workload.
- **Replica-3 only.** Replica-2 is not Red Hat-supported for production and
  has a known data-loss window during recovery; replica-1 has no redundancy
  at all. Neither is worth the capacity gain given the workload only needs
  a small fraction of the replica-3 usable capacity.
- **150 TB usable is not achievable on this 32-node fleet** at any
  supported redundancy level (would require ~600 TB raw at replica-3, versus
  the ~165–188 TB raw ceiling even using every non-bastion node including
  control planes). If that target is still live, it requires additional
  hardware beyond this allocation — not a different configuration of the
  existing 32 nodes.
- **Confirmed workload fit:** actual plan is small VMs (~40 Gi/VM). 100 VMs
  ≈ 4 TB, comfortably inside even the 10-node-only usable capacity
  (~19.7 TB). The 18-node scale-out is for headroom/resilience/failure-domain
  spread, not because the 100-VM target requires it.

## Open items requiring explicit confirmation before execution

1. Authorization to run Phase 1 step 5 (the 18-host BMC virtual-media boot).
2. Whether to label all 18 new nodes for ODF immediately, or start with a
   smaller subset (e.g. 6–9) and expand the `StorageCluster` device sets
   incrementally.
3. Whether to also convert the existing 10 workers' spare disks (9 of them
   have 2× 1.49 TiB + NVMe completely unused today, and `d38-h18` has 1
   disk already consumed by the existing HPP pool) into the same ODF pool,
   or keep the initial ODF deployment scoped to only the 18 new nodes.
