# action-wipe <disk>... — clear block devices for a fresh format. Releases every holder
# first (swap, a stale /mnt, imported pools, md arrays) — a holder cannot be released while
# something above it still uses it, so the order matters. Then each device is deep-cleared:
# a signature sitting INSIDE an old partition survives a plain wipefs and makes a later
# create see a disk in use, so all blocks are discarded (or the head zeroed where discard
# is unsupported) before the partition table is zapped.
set -euo pipefail

[ "$#" -ge 1 ] || fatal "usage: action-wipe <disk>..."

best_effort "swapoff" swapoff -a
if mountpoint -q /mnt; then
  best_effort "umount stale /mnt" umount -R /mnt
fi
if command -v zpool > /dev/null 2>&1; then
  best_effort "export imported pools" zpool export -a
fi
if command -v mdadm > /dev/null 2>&1; then
  best_effort "stop md arrays" mdadm --stop --scan
fi

for disk in "$@"; do
  if [ ! -e "$disk" ]; then
    info "wipe: $disk absent -> skipping"
    continue
  fi
  info "wipe: clearing $disk"
  for part in "$disk"?*; do
    [ -e "$part" ] || continue
    best_effort "wipefs $part" wipefs -af "$part"
  done
  if ! blkdiscard -f "$disk" 2> /dev/null; then
    best_effort "wipefs $disk" wipefs -af "$disk"
    best_effort "zero head of $disk" dd if=/dev/zero of="$disk" bs=1M count=2048 conv=fsync
  fi
  best_effort "zap partition table on $disk" sgdisk --zap-all "$disk"
done
best_effort "reread partition tables" partprobe
udevadm settle
info "wipe: done ($*)"
