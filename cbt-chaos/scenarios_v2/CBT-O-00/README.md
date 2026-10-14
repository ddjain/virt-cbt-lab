# CBT-O family — ODF/RBD-backed CBT backup chaos scenarios (campaign-authored)

Extends `scenarios_v2` with a 12-scenario family targeting the **ODF/Ceph RBD
backend** (`ocs-storagecluster-ceph-rbd`) instead of the HostPath pool. Every
prior family ran on `MANIFEST_VARIANT=default` (HPP); the O-family runs
`MANIFEST_VARIANT=odf` with `VM_OS=rhel9` (maps to the large-odf sizing: 80Gi
root/full disks, 30Gi incremental PVCs per `scripts/common.sh`), keeping the
campaign workload standard: 1000 × 15–20MiB files, `RUN_ID` form
`2026XXXX-cbtoNN-rNN`.

## 1. The golden-rebuild prerequisite (O-01 — run FIRST, always)

The RHEL9 golden PVC (`rhel9-7005186c23b8` in `openshift-virtualization-os-images`)
lives on `cbt-demo-hpp`; CDI cannot smart-clone cross-storage-class
(campaign learning #79: the DV clone hangs Pending forever with
`ProvisioningFailed/IncompatibleProvisioners`). Windows golden
(`vm-cbt-images/windows-golden`) is already on RBD. **Every O-scenario's trigger
guard therefore checks for an RBD-backed rhel9 DataSource before launching.**

The rebuild is a one-time (~30 min) managed-resource change. The exact recipe,
validated against the live cluster (2026-10-14):

**Live cross-check (2026-10-14):** the running `vm-odfrhel40a-*` density VMs clone
FROM the HPP-backed rhel9 DataSource INTO 80Gi RBD DataVolumes and complete with
`cdi.kubevirt.io/cloneType: copy` — CDI's copy-clone path crosses storage classes
fine when the destination StorageProfile declares cloneStrategy "copy". Learning
#79's blocker is specific to the smart-clone expectation; the registry-source
recipe below is belt-and-braces (no dependence on the HPP source PVC at all).


```bash
export KUBECONFIG=/root/mno/kubeconfig
GOLDEN_NS=openshift-virtualization-os-images
TOOLBOX=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name | head -1)

# 1. Resolve the exact source image the cron imports (imageStream tag digest).
oc get imagestream rhel9-guest -n $GOLDEN_NS \
  -o jsonpath='{.status.tags[?(@.tag=="latest")].items[0].dockerImageReference}'

# 2. Stand up a fresh 30Gi RBD DataVolume from that image (copy-clone cross-class
#    IS supported when the DESTINATION is on RBD — StorageProfile cloneStrategy
#    "copy"; the unsupported direction is cloning FROM an HPP source INTO a
#    smart-clone-expected RBD DV, which the explicit registry source sidesteps).
oc apply -f - <<'EOF'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel9-rbd-golden
  namespace: openshift-virtualization-os-images
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  source:
    registry:
      url: docker://registry.redhat.io/rhel9/rhel-guest-image@sha256:7005186c23b8f9bcaf7b068dc99b88e0fc33d54e4073c494f547c55835256374
      pullMethod: node
  storage:
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 30Gi
    storageClassName: ocs-storagecluster-ceph-rbd
    volumeMode: Filesystem
EOF
oc wait dv/rhel9-rbd-golden -n $GOLDEN_NS --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m

# 3. Publish an RBD-backed DataSource (leave the HPP-backed `rhel9` DataSource
#    untouched so HPP-family reruns keep working).
oc apply -f - <<'EOF'
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: rhel9-rbd
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      name: rhel9-rbd-golden
      namespace: openshift-virtualization-os-images
EOF
```

Then launch O-runs with `VM_DATA_SOURCE_NAME=rhel9-rbd` (the harness reads it
from `common.sh`'s rhel9 profile; export it per-run — see O-01's trigger). The
existing `os-images.kubevirt.io:view` RoleBinding in the golden namespace
already grants `system:serviceaccounts` the clone-source read verbs, and the
kubeconfig can create DataVolumes/DataSources there (all `oc auth can-i` checks
passed 2026-10-14), so no RBAC additions are needed.

## 2. The ODF differential attack surface (vs HPP)

On HPP, the backup copy is two node-local file reads/writes — which is why the
campaign proved it survives total pod AND host-netns network blackouts,
kubelet restarts, and full CPU/memory saturation. On RBD the topology changes
decisively:

| Dimension | HPP (proven) | ODF/RBD (to test) |
|---|---|---|
| Copy data path | QEMU read + write to a local filesystem — **no network** | QEMU local read + **kernel RBD client writes to OSDs over the pod network** (msgr2, ports 6800-6803 range) |
| Host-netns blackout | Copy survives (X-03) | **Copy should STALL** — the write path leaves the node |
| Pod-netns block on launcher | No effect (X-03) | Expected no effect (client is host-netns csi-rbdplugin, hostNetwork=true) |
| Storage access component | hostpath-provisioner CSI pod (F-07: copy survives its deletion) | csi-rbdplugin node DaemonSet pod — but once mapped, the kernel RBD device survives plugin pod death; the plugin matters for ATTACH/DETACH only |
| Capacity | Local disk fill (F-08/I-05/T-04) | Ceph pool quota (`ceph osd pool set-quota`) — pool is 105TiB at 0.9% used, so naive fill is infeasible; quotas are the only sane lever |
| Data-plane redundancy | none (single disk) | 54 OSDs, size=3 replication — kills degrade/slow rather than fail, until a placement-group quorum edge |
| New failure surfaces | — | mon quorum, mgr, rook operator, OSD-node memory pressure, in-ceph client contention |

Key pinned facts (live-verified 2026-10-14):
- csi-rbdplugin nodeplugin DS: `hostNetwork: true`, `hostPID: true`, label
  `app=openshift-storage.rbd.csi.ceph.com-nodeplugin` — so the RBD client
  sockets live in the HOST netns; a pod-netns filter on the launcher cannot
  touch the copy, but a host-netns (node_network_filter) block on the VM's node
  with explicit OSD/mon ports CAN.
- Ceph msgr2 (`requireMsgr2: true`): mons on 3300/tcp (ClusterIPs
  172.30.50.8, 172.30.192.131, 172.30.245.152), OSDs bind 6800-6803 v2/v1
  on pod IPs routed via the node's `ovn-k8s-mp0` interface.
- RWO dest is exclusively attached to `hp-volume-*` during the whole copy
  (I-05 r01) — no concurrent pod can touch the destination; capacity chaos
  must be pre-fill or ceph-side.
- Storage nodes: label `cluster.ocs.openshift.io/openshift-storage` (value
  empty), NO `node.ocs.openshift.io/storage` taint on this cluster — helper
  pods scheduling onto OSD nodes need no toleration.

## 3. Ordering / dependencies

```
O-01 (golden rebuild + baseline lifecycle)  ← prerequisite for ALL
  ├─ O-02 node-plugin kill        O-03 ctrl-plugin kill      (independent)
  ├─ O-04 host-netns OSD blackout O-05 storage-path latency  (independent)
  ├─ O-06 OSD kill sweep          O-07 mon/mgr kill          (independent)
  ├─ O-08 pool-quota ENOSPC       O-09 rbd volume ENOSPC     (independent; both end with quota/filler cleanup)
  ├─ O-10 in-ceph I/O contention  O-11 rook operator kill    (independent)
  └─ O-12 combined OSD-kill + contention (run LAST — attributes combined failures)
```

O-01 gates the family. O-08/O-09 mutate ceph pool state and must verify
cleanup before any other scenario runs (their triggers remove the quota /
filler in a trap). O-12 is designed to reuse O-06's and O-10's no-effect and
degradation data points, so run it after both have a recorded threshold.

## 4. Sweep philosophy

Same rules as the T-family: single-variable legs, ≤3 variants per scenario
per campaign budget, fresh RUN_ID per leg, stop at first degradation/failure.
Every jira's "Sweep / combination matrix" section lists the concrete values.
Sweeps that terminate below degradation are valid results (a measured
no-effect ceiling — the T-01/T-02 precedent), not wasted legs.

## 5. krkn usage rules (carry over + ODF-specific)

All of `krknctl-bugs.md` applies. ODF-specific additions:
- NEVER `ports: []` (bug #11 — node-destructive). The O-04 blackout uses
  `node_network_filter` with the EXPLICIT port list [3300, 6800, 6801, 6802,
  6803] and `interfaces: [ovn-k8s-mp0]` — on the VM's node only, never on an
  OSD/mon node (that would risk mon quorum + eviction storms).
- Where krknctl cannot express the target (pod-scenarios has no
  per-node+name-pattern AND, network_ng needs the `target` field), use the
  F-12/X-03-validated direct-krkn pattern: `podman run
  quay.io/krkn-chaos/krkn:latest` + `python3.11 run_kraken.py` + hand-written
  list-of-configs YAML + mounted work dir (`:Z`).
- Hog images need the writable-workdir workaround (bugs #1/#10): direct pod,
  copy `/stress-ng/.` to an emptyDir `/work`.
- Post-chaos connectivity check on every network-filter target (bug #7 leak).
