# E2E Validation Summary

**Date:** 2026-09-29  
**Environment:** OpenShift/KubeVirt cluster accessed through `<target-host>`  
**Repository:** KubeVirt CBT VM backup demo  
**Scope:** Execute the supported Make targets and helper script, then independently verify results with OpenShift API queries and guest SSH.

No production repository logic was modified during validation.

## Results

| Target | Result | Notes |
|---|---|---|
| `make help` | PASS | Printed the documented targets and configuration guidance. |
| `make preflight` | PASS on <target-host> | 57 checks passed, 0 warnings, 0 failures. |
| `make vm-setup` | PASS | VM became ready, VMI ran, CBT was enabled, and guest SSH/file initialization succeeded. |
| `make vm-backup` | PASS | Full backup completed with type `Full`. |
| `make vm-cbt-backup` | PASS on a fresh namespace | Guest data changed and an `Incremental` backup completed. |
| `make vm-cbt-verify` | PASS | Script assertions matched independently queried cluster state. |
| `make vm-cbt-demo` | PASS | Direct composite workflow completed all four stages. |
| `make e2e` | PASS | Preflight and the complete setup/full/incremental/verification workflow passed. |
| `make clean-all` | PASS | Demo resources and workflow-managed key were removed; shared storage remained. |
| `sync.sh` | PASS | Tested against a temporary remote directory; secret and log exclusions were verified. |
| Shell syntax validation | PASS | All shell scripts passed `bash -n`. |

### Counts

- PASS: 10 workflow/helper targets
- FAIL: 0
- BLOCKED: 0
- INCONCLUSIVE: 0
- Issues created: 0

The count is for the <target-host> validation. A separate local workstation invocation of `make preflight` failed because the local machine could not read the <target-host> kubeconfig path from `.env`; the same target passed on <target-host>.

## Source intent and resource map

The repository defines this workflow:

```text
make e2e
  -> make preflight
  -> make vm-cbt-demo
       -> make vm-setup
       -> make vm-backup
       -> make vm-cbt-backup
       -> make vm-cbt-verify
```

The workflow-managed namespace is `vm-cbt-demo`.

| Resource | Expected purpose |
|---|---|
| `VirtualMachine/vm-cbt-demo` | Fedora VM with `cbt-demo=enabled` label and CBT enabled. |
| `VirtualMachineInstance/vm-cbt-demo` | Running VM instance. |
| `DataVolume/vm-cbt-root` and its PVC | 30 GiB VM root disk using `cbt-demo-hpp`. |
| `Service/vm-cbt-ssh` | Port 22 access to the guest through `oc port-forward`. |
| `VirtualMachineBackupTracker/hello-tracker` | Tracks the VM backup checkpoint. |
| `VirtualMachineBackup/hello-full` | Initial full backup. |
| `PVC/hello-full-output` | Full backup output volume. |
| `VirtualMachineBackup/hello-incremental` | Incremental backup based on the tracker checkpoint. |
| `PVC/hello-incremental-output` | Incremental backup output volume. |

## Commands executed and independent verification

All cluster commands below were run on <target-host> after loading the repository configuration and exporting the configured kubeconfig for direct `oc` use. Sensitive kubeconfig contents and credentials were not printed.

### 1. `make help`

Executed:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make help'
```

Observed the documented targets, including:

```text
make preflight
make vm-setup
make vm-backup
make vm-cbt-backup
make vm-cbt-verify
make vm-cbt-demo
make e2e
make clean-all
```

This target does not create or modify cluster resources.

### 2. `make preflight`

Executed:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make preflight'
```

Observed:

```text
Summary: 57 checks; 57 passed; 0 warnings; 0 failures
READY: environment is prepared for the repository workflow.
```

The preflight checks independently queried or validated:

- `bash`, `make`, `oc`, `ssh`, `ssh-keygen`, and required shell utilities.
- Selected OpenShift context.
- `oc whoami` authentication.
- `oc get --raw=/version` API reachability.
- Required CRDs:
  - `virtualmachines.kubevirt.io`
  - `virtualmachinebackups.backup.kubevirt.io`
  - `virtualmachinebackuptrackers.backup.kubevirt.io`
- Fedora DataSource:

```sh
oc get datasource fedora -n openshift-virtualization-os-images
```

- Storage class:

```sh
oc get storageclass cbt-demo-hpp
```

- KubeVirt `IncrementalBackup` feature gate.
- Required create/delete permissions via `oc auth can-i`.
- Guest private-key readability, permissions, validity, and public/private pair matching.

### 3. `make vm-setup`

Executed:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make vm-setup'
```

The script applied `manifests/vm.yaml`, waited for VM readiness, checked CBT, and initialized the guest file.

Independent verification commands:

```sh
oc get ns vm-cbt-demo -o jsonpath='namespace={.metadata.name}{"\n"}'

oc get vm vm-cbt-demo -n vm-cbt-demo \
  -o jsonpath='vm={.metadata.name} runStrategy={.spec.runStrategy} cbtLabel={.metadata.labels.cbt-demo} cbtState={.status.changedBlockTracking.state} ready={.status.ready}{"\n"}'

oc get vmi vm-cbt-demo -n vm-cbt-demo \
  -o jsonpath='vmi={.metadata.name} phase={.status.phase}{"\n"}'

oc get dv vm-cbt-root -n vm-cbt-demo \
  -o jsonpath='dv={.metadata.name} phase={.status.phase} storageClass={.spec.storage.storageClassName} size={.spec.storage.resources.requests.storage}{"\n"}'

oc get pvc vm-cbt-root -n vm-cbt-demo \
  -o jsonpath='pvc={.metadata.name} phase={.status.phase} storageClass={.spec.storageClassName} capacity={.status.capacity.storage}{"\n"}'

oc get svc vm-cbt-ssh -n vm-cbt-demo \
  -o jsonpath='service={.metadata.name} port={.spec.ports[0].port} selector={.spec.selector.vm\\.kubevirt\\.io/name}{"\n"}'
```

Observed:

```text
namespace=vm-cbt-demo
vm=vm-cbt-demo runStrategy=Always cbtLabel=enabled cbtState=Enabled ready=true
vmi=vm-cbt-demo phase=Running
dv=vm-cbt-root phase=Succeeded storageClass=cbt-demo-hpp size=30Gi
pvc=vm-cbt-root phase=Bound storageClass=cbt-demo-hpp
service=vm-cbt-ssh port=22 selector=vm-cbt-demo
```

Independent guest verification used a direct port-forward and SSH command rather than trusting the setup script's hash output:

```sh
oc port-forward -n vm-cbt-demo service/vm-cbt-ssh :22
ssh -i <workflow-private-key> -p <forwarded-port> \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  cbt-demo@127.0.0.1 \
  'cat /home/cbt-demo/hello.txt; sha256sum /home/cbt-demo/hello.txt'
```

Observed initial guest state:

```text
Hello from the VM CBT demo.
86465948fd4c202dbd6905f48b7a639681ec6cf26be3ca7e33de909ee19b59d6
```

### 4. `make vm-backup`

Executed:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make vm-backup'
```

Independent verification commands:

```sh
oc get vmbackup hello-full -n vm-cbt-demo \
  -o jsonpath='hello-full: type={.status.type} done={.status.conditions[?(@.type=="Done")].status} checkpoint={.status.checkpointName} source={.spec.source.name} output={.spec.pvcName}{"\n"}'

oc get vmbackuptracker hello-tracker -n vm-cbt-demo \
  -o jsonpath='tracker: sourceKind={.spec.source.kind} source={.spec.source.name} latest={.status.latestCheckpoint.name}{"\n"}'

oc get pvc hello-full-output -n vm-cbt-demo \
  -o jsonpath='pvc={.metadata.name} phase={.status.phase} storageClass={.spec.storageClassName} requested={.spec.resources.requests.storage}{"\n"}'
```

Observed in the successful fresh run:

```text
hello-full: type=Full done=True checkpoint=hello-full-2026-09-29_07-28-44 source=hello-tracker output=hello-full-output
tracker: sourceKind=VirtualMachine source=vm-cbt-demo latest=hello-full-2026-09-29_07-28-44
pvc=hello-full-output phase=Bound storageClass=cbt-demo-hpp requested=30Gi
```

### 5. `make vm-cbt-backup`

Executed:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make vm-cbt-backup'
```

Independent verification commands:

```sh
oc get vmbackup hello-full -n vm-cbt-demo \
  -o jsonpath='hello-full: type={.status.type} done={.status.conditions[?(@.type=="Done")].status} checkpoint={.status.checkpointName}{"\n"}'

oc get vmbackup hello-incremental -n vm-cbt-demo \
  -o jsonpath='hello-incremental: type={.status.type} done={.status.conditions[?(@.type=="Done")].status} checkpoint={.status.checkpointName} source={.spec.source.name} output={.spec.pvcName}{"\n"}'

oc get vmbackuptracker hello-tracker -n vm-cbt-demo \
  -o jsonpath='tracker: source={.spec.source.name} latest={.status.latestCheckpoint.name}{"\n"}'

oc get pvc hello-full-output hello-incremental-output -n vm-cbt-demo \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,REQUEST:.spec.resources.requests.storage
```

Observed:

```text
hello-full: type=Full done=True checkpoint=hello-full-2026-09-29_07-28-44
hello-incremental: type=Incremental done=True checkpoint=hello-incremental-2026-09-29_07-29-06 source=hello-tracker output=hello-incremental-output
tracker: source=vm-cbt-demo latest=hello-incremental-2026-09-29_07-29-06
```

The full and incremental checkpoints were distinct:

```text
Full:        hello-full-2026-09-29_07-28-44
Incremental: hello-incremental-2026-09-29_07-29-06
```

Independent guest verification after the incremental stage:

```text
Hello from the VM CBT demo.
This line was added after the full backup.
guest_sha256=2c4cc2481630200313b91d02333cf35cbc08b6e5ec10eeb22eb8144aa3621373
```

The guest hash changed from the initial setup hash, proving that the guest-side mutation occurred independently of the backup script's success message.

### 6. `make vm-cbt-verify`

Executed:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make vm-cbt-verify'
```

Independent verification repeated the underlying assertions with direct API queries:

```sh
oc get vm vm-cbt-demo -n vm-cbt-demo \
  -o jsonpath='vm cbt={.status.changedBlockTracking.state} ready={.status.ready}{"\n"}'

for backup in hello-full hello-incremental; do
  oc get vmbackup "$backup" -n vm-cbt-demo \
    -o jsonpath="$backup type={.status.type} done={.status.conditions[?(@.type==\"Done\")].status} checkpoint={.status.checkpointName}{\"\\n\"}"
done

oc get vmbackuptracker hello-tracker -n vm-cbt-demo \
  -o jsonpath='tracker latest={.status.latestCheckpoint.name}{"\n"}'
```

Observed:

```text
vm cbt=Enabled ready=true
hello-full type=Full done=True checkpoint=hello-full-2026-09-29_07-28-44
hello-incremental type=Incremental done=True checkpoint=hello-incremental-2026-09-29_07-29-06
tracker latest=hello-incremental-2026-09-29_07-29-06
```

### 7. `make vm-cbt-demo`

Executed directly after resetting the demo namespace:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make clean-all'
ssh <target-host> 'cd /path/to/cbt-setup && make vm-cbt-demo'
```

The direct composite target completed all four stages and independently produced:

```text
VM CBT: Enabled
Full backup: Done=True, type=Full
Incremental backup: Done=True, type=Incremental
Tracker latest checkpoint: incremental checkpoint
```

### 8. `make e2e`

Executed after an independent pre-run cleanup:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make e2e'
```

The target ran:

```text
preflight -> vm-setup -> vm-backup -> vm-cbt-backup -> vm-cbt-verify
```

Independent post-E2E verification used the VM, VMI, DataVolume, backup, tracker, PVC, and guest SSH commands documented above. The cluster state matched the intended workflow, not merely the script output.

### 9. `make clean-all`

Before cleanup, the following resources were independently recorded:

```sh
oc get vm,vmbackup,vmbackuptracker,pvc,svc,vmi -n vm-cbt-demo
oc get pv
oc get storageclass cbt-demo-hpp
```

The final cleanup command was:

```sh
ssh <target-host> 'cd /path/to/cbt-setup && make clean-all'
```

Independent post-cleanup verification:

```sh
oc get ns vm-cbt-demo
oc get vm,vmbackup,vmbackuptracker,pvc,svc,vmi -A
oc get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="vm-cbt-demo")]}{.metadata.name}{","}{end}'
oc get storageclass cbt-demo-hpp \
  -o jsonpath='storageclass={.metadata.name} provisioner={.provisioner}{"\n"}'
```

Observed:

```text
namespace vm-cbt-demo: absent
demo namespaced resources: absent
demo PV claim references: none
storageclass=cbt-demo-hpp provisioner=kubevirt.io.hostpath-provisioner
workflow-managed guest key: absent
```

The shared `cbt-demo-hpp` storage class remained intact, as required.

### 10. `sync.sh`

The synchronization helper was tested against a temporary remote directory rather than the working repository destination:

```sh
REMOTE_HOST=<target-host> \
REMOTE_DIR=/tmp/cbt-sync-validation-20260929 \
./sync.sh
```

Independent verification:

```sh
ssh <target-host> 'test -f /tmp/cbt-sync-validation-20260929/Makefile'
ssh <target-host> 'test ! -e /tmp/cbt-sync-validation-20260929/.env'
ssh <target-host> 'test ! -e /tmp/cbt-sync-validation-20260929/<target-host>-e2e-2026-09-29.log'
```

Observed:

```text
sync_independent=PASS
```

### 11. Shell syntax validation

Executed locally:

```sh
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

The command completed without output or syntax errors.

## Notable observations

### Local preflight configuration

The workstation invocation:

```sh
make preflight
```

failed because the local workstation could not read the <target-host> kubeconfig path configured in `.env`. The failure was environmental:

```text
FAIL  KUBECONFIG_PATH is not a readable file
FAIL  no usable kubeconfig context is selected
FAIL  oc authentication failed
FAIL  cluster API is not reachable
```

The same command passed on <target-host> with all 57 checks passing. This was not classified as a repository defect.

### Rerunning incremental backup with fixed names

An early rerun against an already-populated namespace returned:

```text
hello-incremental already exists; start a fresh demo namespace before rerunning this step.
```

This behavior is expected. The documentation states that resource names are fixed and the workflow is intentionally one run per namespace. The target passed after `make clean-all` recreated a fresh namespace.

## Final judgment

The <target-host> cluster independently confirmed the intended end-to-end behavior:

1. VM and VMI were created and became ready/running.
2. CBT was actually enabled in VM status.
3. The guest file was created and reachable over SSH.
4. The full backup completed as `Full`.
5. The tracker recorded the full checkpoint.
6. The guest file changed after the full checkpoint.
7. The second backup completed as `Incremental`.
8. Full and incremental checkpoints were different.
9. The tracker advanced to the incremental checkpoint.
10. Cleanup removed demo resources and preserved shared infrastructure.
