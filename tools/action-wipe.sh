# action-wipe <disk>... — clear block devices for a fresh format. Releases every holder
# first (swap, a stale /mnt, imported pools, md arrays) — a holder cannot be released while
# something above it still uses it, so the order matters. Then each device is deep-cleared:
# a signature sitting INSIDE an old partition survives a plain wipefs and makes a later
# create see a disk in use, so all blocks are discarded (or the ends zeroed where discard
# is unsupported) before the partition table is zapped.
#
# BOTH ENDS, always: the structures that outlive a write to the head all live at the tail —
# GPT's backup header sits in the last sector, zfs keeps two of its four vdev labels at the
# end, mdadm 0.90 puts its superblock there. Anything smaller than the disk (an image
# written to it, a smaller layout) leaves those behind, and udev then sees two truths about
# one disk.
set -euo pipefail

# Bytes cleared at each end when discard is unavailable. Generous on purpose: it costs a
# second and covers every tail structure above.
wipe_ends_bytes=${wipe_ends_bytes:-$((64 * 1024 * 1024))}

zero_ends() {
  local dev=$1 size chunk seek
  local sc=0
  size=$(blockdev --getsize64 "$dev") || sc=$?
  if [ "$sc" != 0 ] || [ -z "$size" ]; then
    error "cannot size $dev — zeroing the head only"
    best_effort "zero head of $dev" \
      dd if=/dev/zero of="$dev" bs=1M count=$((wipe_ends_bytes / 1048576)) conv=fsync
    return 0
  fi
  chunk=$wipe_ends_bytes
  # A disk smaller than two chunks is cleared in one pass rather than twice over itself.
  if [ "$size" -le $((chunk * 2)) ]; then
    best_effort "zero all of $dev" dd if=/dev/zero of="$dev" bs=1M conv=fsync
    return 0
  fi
  best_effort "zero head of $dev" \
    dd if=/dev/zero of="$dev" bs=1M count=$((chunk / 1048576)) conv=fsync
  seek=$(( (size - chunk) / 1048576 ))
  best_effort "zero tail of $dev" \
    dd if=/dev/zero of="$dev" bs=1M count=$((chunk / 1048576)) seek="$seek" conv=fsync
}

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

# THE GATE, after the holder release and before the first destructive byte: a disk that
# still has mounts now is the one the running system lives on — refuse it. Standalone
# callers get the same protection action-install applies up front.
for disk in "$@"; do
  [ -e "$disk" ] || continue
  if lsblk -rno MOUNTPOINTS "$(readlink -f "$disk")" | grep -q .; then
    fatal "$disk carries the running system — refusing to wipe it"
  fi
done

for disk in "$@"; do
  if [ ! -e "$disk" ]; then
    info "wipe: $disk absent -> skipping"
    continue
  fi
  info "wipe: clearing $disk"
  # Enumerate the disk's OWN partitions via the kernel, never a name glob: /dev/sda?*
  # also matches /dev/sdaa — a different disk, and this must clear exactly the named ones.
  mapfile -t parts < <(lsblk -npo PATH "$(readlink -f "$disk")" | tail -n +2)
  for part in "${parts[@]}"; do
    best_effort "wipefs $part" wipefs -af "$part"
  done
  best_effort "wipefs $disk" wipefs -af "$disk"
  if ! blkdiscard -f "$disk" 2> /dev/null; then
    zero_ends "$(readlink -f "$disk")"
  fi
  # Zaps both the primary table and the backup header in the last sector.
  best_effort "zap partition table on $disk" sgdisk --zap-all "$disk"
done
best_effort "reread partition tables" partprobe
udevadm settle
info "wipe: done ($*)"
