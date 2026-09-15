# Deterministic e2e capture — a HARNESS helper, not a tool: no block receives it. Appends a
# witness line to the vfat "result" disk the harness attaches (stable virtio serial e2eout),
# instead of racing serial output that a fast guest can lose before qemu drains it. The
# harness reads the disk with mtools after qemu exits. Test hosts wire it into their marker
# units, and into the install block's `report` seam.
{ pkgs }:

pkgs.writeShellScriptBin "e2e-record" ''
  set -eu
  dev=/dev/disk/by-id/virtio-e2eout
  [ -e "$dev" ] || { echo "e2e-record: no result disk" >&2; exit 0; }
  mnt=/run/e2e-out
  # Mount ONCE and leave it: a mount/umount per call races the vfat ("device busy" on the
  # next mount before writeback settles) and silently drops lines. Shutdown unmounts and
  # flushes; the per-write sync is belt-and-braces.
  ${pkgs.coreutils}/bin/mkdir -p "$mnt"
  ${pkgs.util-linux}/bin/mountpoint -q "$mnt" \
    || ${pkgs.util-linux}/bin/mount -t vfat -o rw "$dev" "$mnt"
  ${pkgs.coreutils}/bin/printf '%s\n' "$*" >> "$mnt/log"
  ${pkgs.coreutils}/bin/sync
''
