# Restore-verification helper image for scripts/vm-cbt-restore-test.sh.
#
# Provides qemu-img (rebase/convert the CBT backup qcow2 chain to raw) and
# util-linux (losetup/mount) to read the guest file straight off the demo
# VM's ext4 root filesystem via a loop device.
FROM registry.fedoraproject.org/fedora:41

RUN dnf install -y --setopt=install_weak_deps=False \
      qemu-img \
      util-linux \
      findutils \
      coreutils \
      grep \
    && dnf clean all
