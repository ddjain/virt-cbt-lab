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

## Phase 3 — Migrate this repo's demo workloads (complete, 2026-09-30)

Added an `odf` `MANIFEST_VARIANT` (`manifests/vm-odf.yaml`,
`manifests/full-backup-odf.yaml`, `manifests/incremental-backup-odf.yaml`)
pointing the root disk and both backup PVCs at `ocs-storagecluster-ceph-rbd`
instead of `cbt-demo-hpp`, and a `large-odf` variant combining that with the
existing `large` chaos-testing sizing. `MANIFEST_VARIANT=odf` is now the
default for `make e2e`; `default` (plain `cbt-demo-hpp`) remains available
for clusters without ODF. `README.md`, `docs/vm-cbt-workflow.md`, and
`.env.example` were updated alongside the manifests, and `./preflight`
checks for `ocs-storagecluster-ceph-rbd` when an `odf`/`large-odf` variant is
selected.

The ODF-backed PVCs are sized larger than their `cbt-demo-hpp` equivalents
(6Gi/6Gi/4Gi vs. 5Gi/5Gi/3Gi for the small variant; 48Gi/48Gi/30Gi vs.
40Gi/40Gi/25Gi for large) — found necessary by actually running
`make e2e MANIFEST_VARIANT=odf` against this cluster: CDI's clone-time
filesystem-overhead reservation inflates the root disk past its nominal
request, and Ceph RBD enforces PVC capacity strictly (unlike `cbt-demo-hpp`,
which silently tolerates the same overcommit), so a flat backup-target PVC
at the nominal size failed the full backup with
`Backup has failed: No space left on device`. All four variants
(`default`, `large`, `odf`, `large-odf`) were run end to end against
`cloud05` after the fix, including the restore-verification hash checks,
and passed. The existing single-node HPP pool is left untouched.

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
   **Resolved 2026-09-30: authorized and completed — see execution log.**
2. Whether to label all 18 new nodes for ODF immediately, or start with a
   smaller subset (e.g. 6–9) and expand the `StorageCluster` device sets
   incrementally. **Resolved 2026-09-30: label all 18 new nodes now.**
3. Whether to also convert the existing 10 workers' spare disks (9 of them
   have 2× 1.49 TiB + NVMe completely unused today, and `d38-h18` has 1
   disk already consumed by the existing HPP pool) into the same ODF pool,
   or keep the initial ODF deployment scoped to only the 18 new nodes.
   **Resolved 2026-09-30: scope initial ODF deployment to the 18 new nodes
   only; existing 10 workers stay untouched.**

## Execution log

All commands below were run against the `cloud05` bastion
(`ssh cloud05`, `/root/openshift-cluster/jetlag`, `KUBECONFIG=/root/mno/kubeconfig`).

### Phase 1 — day-2 worker scale-out (2026-09-30)

1. Edited `ansible/vars/all.yml`: `worker_node_count: 10` → `28`.
2. Created `ansible/vars/scale_out.yml`:
   ```yaml
   current_worker_count: 10
   scale_out_count: 18
   ```
3. Backed up the existing inventory, then regenerated it:
   ```sh
   cp ansible/inventory/cloud05.local ansible/inventory/cloud05.local.bak-preso-scaleout-<timestamp>
   ansible-playbook -i ansible/inventory/cloud05.local ansible/create-inventory.yml
   ```
   Verified via `ansible-inventory --graph` and `diff` against the backup:
   `[worker]` group grew from 10 to 28 entries, only new entries appended,
   each with valid `install_disk`/`mac_address`/`ip`.
4. `ansible-playbook --syntax-check ansible/ocp-scale-out.yml` — passed.
5. Ran the scale-out playbook detached in `tmux` (session `ocp-scale-out`,
   log `scale-out-run.log`):
   ```sh
   ansible-playbook -i ansible/inventory/cloud05.local ansible/ocp-scale-out.yml
   ```
   - **First attempt failed** before any host was touched: the
     `ocp-scale-out` role hardcoded `dest: /opt/http_store/data/...`
     instead of using the `http_store_path` variable every other role in
     this codebase uses (which resolves to the real path,
     `/opt/jetlag/http_store`). Fixed in
     `ansible/roles/ocp-scale-out/tasks/main.yml`:
     `dest: "{{ http_store_path }}/data/ocp-scale-out.x86_64.iso"`.
   - **Second attempt failed** (still before any host was touched):
     `http_store_path` was undefined in this role's context — it's only
     defined as a default in the `bastion-http` role, which
     `ocp-scale-out.yml` doesn't include. Fixed by adding
     `http_store_path: /opt/jetlag/http_store` to
     `ansible/roles/ocp-scale-out/defaults/main.yml`.
   - **Third attempt succeeded**: `EXIT:0`, `failed=0`. All 18 new hosts
     were BMC-booted off the generated discovery ISO one at a time,
     installed RHCOS, and joined the cluster with CSRs auto-approved by
     the playbook's own retry loop, in well under 20 minutes end to end.
6. Verified: `oc get nodes -o wide` — 31 total nodes (3 control-plane + 28
   workers), all `Ready`.

### Phase 2 — ODF deployment (in progress, 2026-09-30)

1. Labeled all 18 new worker nodes:
   ```sh
   for n in d39-h09-000-r660 ... d40-h06-000-r660; do
     oc label node "$n" cluster.ocs.openshift.io/openshift-storage="" --overwrite
   done
   ```
   Verified: `oc get nodes -l cluster.ocs.openshift.io/openshift-storage=`
   returns 18 nodes.

2. Installed `odf-operator` via `oc apply` of a namespace + `OperatorGroup`
   + `Subscription` manifest (channel `stable-4.22`, source
   `redhat-operators` — matches cluster OCP 4.22.15):
   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: openshift-storage
     labels:
       openshift.io/cluster-monitoring: "true"
   ---
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     name: openshift-storage-operatorgroup
     namespace: openshift-storage
   spec:
     targetNamespaces:
     - openshift-storage
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: odf-operator
     namespace: openshift-storage
   spec:
     channel: stable-4.22
     name: odf-operator
     source: redhat-operators
     sourceNamespace: openshift-marketplace
   ```
   OLM auto-installed the full dependency set (12 CSVs, all `Succeeded`
   within ~2 minutes): `odf-operator`, `odf-dependencies`, `ocs-operator`,
   `ocs-client-operator`, `rook-ceph-operator`, `mcg-operator`,
   `cephcsi-operator`, `odf-csi-addons-operator`,
   `odf-external-snapshotter-operator`, `odf-prometheus-operator`,
   `ocs-tls-profiles`, `recipe` — all at `4.22.5-rhodf`.

3. Disk discovery:
   - Applied a `LocalVolumeDiscovery` scoped to the 18 labeled nodes via
     `nodeSelector` on `cluster.ocs.openshift.io/openshift-storage`. It sat
     idle (CRD present, no controller) because **`local-storage-operator`
     was not yet installed** — ODF 4.22 does not bundle it automatically.
     Installed it separately (`Subscription`, channel `stable`, source
     `redhat-operators`); CSV `local-storage-operator.v4.22.0-202609212027`
     reached `Succeeded`, after which the discovery daemonset
     (`diskmaker-discovery`) came up on all 18 nodes and produced 18
     `LocalVolumeDiscoveryResult` objects.
   - Confirmed the plan's device-letter-irregularity concern directly:
     `d40-h01-000-r660`'s OS disk is `sdb` (not `sda`, unlike most other
     nodes), and LSO's discovery correctly marked it `NotAvailable`
     (partitioned/mounted) while flagging `sda`, `sdc`, and `nvme0n1` as
     `Available` — i.e. LSO's availability check already handles the
     device-letter irregularity; the important part is to select on
     size/type, never a device-name allowlist.
   - Applied a `LocalVolumeSet` (`odf-local-block`, storage class
     `localblock`) using `deviceInclusionSpec.minSize: 1000Gi` +
     `deviceMechanicalProperties: [NonRotational]` to select only the two
     1.49 TiB disks and the NVMe per node, safely excluding the 446 GiB OS
     disk everywhere regardless of its letter.
   - Result: 54 `Available` PVs (18 nodes × 3 disks) — 36 × 1489Gi + 18 ×
     2980Gi, matching the expected raw layout exactly.

4. Applied the `StorageCluster` CR (`ocs-storagecluster`), single device
   set `ocs-deviceset-localblock`, `count: 54`, `replica: 1`,
   `portable: false`, `storageClassName: localblock`.
   - 22 of the 54 `rook-ceph-osd-prepare` jobs failed immediately with
     `failed to get device already provisioned by ceph-volume raw: osd.N:
     "<uuid>" belonging to a different ceph cluster "<foreign-fsid>"` —
     stale Ceph OSD signatures left on these disks from a prior, unrelated
     Ceph cluster (this hardware was reallocated to `cloud05` by QUADS; the
     leftover data predates this allocation). Confirmed via
     `ceph-volume raw list` and manual `wipefs`/`sgdisk --zap-all`/`dd`
     wiping of the 22 specific devices, though the manual approach also
     surfaced a separate kubelet-level complication: raw-block local PVs
     are bind-mounted into pods via loop devices, and the loop device
     backing a given PVC is not automatically recreated across job pod
     retries, so a manually wiped disk could still appear "stale" to a
     retried prepare pod until its loop device was explicitly detached
     (`losetup -d`) and remounted fresh.
   - **The correct, documented fix** (found in
     `virt-cbt/docs/odf/ODF-SETUP.md`, from a prior successful ODF
     deployment on different hardware that hit this exact same failure
     mode) is a `StorageCluster` cleanup-policy flag instead of manual
     device wiping:
     ```sh
     oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge \
       -p '{"spec":{"managedResources":{"cephCluster":{"cleanupPolicy":{"wipeDevicesFromOtherClusters":true}}}}}'
     ```
     After applying this and letting the operator reconcile (it recreated
     the failed prepare jobs on its own; no manual job deletion was
     needed), all 22 previously-blocked devices wiped and provisioned
     cleanly through the operator's own path.
   - **Destructive-operation note:** this flag authorizes Ceph to wipe any
     device carrying a foreign cluster's OSD signature. Only acceptable
     here because the 18 nodes are freshly QUADS-reallocated spares with no
     known current legitimate owner of that leftover data — confirmed with
     the user before applying. Do not enable this flag on a cluster where
     device provenance is uncertain without the same explicit confirmation.
   - End state: `CephCluster` `Ready`/`HEALTH_OK`, all 54 OSDs `up`/`in`,
     `StorageCluster` `Ready`. `ceph -s` / `ceph df`:
     - `105 TiB` raw available (projection: ~106 TB for 18 nodes).
     - `30 TiB` MAX AVAIL per pool at replica-3 (projection: ~35 TB usable
       for 18 nodes — close match, delta is normal Ceph/replication
       overhead).
     - Storage classes present: `ocs-storagecluster-ceph-rbd`,
       `ocs-storagecluster-ceph-rbd-virtualization`,
       `ocs-storagecluster-cephfs`, `ocs-storagecluster-ceph-rgw`.
     - Ceph toolbox enabled via
       `oc patch ocsinitialization ocsinit -n openshift-storage --type json
       --patch '[{"op":"add","path":"/spec/enableCephTools","value":true}]'`
       (note: object name is `ocsinit`, not `ocs-storagecluster`).

Phase 2 is complete. Phase 3 (migrating `cbt-setup`'s demo `DataVolume`/
`VirtualMachine` manifests to `ocs-storagecluster-ceph-rbd`) is also
complete — see the Phase 3 section above — and `odf` is now the default
`MANIFEST_VARIANT`. The existing HPP pool is left untouched.
