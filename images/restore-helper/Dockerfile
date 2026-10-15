# Restore-verification helper image for scripts/vm-cbt-restore-test.sh.
#
# Provides qemu-img (rebase/convert the CBT backup qcow2 chain to raw),
# qemu-nbd (expose a qcow2 chain as a block device, so the full-size raw
# intermediate can be skipped when the node offers the nbd kernel module),
# kmod (modprobe, to load nbd from inside the privileged pod when the node
# does not already provide it), util-linux (losetup/mount), and ntfs-3g
# (read-only NTFS mounts) to read guest files from the Windows NTFS, Debian
# ext4, and RHEL 9 XFS root filesystems.
FROM registry.fedoraproject.org/fedora:41

RUN dnf install -y --setopt=install_weak_deps=False \
      qemu-img \
      kmod \
      util-linux \
      ntfs-3g \
      findutils \
      coreutils \
      grep \
    && dnf clean all
