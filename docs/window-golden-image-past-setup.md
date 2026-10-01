A sysprepped Windows Server 2022 golden image PVC from a prior KubeVirt cluster for CCLM migration testing. It contains Python 3.12.4 and three workloads (file-writer, sqlite-writer, http-server) that start at boot through a Windows Scheduled Task.

Golden Image PVC
Field

Value

PVC name

win2022-golden

Namespace

windows-golden-images

Storage class

hostpath-csi

Capacity

446Gi (40Gi requested, hostpath-csi over-provisions)

OS

Windows Server 2022 Standard Evaluation (build 20348.587)

State

Sysprepped (/generalize /oobe /shutdown)

Installed Software
Software

Version

Path

Python

3.12.4

C:\Program Files\Python312\python.exe

VirtIO guest tools

From CNV 4.21

Drivers + QEMU guest agent

.NET Framework 4.5

Built-in

Windows feature

Workloads
Three Python scripts in C:\workloads\, registered to auto-start via Scheduled Task StartWorkloads (runs as SYSTEM at startup).

Workload

Script

What it does

Data path

file-writer

C:\workloads\file-writer.py

Appends timestamped line every 1s

C:\data\test\log.txt

sqlite-writer

C:\workloads\sqlite-writer.py

Inserts row every 2s

C:\data\test\test.db

http-server

C:\workloads\http-server.py

Python HTTP server on port 8080, serves C:\data

Port 8080

Startup mechanism


Scheduled Task: StartWorkloads
  Trigger: At system startup
  Principal: SYSTEM (highest privileges)
  Action: powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\workloads\start-workloads.ps1
start-workloads.ps1 launches all 3 Python scripts as hidden background processes.

Migration validation mapping (Windows vs Fedora)
Check

Fedora (Linux)

Windows

File write continuity

/data/test/log.txt line count

C:\data\test\log.txt line count

SQLite row continuity

/data/test.db row count

C:\data\test\test.db row count

HTTP server alive

curl http://localhost:8080

Invoke-WebRequest http://localhost:8080

Process survival

systemctl status / pgrep

Get-Process python

How It Was Built
Prerequisites
Windows Server 2022 Evaluation ISO copied to a temporary location on the execution host (approximately 4.7GB).

ISO copied to a localblock-sc Block PVC via dd (CDI doesn't work with localblock-sc)

Storage architecture
Disk

Storage class

Volume mode

Why

ISO (boot media)

localblock-sc

Block

UEFI boot requires Block mode; Filesystem mode causes BdsDxe timeout

Root disk (40Gi)

hostpath-csi

Filesystem

Standard VM disk, node-local NVMe

Both storage classes use WaitForFirstConsumer — VM must use nodeSelector to pin to a node that has both PV types available.

VM configuration
4 CPU cores, 8Gi RAM

EFI + Secure Boot, q35 machine type

Hyper-V enlightenments (relaxed, vapic, spinlocks, stimer, etc.)

SATA bus for all disks (Windows compatibility)

Masquerade networking (virtio NIC)

# Select a node that can access both WaitForFirstConsumer PVs.

Installation sequence
Namespace: Created windows-golden-images

ISO PVC: Created localblock-sc Block PVC, copied ISO via oc exec dd

Sysprep secret: autounattend.xml with unattended install (EFI partitions, VirtIO drivers from E:\, local admin account; historical password redacted)

Installer VM: Created with runStrategy: RerunOnFailure

Manual boot: UEFI didn't auto-boot from ISO (sat at firmware menu). Sent keystrokes via virsh send-key to select DVD from Boot Manager

Unattended install: ~20 minutes, autounattend handled partitioning, OS install, OOBE, VirtIO tools

Workload setup: Python + scripts pushed via QEMU guest agent (guest-file-write + guest-exec), no VNC/RDP needed

Reboot test: Verified workloads auto-start via Scheduled Task

Sysprep: First attempt blocked by Microsoft Edge (0x80073cf2). Fixed by removing Edge AppX package, then re-ran sysprep successfully

Clone: CDI DataVolume clone with cdi.kubevirt.io/storage.bind.immediate.requested: "true" annotation (required for WaitForFirstConsumer storage). Completed in ~40 seconds

Cleanup: Deleted installer VM and ISO PVC

Key gotchas
Issue

Root cause

Fix

UEFI didn't boot from ISO

OVMF firmware doesn't auto-boot; shows setup menu on first boot

Navigate Boot Manager via virsh send-key

Filesystem mode ISO causes BdsDxe timeout

QEMU uses slow file-backed I/O for Filesystem PVCs

Use localblock-sc Block mode for ISO

CDI scratch PVC fails with localblock-sc

CDI creates Filesystem scratch PVC, localblock-sc only has Block PVs

Bypass CDI: plain PVC + dd via oc exec

Sysprep error 0x80073cf2

Microsoft Edge installed per-user, not provisioned for all users

Remove-AppxPackage -AllUsers *MicrosoftEdge.Stable* before sysprep

VM restarts after sysprep shutdown

runStrategy: RerunOnFailure treats shutdown as failure

Change to runStrategy: Manual before sysprep

CDI clone stuck at PendingPopulation

hostpath-csi uses WaitForFirstConsumer, CDI can't create pod

Add annotation cdi.kubevirt.io/storage.bind.immediate.requested: "true"

virt-handler stale domain cache

Force-deleting VMs leaves ghost entries

Recreate VM on a different node

Cloning VMs from Golden Image
Two resources are needed per clone:

A DataVolume cloning the golden PVC (with cdi.kubevirt.io/storage.bind.immediate.requested annotation)

A VirtualMachine with a sysprep volume pointing to the OOBE unattend secret

OOBE unattend secret (required)
The golden image is sysprepped with /oobe. Cloned VMs go through Windows OOBE on first boot. Without an unattend, OOBE is interactive (stuck at "Hi there" screen). Mount this secret as a sysprep volume:



apiVersion: v1
kind: Secret
metadata:
  name: win2022-oobe-unattend
  namespace: windows-golden-images
type: Opaque
stringData:
  unattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <InputLocale>en-US</InputLocale>
          <SystemLocale>en-US</SystemLocale>
          <UILanguage>en-US</UILanguage>
          <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideLocalAccountScreen>true</HideLocalAccountScreen>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <ProtectYourPC>3</ProtectYourPC>
          </OOBE>
          <UserAccounts>
            <AdministratorPassword><Value>__REDACTED_ADMIN_PASSWORD__</Value><PlainText>true</PlainText></AdministratorPassword>
            <LocalAccounts>
              <LocalAccount wcm:action="add">
                <Name>admin</Name><Group>Administrators</Group>
                <Password><Value>__REDACTED_ADMIN_PASSWORD__</Value><PlainText>true</PlainText></Password>
              </LocalAccount>
            </LocalAccounts>
          </UserAccounts>
          <AutoLogon>
            <Enabled>true</Enabled><Username>admin</Username>
            <Password><Value>__REDACTED_ADMIN_PASSWORD__</Value><PlainText>true</PlainText></Password>
            <LogonCount>1</LogonCount>
          </AutoLogon>
        </component>
      </settings>
    </unattend>
Important: The file must be named unattend.xml (not autounattend.xml). Windows looks for autounattend.xml during initial install (windowsPE pass) but unattend.xml during OOBE (oobeSystem pass).

VM manifest


apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win-test-0-rootdisk
  namespace: windows-golden-images
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  pvc:
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 40Gi
    storageClassName: hostpath-csi
  source:
    pvc:
      namespace: windows-golden-images
      name: win2022-golden
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win-test-0
  namespace: windows-golden-images
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 4
        features:
          acpi: {}
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
          smm:
            enabled: true
        firmware:
          bootloader:
            efi:
              secureBoot: true
        machine:
          type: q35
        devices:
          disks:
            - disk:
                bus: sata
              name: rootdisk
            - cdrom:
                bus: sata
              name: sysprep
          interfaces:
            - name: default
              masquerade: {}
              model: virtio
        resources:
          requests:
            memory: 8Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: win-test-0-rootdisk
        - name: sysprep
          sysprep:
            secret:
              name: win2022-oobe-unattend
Boot timeline (tested)
Event

Time

Clone completes

~10s

VMI Running

~5s after clone

Guest agent connected

~15s after VMI

OOBE auto-completes

~60-90s

Workloads auto-start (Scheduled Task)

~10s after OOBE

All 3 workloads verified

~2 min total from VM creation

Remote Access Methods
Method

Command

Guest agent (run commands)

virsh qemu-agent-command via oc exec into virt-launcher pod

VNC (graphical)

virtctl vnc <vm> -n windows-golden-images + SSH tunnel

RDP

virtctl port-forward <vm>.windows-golden-images 3389 + SSH tunnel, user admin/<redacted password>

Screenshot

virsh screenshot via oc exec into virt-launcher pod

Guest agent command execution pattern


# Write a script to the VM
HANDLE=$(oc exec <pod> -c compute -- virsh -c qemu:///session qemu-agent-command <domain> \
  '{"execute":"guest-file-open","arguments":{"path":"C:\\script.ps1","mode":"w"}}' | jq -r '.return')
oc exec <pod> -c compute -- virsh -c qemu:///session qemu-agent-command <domain> \
  "{\"execute\":\"guest-file-write\",\"arguments\":{\"handle\":$HANDLE,\"buf-b64\":\"<base64>\"}}"
oc exec <pod> -c compute -- virsh -c qemu:///session qemu-agent-command <domain> \
  "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$HANDLE}}"
# Execute it
PID=$(oc exec <pod> -c compute -- virsh -c qemu:///session qemu-agent-command <domain> \
  '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-ExecutionPolicy","Bypass","-File","C:\\script.ps1"],"capture-output":true}}' | jq -r '.return.pid')
sleep 5
oc exec <pod> -c compute -- virsh -c qemu:///session qemu-agent-command <domain> \
  "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}" | jq -r '.return["out-data"] | @base64d'
