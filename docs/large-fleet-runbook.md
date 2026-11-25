# Large-Scale VM Fleet Runbook (1000+ VMs, RHEL + Windows)

How to spin up and operate a 1000+1000 VM fleet for parallel CBT backup
testing on the cloud05 cluster, using the tracked density/fleet tooling.
Written from the measured 2026-11-22/23 build (2000 VMs: 1000 rhel9-light +
1000 windows). Read fully before any large build — every step below exists
because something broke without it.

Cluster context: OpenShift 4.22 (OCS 4.22.15, CNV), checkout
`/root/v2/virt-cbt-lab`, `export KUBECONFIG=/root/mno/kubeconfig`. For the
root-cause analysis of the failures that produced this runbook, see
`artifacts/scale-build-findings-2026-11-23.md` (gitignored evidence tree).

## Overview: the working sequence

```
0. (once) Raise CSI grpcTimeout on the RBD Driver CR
1. Create goldens in vm-cbt-demo via CDI DataVolume  ── and VERIFY DATA
2. Build the fleet in batched PVC waves (DENSITY_PVC_BATCH=100)
3. Repair stragglers (wave-fill) and confirm >=95% ready per family
4. SSH smoke test a VM (never launch backups without it)
5. PARALLEL_OS=true fleet-e2e.sh run ... --wave 500
```

## Step 0 — one-time cluster tuning

```sh
# Clones slower than the default 150s gRPC deadline used to fail with
# DeadlineExceeded and retry-storm through the throttled provisioner.
oc patch driver.csi.ceph.io openshift-storage.rbd.csi.ceph.com -n openshift-storage \
  --type=merge -p '{"spec":{"grpcTimeout":600}}'
```

Background: the csi-provisioner sidecar self-throttles at kube-api-qps=5
(client-go default; not exposable through the ceph-csi-operator `Driver` CR —
its schema has no sidecar args passthrough, unlike rook <=1.19's KubeApiQPS).
The structural mitigation is keeping concurrent clones low (step 2 batching);
the timeout raise turns would-be retry storms into slow successes. The
`Driver` CR is owned by the ODF operator chain — re-check the value after
ODF upgrades.

## Step 1 — goldens: create and VERIFY DATA

Goldens are same-namespace PVCs in `vm-cbt-demo` that per-VM root disks clone
from (`dataSource: {kind: PersistentVolumeClaim, name: golden-<os>}` — no
CDI in the per-VM hot path):

| Golden | Size | volumeMode | StorageClass |
|---|---|---|---|
| `golden-rhel9-light` | 11Gi | Filesystem | `ocs-storagecluster-ceph-rbd` |
| `golden-windows` | 40Gi | Block | `ocs-storagecluster-ceph-rbd-virtualization` |

Create via **CDI DataVolume cross-namespace clone** (source = the golden PVCs
behind the `vm-cbt-images` DataSources):

```sh
cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: golden-rhel9-light
  namespace: vm-cbt-demo
  labels: {virt-cbt-lab/golden: "true"}
spec:
  source:
    pvc: {namespace: vm-cbt-images, name: rhel9-light-golden}
  pvc:
    accessModes: [ReadWriteOnce]
    volumeMode: Filesystem
    storageClassName: ocs-storagecluster-ceph-rbd
    resources: {requests: {storage: 11Gi}}
EOF
# windows: name golden-windows, source windows-golden, volumeMode Block,
#   storageClassName ocs-storagecluster-ceph-rbd-virtualization, 40Gi.
# Wait for Succeeded (~60s): oc get dv golden-rhel9-light -n vm-cbt-demo
```

**Verify the data — this step is mandatory.** `rbd du` on a cloned image
head reports 0 B (the data lives in the clone-parent chain); the only
reliable check is mounting the golden in a scratch pod and reading `df`:

```sh
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: fscheck, namespace: vm-cbt-demo}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: $(oc get deploy cdi-deployment -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[0].image}')
    command: ["sleep", "600"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: v, mountPath: /data, readOnly: true}]
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: golden-rhel9-light, readOnly: true}
EOF
oc wait --for=condition=Ready pod/fscheck -n vm-cbt-demo --timeout=180s
oc exec fscheck -n vm-cbt-demo -- df -h /data   # expect ~1.9G used; 0 = BAD
oc delete pod fscheck -n vm-cbt-demo
```

**Never** build fleet roots from a golden that has not passed this check.
On 2026-11-22 a golden created via `dataSourceRef -> DataSource` cross-ns
bound as a **blank disk** (that mechanism needs a ReferenceGrant, which this
cluster does not have; without it the reference is silently ignored). 2000
VMs booted empty disks: VMI phase "Running" (qemu up, no OS), SSH connection
refused. `scripts/density-setup.sh:ensure_namespace_golden()` must be
migrated to the DataVolume method above before it is trusted for a new
namespace.

## Step 2 — build the fleet in batches

`scripts/density-setup.sh` batches automatically when
`DENSITY_VM_COUNT > DENSITY_PVC_BATCH` (default 100): kube-burner runs once
per batch and each batch's root PVCs must bind before the next batch starts.
This keeps concurrent ceph clones under the level where the 5-QPS provisioner
starves.

```sh
cd /root/v2/virt-cbt-lab
make density-setup VM_OS=rhel9-light POOL=fleet-rhl MANIFEST_VARIANT=large-odf \
  DENSITY_VM_COUNT=1000 DENSITY_INCREMENTAL_PASSES=1 DENSITY_QPS=50 \
  DENSITY_WAIT_MINUTES=310 DENSITY_PVC_BATCH=100

make density-setup VM_OS=windows POOL=fleet-win GUEST_EXEC_POLL_ATTEMPTS=450 \
  DENSITY_VM_COUNT=1000 DENSITY_INCREMENTAL_PASSES=1 DENSITY_QPS=50 \
  DENSITY_WAIT_MINUTES=370 DENSITY_PVC_BATCH=100
```

Rules learned the hard way:

- `VM_OS`/`POOL` are **make arguments**, never env vars — `.env` overrides
  the environment (`VM_OS=rhel9-light POOL=x make density-setup` built stock
  rhel9 VMs once).
- Run the two families in parallel; one family's stall must not abort the
  other (`fleet-e2e.sh fleet-setup` does this; manual parallel `make` calls
  work too).
- Root disk size must equal the golden's **actual capacity**
  (`oc get pvc golden-... -o jsonpath='{.status.capacity.storage}'`) — the
  CSI clone floor rejects requests smaller than the source (11Gi real vs 10Gi
  requested trips it).
- Expected wall time: ~2 h for 1000 gated root clones per family, rhl boot
  ~1 min/VM, windows OOBE 20-25 min/VM (parallel batches).
- Registry: if anything was cleaned outside fleet-e2e, regenerate
  `artifacts/fleet.yaml` with the exact jq in `cbt-scale/fleet-e2e.sh`
  (`FLEET_REG_JQ`) before running `fleet-e2e.sh run`.

## Step 3 — repair stragglers

A few percent of roots typically land in the
`failed to clone rbd image ... RBD image not found` loop (their in-flight
clone's parent snapshot was cycled; leaked `-temp` rbd images are the
signature). Fix: delete the PVC and recreate it from the golden. The
wave-fill pattern (kept at `/tmp/wave-fill2.sh` on cloud05; also matches the
batch loop in `density-setup.sh`):

```sh
# missing = VM exists but its vm-disk-<vm> PVC does not; recreate in gated
# waves of 50-100 with:
#   dataSource: {kind: PersistentVolumeClaim, name: golden-<os>}
# Labels REQUIRED (fleet/reset tooling matches on them):
#   app.kubernetes.io/managed-by: virt-cbt-lab
#   virt-cbt-lab/run-id: <vm-name>
#   virt-cbt-lab/pool: fleet-rhl | fleet-win
bash /tmp/wave-fill2.sh 100
```

If the clone rate collapses to ~0: the csi-provisioner leader is wedged
(check `oc logs <leader> -n openshift-storage -c csi-provisioner` for
near-zero GRPC lines). Restart the leader pod, resolving it via
`oc get pods -n openshift-storage -l app=openshift-storage.rbd.csi.ceph.com-ctrlplugin`
and the lease holder's replicaset suffix — never construct the pod name from
the lease `holderIdentity` (dash/dot mismatch makes it NotFound).

Fleet gate: >=95% ready per family (`FLEET_MIN_READY_FRAC`, default 0.95).

## Step 4 — SSH smoke test (never skip)

```sh
oc port-forward -n vm-cbt-demo service/vm-ssh-fleet-rhl-0001 24567:22 &
ssh -i /root/v2/virt-cbt-lab/keys/id_ed25519 -p 24567 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    cbt-demo@127.0.0.1 'echo SSH-OK'
```

VMI phase "Running" is qemu, not a booted guest. Only this check proves the
guest OS is alive — it is the difference between a real backup run and
backing up 2000 blank disks.

## Step 5 — the parallel backup run

```sh
PARALLEL_OS=true FAMILY_WAIT_TIMEOUT=43200 KUBECONFIG=/root/mno/kubeconfig \
  cbt-scale/fleet-e2e.sh run --os rhel9-light --count <ready-rhl> \
  --windows-count <ready-win> --wave 500
```

- `PARALLEL_OS=true` is mandatory for multi-family simultaneity (default
  drives families sequentially).
- After the run, confirm concurrency: every family's "all full backup
  requests applied" timestamp must be within seconds of the others.
- Capacity: a 2000-VM full+incremental wave writes ~48 TiB of backups (x3 raw
  on the durable pool); check `ceph df` MAX AVAIL before a run. One run per
  cleanup cycle; run `cbt-scale/backup-wipe.sh --yes` between stacked runs.
- Monitor during the run: per-family vmbackup Done counts, ceph pool
  utilization (pause if >80%), `hp-volume-*` Pending pods (attach-storm
  signature).
- Windows driver logs report `pass=0` for the workload step (no vm-ssh
  Service on windows pools — by design); judge windows from cluster state
  and `summary.json`.
- Verification is `cbt-scale/fleet-verify.sh <group-id> [start-UTC end-UTC]`
  (per-vmbackup Done reasons + tracker checkpoints + Prometheus sweep);
  verdicts come from that, never from exit codes alone.

## Replacing all root disks (recovery from a bad golden)

Root PVCs of running VMs cannot be deleted (`kubernetes.io/pvc-protection`).
The full sequence:

```sh
# 1. Halt every fleet VM. NOTE: spec.running is IGNORED when runStrategy is
#    set — patch runStrategy, not running:
oc patch vm <vm> -n vm-cbt-demo --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
# 2. Wait for VMIs and virt-launcher pods to reach 0.
# 3. Delete the root PVCs (they now drain; PVs reclaim with Delete policy).
# 4. Recreate roots from the FIXED golden (wave-fill, step 3).
# 5. Start again:
oc patch vm <vm> -n vm-cbt-demo --type=merge -p '{"spec":{"runStrategy":"Always"}}'
```

## Failure signatures quick-reference

| Signature | Meaning | Fix |
|---|---|---|
| Root PVC Pending, `DeadlineExceeded` events | provisioner throttle storm | batching + grpcTimeout=600 |
| `failed to clone rbd image ... RBD image not found` | clone's parent snapshot cycled | delete + recreate PVC (wave-fill) |
| VMI Running but SSH connection refused | empty/guestless disk | verify golden data (step 1), re-clone roots |
| PVC deletionTimestamp set but never deleted | pvc-protection: VM still running | halt VM first (runStrategy!) |
| `rbd du` shows 0 B on a golden | misleading (clone-parent accounting) | verify with scratch-pod `df` |
| Provisioner leader near-zero GRPC lines | wedged leader | restart leader pod (resolve via replicaset label) |
| `vm-disk-vm-*` PVCs appear | double-prefix bug in ad-hoc scripts | delete (junk); use the tracked wave-fill pattern |

## Timing budget (measured, 2026-11-22/23)

| Phase | Wall |
|---|---|
| Goldens (CDI clone + data verification) | ~5 min |
| 1000 root clones per family (gated 100-waves) | ~2 h |
| rhel9-light boot to ready (1000) | ~20 min |
| Windows OOBE to ready (1000) | ~45-60 min |
| Full fleet build, cold | ~3-4 h |
| Full root-disk replacement (bad golden recovery) | +4.5 h — avoid via step 1 verification |
