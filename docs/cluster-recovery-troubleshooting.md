# Cluster recovery troubleshooting: NotReady workers, down OSDs, full OSDs

Living guide written while recovering a Scale Lab OpenShift/ODF cluster that
could not provision VM roots for a CBT scale run. Everything here was observed
on a real cluster; items marked **[INFERENCE]** were not directly verified.
Node names, addresses and credentials are intentionally omitted: use
`<node>`, `<node-ip>` and `<bmc-host>` placeholders.

Run all `oc` and `ssh` commands from the fixed execution host (see
`.agents/skills/cbt-scale-chaos/SKILL.md`), with `KUBECONFIG` set. Ceph
commands run in the rook-ceph tools pod:

```sh
TOOLS=$(oc -n openshift-storage get pod -l app=rook-ceph-tools -o name | head -1)
ceph() { oc -n openshift-storage exec "$TOOLS" -- ceph "$@"; }
```

## 1. Symptom set

| Symptom | Where seen |
|---|---|
| Several workers `NotReady`, "Kubelet stopped posting node status" | `oc get nodes`, node conditions |
| `HEALTH_WARN`/`HEALTH_ERR`: OSDs down, PGs inactive/down/stale, `backfill_toofull` | `ceph status` |
| Pools show `0 B` MAX AVAIL, 100 % used | `ceph df` |
| VM roots and backup PVCs cannot provision | fleet build stalls |
| `make clean-all`-style cleanup finds nothing, yet pools stay full | orphan RBD images |

## 2. Diagnose before acting (read-only)

```sh
oc get nodes -o wide | grep -v ' Ready'
oc get csr | grep -c Pending
ceph status; ceph health detail | head -30
ceph osd tree down
ceph osd dump | grep -E '^(full|backfillfull|nearfull)_ratio'
ceph df; ceph osd df | sort -k17 -n -r | head
```

Check the node itself (workers accept ssh as `core` from the execution host):

```sh
ssh core@<node-ip> 'uptime; systemctl is-active kubelet crio; ps -eo stat | grep -c ^D'
ssh core@<node-ip> 'ps -eo pid,ppid,stat,wchan:30,etime,cmd | grep -E "[k]ubelet|[k]ubenswrapper"'
ssh core@<node-ip> 'sudo journalctl -u kubelet --no-pager -n 25'
ssh core@<node-ip> 'sudo dmesg -T | grep -iE "libceph|rbd:|hung task|blocked for more"'
```

## 3. Root cause found: a circular dependency

Observed on every NotReady node:

- The old kubelet is a **defunct** process (`Zsl`, parent PID 1, running since
  boot) whose threads sit in uninterruptible I/O (state `D`, tens per node,
  load average 65-140) on `rbd*-tasks` kernel workers.
- `dmesg` shows `libceph: pool N is full or reached quota` and
  `rbd: ... failed to unwatch: -110`.
- The replacement kubelet crash-loops with
  `listen tcp <node-ip>:10250: bind: address already in use` and
  `Failed to start healthz server ... 127.0.0.1:10248: address already in use`:
  the zombie still holds both ports. systemd logs
  `State 'stop-sigterm' timed out. Killing.` and never frees them.
- Client certificates were valid; this was not a certificate problem.
- OSDs live on the same nodes. With the nodes dead the OSDs are down, PGs go
  inactive, and RBD I/O hangs, which keeps the kubelets stuck.

```
dead node -> OSDs down -> PGs inactive -> RBD I/O hangs (D-state)
   ^                                              |
   +---- zombie kubelet holds :10250/:10248 <-----+
```

A `D`-state thread cannot be killed. Restarting the kubelet service does not
help. **Only a node reboot clears it, or restoring PG availability so the I/O
completes.** In this recovery, once one node's OSDs rejoined and PGs became
active, most of the other stuck nodes recovered on their own within minutes
(see section 5).

## 4. Fix procedure

Cluster-wide effects: get explicit approval before rebooting nodes or power
cycling. Never reboot several storage nodes at once.

1. **Canary one node.**
   `ssh core@<node-ip> 'sudo systemctl reboot'`. Expect the shutdown to hang
   for several minutes on the stuck RBD I/O, then the host to drop off the
   network and go through firmware POST (about 5 minutes on a 3-OSD R660).
2. If the node is still down 10 minutes after the reboot, or stays pingable
   but refuses ssh, power-cycle it through the BMC (section 6). A clean
   reboot of a node with stuck RBD I/O often never completes.
3. **Verify the canary before touching anything else:**
   `oc get node <node>` is `Ready`, `systemctl is-active kubelet crio` is
   `active`, the D-state count is 0, and its OSD pods start
   (`oc -n openshift-storage get pods -o wide | grep osd`), the OSDs show
   `up` in `ceph osd tree`, and `ceph status` shows PGs recovering.
4. **Re-check the other NotReady nodes after the canary is healthy.**
   Do not reboot them blindly: see the mistake in section 5.
5. Approve the pending `kubelet-serving` CSRs for nodes that belong to the
   cluster (a backlog of hundreds builds up while kubelets are down). Only
   approve CSRs whose `spec.username` is `system:node:<a node in oc get nodes>`
   and whose signer is `kubernetes.io/kubelet-serving`.

## 5. Mistakes and pitfalls (so they are not repeated)

- **Re-check node state after the canary recovers.** After the first node came
  back and its three OSDs rejoined, seven of the remaining ten NotReady nodes
  became Ready by themselves within about two minutes. A batch reboot issued
  without re-checking hit three nodes that were already recovering, forced
  another ~15-minute outage on them, and required BMC power cycles. The
  helper script that issued the reboots started before the node-state check.
- When a command is started asynchronously in the same step that writes the
  script it runs, the script may not exist yet: write the file first, run in a
  later call.
- Do not `pkill -f` a pattern that also appears in your own ssh command line:
  it kills the invoking shell. Use a bracket pattern, for example
  `pkill -f '[s]cale-pool-gc'`, or target a PID.

## 6. BMC / iDRAC access (Scale Lab)

- BMC host name: `mgmt-<node-fqdn>` (prepend `mgmt-` to the host name; see the
  Scale Lab FAQ, "out-of-band / IPMI interfaces"). Credentials are in the
  assignment email (`quads` user); never write them into logs, docs or
  manifests. Pass the password through stdin or `IPMI_PASSWORD` with
  `ipmitool -E`, never on the command line.
- Read-only checks first:
  `ipmitool -I lanplus -H <bmc-host> -U <user> -E chassis power status` and
  `... sel elist last 8`.
- `sol activate` can be disabled ("SOL payload disabled"); then there is no
  serial console from the execution host.
- Power cycle only after the clean reboot has hung:
  `ipmitool -I lanplus -H <bmc-host> -U <user> -E chassis power cycle`.
  A node power-cycled this way was `Ready` about five minutes later.
- Scale Lab rules: do not change IPMI/iDRAC passwords, IP addressing, boot
  order, PXE settings or virtual media. Power state only.

## 7. After the nodes and OSDs are back: full OSDs and skew

All OSDs up does not mean healthy. The 15 OSDs that were down missed writes,
and backfill onto already-full OSDs is blocked (`backfill_toofull`).

- Symptom: cluster only ~38 % raw used, yet `HEALTH_ERR` "N full osd(s)",
  13 pools full and `0 B` available. One OSD stayed at ~94 %.
- `full_ratio` (and `backfillfull_ratio`) are reset by Rook/ODF back to 0.85 /
  0.80 after OSD restarts; do not assume a temporary raise persists.
- Raising `full_ratio` (`ceph osd set-full-ratio 0.95`) is only a temporary
  unblock so that `rbd rm` and lock removal can complete. Always restore it:
  `ceph osd set-full-ratio 0.85`, and confirm with
  `ceph osd dump | grep ^full_ratio`.
- Orphaned RBD images are the main space reclaim. Find them (report only):
  `cbt-scale/scale-pool-gc.sh [--pool <pool>]`. An image is an orphan when no
  PersistentVolume references it. In this recovery: the backup pool had 105
  orphans and the root pool 5,027 (about 948 GiB written), with thousands of
  ceph-csi internal images (`rf-*`, `rest-*`, `-temp`) that the script skips on
  purpose. Deleting orphans needs explicit approval because it is
  irreversible; keep every PV-referenced image (golden DataSources included).
- `rbd du` can fail on a dangling parent snapshot; the script then reports
  `written=0GiB`. That is not "nothing to reclaim".
- **Reweighting the full OSD did not help** when the stuck PG was in the
  replica-1 backup pool. `ceph osd reweight <id> 0.8` left the OSD at 94 % and
  one PG (`active+remapped+backfill_toofull`, ~21 GB, up `[<full-osd>]`,
  acting on another OSD) kept trying to backfill *onto* the full OSD. Check
  with `ceph pg ls backfill_toofull`: if `UP` is the full OSD, the fix is to
  free data on that OSD (delete the unreferenced backup-pool images), not to
  lower its weight. Revert any temporary reweight afterwards
  (`ceph osd reweight <id> 1.0`).

### Known bug: `scale-pool-gc.sh --delete` exits 141

`scale-pool-gc.sh --delete` died with exit 141 (SIGPIPE) right after
`releasing stale exclusive locks`, deleting nothing. The check
`tools ceph health | grep -q 'full osd'` runs under `set -o pipefail`, and
`grep -q` closes the pipe early. It also matches `backfillfull osd(s)`, so
raising `full_ratio` first does not avoid it. Workaround used (repo file left
unedited): stream a patched copy, replacing that `if` with `if false`, and
raise/restore `full_ratio` manually:

```sh
sed "s#if tools ceph health 2>/dev/null | grep -q .full osd.; then#if false; then#" \
  cbt-scale/scale-pool-gc.sh | bash -s -- --delete --jobs 8
```

A permanent fix is to capture the health text into a variable first
(`health=$(tools ceph health 2>/dev/null || true)`) and grep the variable.

### Why the OSD stayed full: huge PGs in a 32-PG pool, held by ceph-csi leftovers

After the backup pool dropped from 9.5 TiB to under 25 GiB stored, the full OSD
barely moved (94 % to 93 %). `ceph pg ls-by-osd <id>` showed six of its PGs
belong to the root pool, which has only 32 PGs holding 25 TiB (roughly 800 GB
per PG, three replicas). The data in that pool was ~950 GiB of plain orphan
`csi-vol-*` images plus thousands of ceph-csi **internal** images with no PV:
clone-v2 intermediates named `csi-vol-<uuid>-temp`, each holding a snapshot
named after the source volume. The golden source images keep hundreds of
**trashed** snapshots (`rbd snap ls --all` shows
`trash (user csi-vol-<uuid>-temp)`), one per clone that was ever made.

### Never delete golden images: protect before you purge

Golden DataSource images (for example the `rhel9-light`, `rhel9-rbd` and
Windows goldens) are PVC-backed, so a PV references them, and they are clone
parents. A Windows golden can itself be a clone of an internal `-temp` image
(`rbd info` shows `parent: <pool>/csi-vol-<uuid>-temp@csi-vol-<uuid>`), so
"internal" does not mean "unused". Rules used for deletion:

1. Protect every image any PV references (all RBD PVs, filtered by pool).
2. Protect the parent chain of each protected image (follow `parent:` from
   `rbd info` until a fixpoint).
3. Protect any image whose name contains a uuid from a VolumeSnapshotContent
   `snapshotHandle` or `source.volumeHandle`.
4. Dry-run first (print the protected list and the target count), delete only
   the rest with `rbd snap purge` then `rbd rm`. A protected snapshot or live
   child makes the command fail, which leaves the image in place.
5. Afterwards verify: the protected images still `rbd info`, the golden PVCs
   are `Bound` and the DataVolumes `Succeeded`.

Note: a `VolumeSnapshot` in the namespace that points at a pre-provisioned
`VolumeSnapshotContent` may have no RBD snapshot or CSI journal entry behind
it at all (`rados listomapkeys csi.snaps.default` empty, no image carries the
handle uuid). Check before assuming it is a golden copy.

## 8. Recovery timeline (this incident, UTC, 2026-11-24)

| Time | Event |
|---|---|
| 04:29 | `systemctl reboot` on canary: shutdown hangs on stuck RBD I/O |
| ~04:35 | Canary drops off the network |
| 05:13 | BMC power cycle of the canary |
| 05:20 | Canary `Ready`, `kubelet`/`crio` active, 0 D-state threads |
| 05:21 | Canary's 3 OSDs up; PGs start recovering |
| ~05:22 | Seven other NotReady nodes recover without a reboot |
| 05:36 | BMC power cycle of three nodes rebooted by mistake |
| 05:43 | All nodes `Ready` |
| 05:48 | All 86 OSDs up; HEALTH_ERR from full OSDs |
| 06:15 | 105 backup-pool orphans deleted, 0 failed |
| 06:22 | Root-pool orphan deletion started (5,027 images; lock-release step alone takes tens of minutes) |
| 06:29 | `ceph osd reweight 78-equivalent 0.8` applied with approval; no drain, see section 7 |
| 07:32 | Root-pool deletion (`internal-gc2.sh`) started with ~7,180 images left (07:31 check) |
| 10:19 | First deletion pass finished: 1,842 images left; the rest were refused by Ceph because a snapshot still had a linked clone |
| 10:31 | Retry loop started for leftovers (`image has snapshots with linked clones`; Ceph refused each unsafe removal) |
| 10:41 | Retry loop finished (4 rounds). Root pool holds exactly the 5 protected images |
| 10:42 | Temporary settings reverted: `full_ratio` 0.85, osd.78 reweight 1.0 |

## 9. Final state and open items

- Stability gate at 10:42 UTC: 31/31 nodes Ready, 86/86 OSDs up and in,
  425/425 PGs active+clean, no OSD_FULL or OSD_NEARFULL health warning,
  `full_ratio` 0.85, root pool 47 TiB available.
- Ceph is `HEALTH_WARN`, not `HEALTH_ERR`. Remaining warnings: `cbt-scale-pool`
  has no replicas (intentional replica-1 test pool), and osd.9 crashed at
  03:07 UTC (not archived; left for the user to decide).
- Root-pool protected images: 5, all answering `rbd info`; golden PVCs Bound,
  golden DataVolumes Succeeded.
- Open: the `artifacts/fleet.yaml` registry was stale (listed VMs deleted
  earlier); `fleet-setup` regenerates it from the cluster.
- Known bug still open: `scale-pool-gc.sh --delete` exits 141 under
  `pipefail` (see the section above); the tracked file is unfixed.

## 10. After the stability gate: fleet build blocked (2026-11-24, UTC)

The stability gate in section 9 still holds. The fleet build did not succeed,
because every freshly created guest lacks sshd and qemu-guest-agent.

- Operator: OpenShift Virtualization `kubevirt-hyperconverged-operator.v4.22.16`
  was upgraded from v4.22.12 on 2026-11-23 18:25 UTC. The last working backups
  ran on 2026-11-20. The golden images (2026-11-19) predate the upgrade and are
  unchanged.
- Rollback to v4.22.12 is not possible through OLM: that CSV no longer exists,
  and the `stable` channel offers only v4.22.16.
- The Subscription was moved to `candidate` (v4.22.17, approved). The CSV is stuck
  in `Installing`/`InstallWaiting`. The new `virt-operator` and
  `virt-synchronization-controller` pods are in `ImagePullBackOff` from
  `registry.redhat.io` (`DeadlineExceeded`, `ErrImagePull`). The pull secret does
  include `registry.redhat.io`, so the likely cause is cluster egress or registry
  reachability. The old v4.22.16 operator still serves.
- Running VMs: the 21 VMIs in `vm-cbt-demo` (`rhel-t1`, `rhl-r2`, `win-fleet`)
  stayed Running with 0 restarts through the upgrade. None reports guest OS info.
- Guest boot: stock `rhel9`, RHEL-light (old and new goldens), and Windows all
  fail the same way. sshd is refused on 127.0.0.1:22 inside the virt-launcher
  netns, and qemu-guest-agent never connects. The root PVC is 11Gi, the same as
  its golden. virt-launcher logs one `No disk capacity` error at boot
  (manager.go:995). Its cause is not yet established.
- `scripts/density-setup.sh` now reads the `rhel9` golden from
  `openshift-virtualization-os-images`, and it honors
  `RHEL_LIGHT_DATA_SOURCE_NAME` for both source and golden PVC names. This is
  uncommitted.

Open items for infra:

1. Restore egress to `registry.redhat.io` from the cluster. Then the v4.22.17
   CSV should reach `Succeeded`. If it does not, move the Subscription back to
   `stable`.
2. Capture a guest serial or console log for `vm-rhel-t1-0001` in `vm-cbt-demo`.
   Find why sshd and qemu-guest-agent never start, and what the `No disk
   capacity` line means.
3. Only after the guests boot: build the 10 RHEL-light and 10 Windows fleet, run
   full and incremental backups, then `cbt-scale/fleet-verify.sh` and the timing
   report.

Leftover pools kept on purpose: `rhel-t1` (1 VM), `rhl-r2` (10 RHEL-light),
`win-fleet` (10 Windows). Delete by pool label when no longer needed.

## 11. Root cause of the blank guests and fix (2026-11-24, UTC)

The operator upgrade and registry egress were not the cause. Standard
`make vm-setup` (DataVolume `sourceRef` to a DataSource) booted RHEL 9 with
SSH and the guest agent on the same cluster, with the v4.22.17 CSV still stuck.

- Every failing VM came from `make density-setup`. Its uncommitted
  same-namespace golden copy (`ensure_namespace_golden` in
  `scripts/density-setup.sh`) created a bare PVC with
  `dataSourceRef: {apiGroup: cdi.kubevirt.io, kind: DataSource}`. CDI has no
  populator for that kind. ceph-csi provisioned a **blank** volume that bound
  normally, so the check "golden PVC Bound" passed.
- Evidence: `rbd du` on `golden-rhel9`, `golden-rhel9-light`,
  `golden-rhel9-light-r2` and `golden-windows` in `vm-cbt-demo` showed `0 B`
  written. The source goldens held 2-4 GiB. In the launcher, `disk.img` of a
  pool VM was all zeros with no MBR signature. That explains the absent sshd
  and guest agent. `No disk capacity` (manager.go:995) is logged for working
  VMs too, so it does not indicate this failure.
- Fix: `ensure_namespace_golden` now creates a CDI DataVolume
  (`sourceRef: DataSource`, `deleteAfterCompletion: "false"`) and waits for
  `Succeeded`. It reuses a golden only when its DataVolume `Succeeded`, and it
  refuses a golden PVC that has no DataVolume.
- Cleanup done: the four blank golden PVCs were deleted (completed debug pods
  `fscheck`/`fscheck2` held `golden-rhel9-light` in `Terminating`). The blank
  pools `rhel-t1`, `rhl-r2` and `win-fleet` and the `fix-*` test pools were
  later deleted by pool/run-id label and rebuilt with the fixed script. All 21
  guests (1 `rhel9`, 10 RHEL-light, 10 Windows) report their OS through the
  guest agent, and every pool is annotated `large-odf`. The test run
  directories were moved under `artifacts/cleanup-2026-11-24/runs/`.
- Verified after the fix: one-VM pools for `rhel9`, `rhel9-light` and
  `windows` boot, and each guest agent reports its OS. The pool root disks
  carry an MBR signature. On each adopted pool VM (small workload),
  `make e2e EXISTING_VM=...` ran 1 full and 4 incremental backups and passed
  restore verification, with `summary.json` verdict `PASS` for all three
  OSes. `make vm-setup` on the standard path (rhel9, `.env` workload) also
  passed.

Two adoption bugs (`make e2e EXISTING_VM=...`) surfaced once the guests booted:

- The rhel9-light size guard (`check_rhel_light_workload_fits`) ran only on
  the create path. With the `.env` workload (1000 files of 15-20 MiB) an
  adopted 12Gi light VM filled its root mid-setup and left a half-written run
  directory. `scripts/vm-setup.sh` now runs the guard before adoption too.
  It fails fast and leaves no `runs/<id>/`. For light VMs, pass a small
  workload (for example `GUEST_BASE_FILE_COUNT=20
  GUEST_INCREMENTAL_FILE_COUNT=10 GUEST_FILE_SIZE_MIN_MIB=4
  GUEST_FILE_SIZE_MAX_MIB=12`).
- Windows pools were annotated `manifest-variant=default`, which selects the
  `cbt-demo-hpp` backup manifests. The HPP pool exists only on
  `d38-h18-000-r660`, so the backup PVC stays `Pending` ("did not have enough
  free storage") on any other node. The roots are ODF and unpinned, so
  `density-setup.sh` now annotates Windows pools `large-odf`. Windows pools
  built before this fix keep the old annotation. Rebuild them.

## 12. Registry egress root cause: leaked krkn rule on two masters (2026-11-24, UTC)

The stuck v4.22.17 upgrade (`virt-operator`/`virt-synchronization-controller`
in `ImagePullBackOff`, `DeadlineExceeded`) was not an infra egress outage.
Only two of the 31 nodes failed outbound TCP/443. Both are control-plane
nodes, and `virt-operator` had been scheduled on one of them. TCP/80, 853 and
8443 worked from those nodes, and so did 443 from the other nodes and the
bastion.

- Method: nft counter chains at output priority -400 and 50 showed the SYN
  dropped between them on the bad nodes, with no nft rule matching in
  `nft monitor trace`. `lsmod` showed `iptable_filter` in use (refcount 1)
  only there, so a **legacy** iptables table held the rule, out of sight of
  `iptables-nft`/`nft`. RHCOS ships no `iptables-legacy`. The locally cached
  `quay.io/krkn-chaos/krkn-hub-multiarch` image has it:
  `podman run --rm --privileged --net=host --entrypoint iptables-legacy-save <image>`.
- Rule found in the host netns:
  `-A OUTPUT -p tcp --dport 443 -m state --state NEW,RELATED,ESTABLISHED -j DROP`.
  It matches word for word the krkn `pod-network-filter` rule from CBT-F-12
  (`cbt-chaos/scenarios_v2/CBT-F-12/runs/remove-rule-r02.sh`). That injection
  leaked into the node network namespace and was never removed. It also
  silently blocked kubelet-side clients from reaching `172.30.0.1:443` on those
  nodes.
- Fix: delete that exact spec with `iptables-legacy -D OUTPUT ...` (same
  image), check that it is gone, then delete the `ImagePullBackOff` pods. A
  scan of all nodes found no other copy.
- Lesson for chaos runs: after any krkn network-filter scenario, check every
  node's legacy filter table (`iptables-legacy-save`), not only the pod netns
  or `nft list ruleset`.
