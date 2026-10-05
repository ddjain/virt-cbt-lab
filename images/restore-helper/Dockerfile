# Restore-verification helper image for scripts/vm-cbt-restore-test.sh.
#
# Provides qemu-img (rebase/convert the CBT backup qcow2 chain to raw),
# util-linux (losetup/mount), and ntfs-3g (read-only NTFS mounts) to read
# guest files from the Windows NTFS, Debian ext4, and RHEL 9 XFS root filesystems.
FROM registry.fedoraproject.org/fedora:41

RUN dnf install -y --setopt=install_weak_deps=False \
      qemu-img \
      util-linux \
      ntfs-3g \
      findutils \
      coreutils \
      grep \
    && dnf clean all
