# Restore-verification helper image for scripts/vm-cbt-restore-test.sh.
#
# Provides qemu-img (rebase/convert the CBT backup qcow2 chain to raw) and
# btrfs-progs' `btrfs restore` (extracts files directly from a btrfs
# filesystem's on-disk format via a loop device, without needing a btrfs
# kernel module — RHEL/CentOS-family kernels and libguestfs appliances built
# on them do not ship one, which is why this repo does not use guestfish for
# btrfs guest disks).
FROM registry.fedoraproject.org/fedora:41

RUN dnf install -y --setopt=install_weak_deps=False \
      qemu-img \
      btrfs-progs \
      util-linux \
      findutils \
      coreutils \
      grep \
    && dnf clean all
