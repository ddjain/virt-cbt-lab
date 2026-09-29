# CBT Backup Pipeline Verification Report

**Generated:** 2026-09-29  
**Test Environment:** RedHat OpenShift KubeVirt on Scale Lab (<target-host>)  
**Repository:** /path/to/cbt-setup  

---

## Executive Summary

The CBT end-to-end pipeline **passes all Make targets** with exit code 0. However, **the pipeline does not actually verify that CBT backup data can be restored or that the restored VM contains correct data.**

The verification stops at **Level 2 (Storage Artifact Verification)**:
- ✓ Backups are created and reach "Done=True" status
- ✓ Backup files exist on disk
- ✓ Metadata matches expected types and checkpoints

**Missing entirely (Levels 3-6):**
- ✗ Restore/remount of backup artifacts
- ✗ Filesystem mount verification
- ✗ File content comparison (pre vs post-backup)
- ✗ Incremental delta verification
- ✗ VM boot from restored disk

---

## What the Pipeline Actually Proves

### 1. **VM Creation & CBT Enablement** ✓ PROVEN
- Fedora VM created in namespace `vm-cbt-demo`
- CBT state: **Enabled**
- Guest SSH access functional
- Initial file written: `/home/cbt-demo/hello.txt`
- Initial hash: `86465948fd4c202dbd6905f48b7a639681ec6cf26be3ca7e33de909ee19b59d6`

### 2. **Full Backup Creation** ✓ PROVEN (Metadata Only)
- **Backup CR:** `hello-full` in namespace `vm-cbt-demo`
- **Status:** Done=True, type=Full
- **Checkpoint:** `hello-full-2026-09-29_18-14-38`
- **Artifact:** `/mnt/backup/vm-cbt-demo/hello-full-2026-09-29_18-14-38/hello-full-rootdisk.qcow2` (31 GB)
- **What's verified:** Metadata and file existence only
- **What's NOT verified:** Content readability, filesystem integrity

### 3. **CBT Tracking & Guest Mutation** ✓ PROVEN
- Guest file modified after checkpoint
- New hash: `2c4cc2481630200313b91d02333cf35cbc08b6e5ec10eeb22eb8144aa3621373`
- Tracker checkpoint advanced: `hello-full-2026-09-29_18-14-38` → watching for next backup
- **What's verified:** Live guest file changed
- **What's NOT verified:** CBT correctly identified changed blocks

### 4. **Incremental Backup Creation** ✓ PROVEN (Metadata Only)
- **Backup CR:** `hello-incremental` in namespace `vm-cbt-demo`
- **Status:** Done=True, type=Incremental
- **Checkpoint:** `hello-incremental-2026-09-29_18-15-00`
- **Artifact:** `/mnt/backup/vm-cbt-demo/hello-incremental-2026-09-29_18-15-00/hello-incremental-rootdisk.qcow2` (11 MB)
- **What's verified:** Metadata and file existence only
- **What's NOT verified:** Whether 11 MB is a delta or complete copy, whether applying it produces correct state

### 5. **Checkpoint Relationships** ✓ PROVEN
- Full checkpoint ≠ Incremental checkpoint ✓
- Both non-empty ✓
- Tracker's `latestCheckpoint` matches incremental checkpoint ✓

---

## Critical Verification Gaps

### Gap 1: **No Restore Verification** (CRITICAL)
- **Missing:** VirtualMachineRestore CR creation and execution
- **Evidence:** `grep -r restore /path/to/repo` returns nothing
- **Impact:** Cannot prove backups are recoverable
- **How to verify:** Create VirtualMachineRestore CRs, wait for completion

### Gap 2: **No Filesystem Mount Verification** (CRITICAL)
- **Missing:** Backup PVCs never mounted; filesystem never inspected
- **Evidence:** Scripts only use `oc get vmbackup` (metadata), never `mount` or `findmnt`
- **Impact:** Cannot prove restored disks are readable
- **How to verify:** Mount restored PVC in test pod, check filesystem

### Gap 3: **No File Content Verification** (CRITICAL)
- **Missing:** Pre-backup and post-restore file hash comparison
- **Evidence:** Hashes printed from **live guest** only, not from restored filesystem
- **Impact:** Cannot prove backup contains expected data
- **How to verify:**
  1. Restore full + incremental backups
  2. Mount filesystem in test pod
  3. Read `/home/cbt-demo/hello.txt` from restored filesystem
  4. Compute hash
  5. Compare: `restored_hash == expected_hash`

### Gap 4: **No Incremental Delta Verification** (HIGH)
- **Missing:** Verification that incremental file is actually a delta
- **Evidence:** Incremental qcow2 is only 11 MB (vs 31 GB full), but no qcow2 header/metadata check
- **Impact:** Cannot prove CBT captured only changed blocks (could be different backup format)
- **How to verify:** Inspect qcow2 headers, verify backing_file references full backup

### Gap 5: **No End-to-End VM Boot Test** (HIGH)
- **Missing:** Restored VM never started; cloud-init, SSH never verified from restored state
- **Evidence:** Pipeline terminates after backup creation
- **Impact:** Cannot prove restored VM is bootable or functional
- **How to verify:** Create VM from restored PVC, wait for Ready, SSH into guest

---

## Verification Levels Summary

| Level | Description | Current Status | Evidence |
|-------|-------------|-----------------|----------|
| **1** | Metadata verification | ✓ PROVEN | Backup CR has type=Full/Incremental, Done=True |
| **2** | Storage artifact verification | ✓ PROVEN | Backup files exist on disk (31 GB + 11 MB) |
| **3** | Disk-level verification | ✗ NOT VERIFIED | qcow2 never opened or inspected |
| **4** | Filesystem verification | ✗ NOT VERIFIED | Restored disk never mounted |
| **5** | Application/VM data verification | ✗ NOT VERIFIED | Restored files never read; no content comparison |
| **6** | CBT semantic verification | ✗ NOT VERIFIED | Incremental changes never verified in restored state |

**Current Maximum Achievable Level: 2**  
**Recommended Minimum: 5** (for data integrity confidence)

---

## Data Evidence Collected

### Backup Artifacts
```
Full Backup:
  Path: /mnt/backup/vm-cbt-demo/hello-full-2026-09-29_18-14-38/hello-full-rootdisk.qcow2
  Size: 31 GB
  Ownership: uid=107, gid=107
  Permissions: rw-------

Incremental Backup:
  Path: /mnt/backup/vm-cbt-demo/hello-incremental-2026-09-29_18-15-00/hello-incremental-rootdisk.qcow2
  Size: 11 MB
  Ownership: uid=107, gid=107
  Permissions: rw-------
```

### Backup CR Status (from cluster)
```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: hello-full
  namespace: vm-cbt-demo
status:
  type: Full
  done: True
  checkpointName: hello-full-2026-09-29_18-14-38
  includedVolumes:
  - diskTarget: vda
    volumeName: rootdisk
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: hello-incremental
  namespace: vm-cbt-demo
status:
  type: Incremental
  done: True
  checkpointName: hello-incremental-2026-09-29_18-15-00
  includedVolumes:
  - diskTarget: vda
    volumeName: rootdisk
```

### Tracker Status (from cluster)
```yaml
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: hello-tracker
  namespace: vm-cbt-demo
status:
  latestCheckpoint:
    name: hello-incremental-2026-09-29_18-15-00
    creationTime: "2026-09-29T18:15:00Z"
    volumes:
    - diskTarget: vda
      volumeName: rootdisk
```

---

## Recommended Minimal Improvements

### 1. Add Restore Verification
**File:** New `scripts/vm-cbt-restore-test.sh`  
**Effort:** ~150 lines  
**What it does:**
- Creates VirtualMachineRestore CR pointing to `hello-full` backup
- Waits for restore to complete
- Creates inspection pod mounting restored PVC
- Reads `/home/cbt-demo/hello.txt` from restored filesystem
- Computes SHA256
- Asserts hash matches expected value
- Verifies incremental line is present
- Cleans up

### 2. Update Verification Script
**File:** `scripts/vm-cbt-verify.sh`  
**Effort:** ~30 lines added  
**What it does:**
- Add workflow step 4/3: "Verify backup restoration and content"
- Call restore test script
- Compare hashes
- Fail if mismatch

### 3. Optional: Incremental Delta Verification
**File:** Enhancement to restore test  
**Effort:** ~50 lines  
**What it does:**
- Inspect qcow2 header of incremental backup
- Verify `backing_file` reference
- Confirm it points to full backup
- Prove it's a delta, not standalone copy

---

## What This Report Proves

✓ Pipeline creates backups and reaches "Done=True"  
✓ Backup files exist on disk with expected sizes  
✓ VM CBT state is Enabled  
✓ Checkpoints are distinct and tracked  
✗ Backups contain correct/recoverable data  
✗ Restored filesystem matches original  
✗ Incremental changes persist after restore  
✗ Restored VM is bootable  

---

## Conclusion

**The CBT backup pipeline demonstrates successful API-level backup creation but does not prove that backups contain recoverable, correct VM data.**

This is a classic case of **test-the-interface not test-the-capability**:
- Interface check: "Does Backup CR reach Done=True?" ✓
- Capability check: "Can we restore and read the data?" ✗

The 11 MB incremental backup file is suspicious—it suggests CBT is working, but without restore verification, we cannot be certain the backup is usable or contains the correct delta.

**Recommendation:** Add the 200-line restore verification to move from Level 2 to Level 5 confidence and detect any silent data corruption in the backup pipeline.
