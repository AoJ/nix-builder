# action-install — install a host onto its disk from a RAM install environment. Taken from
# lib/50_install/niximilate-install.sh (well-tested) and made SHAPE-AWARE: the zfs path is
# preserved as it was (import-probe, clean export — a half-exported pool boots to
# emergency), and a generic path is added for a plain filesystem (ext4), whose probe is the
# mount script itself and whose teardown is a plain unmount.
#
#   action-install <createScript> <mountScript> <toplevel> <keyDest> <storage> <pool>
#
# createScript brings the target's storage into existence AND mounts it at /mnt (disko's
# create, or an equivalent). mountScript mounts an already-present target at /mnt. The
# caller pre-delivers /run/niximilate-sops.age (the host's age key, optional) and, for an
# encrypted pool, /tmp/zfs_root_key (createScript reads it).
set -euo pipefail

create=${1:-}
mounts=${2:-}
toplevel=${3:-}
key_dest=${4:-}
storage=${5:-}
pool=${6:-}

[ "$#" -eq 6 ] || fatal "usage: action-install <create> <mount> <toplevel> <keyDest> <storage> <pool>"
required create mounts toplevel key_dest storage

# Bring the target up at /mnt: never reformat what is already installed there.
prepare_target() {
  if [ "$storage" = zfs ]; then
    # `zpool import` doubles as the probe — the pool is the thing that persists.
    if timeout 120 zpool import -f "$pool" 2>/dev/null; then
      info "pool $pool already exists -> mounting (no reformat)"
      timeout 120 zpool export "$pool"
      run "mount $pool" "$mounts"
    else
      info "pool $pool absent -> creating (this formats the disk)"
      run "create $pool" timeout 600 "$create"
    fi
  else
    # Generic filesystem: the mount script is the probe. It succeeds on an installed
    # target and fails on a fresh disk, at which point we create.
    if timeout 120 "$mounts" 2>/dev/null; then
      info "$storage target already present -> mounting (no reformat)"
    else
      info "$storage target absent -> creating (this formats the disk)"
      run "create $storage" timeout 600 "$create"
    fi
  fi
}

place_sops_key() {
  if [ -f /run/niximilate-sops.age ]; then
    info "placing sops age key -> /mnt$key_dest"
    install -D -m600 /run/niximilate-sops.age "/mnt$key_dest"
  else
    info "no /run/niximilate-sops.age delivered -> skipping sops key"
  fi
}

install_system() {
  run "nixos-install" timeout 3600 \
    nixos-install --root /mnt --system "$toplevel" --no-root-passwd --no-channel-copy
}

# Tear down cleanly so the installed system comes up on its own. nixos-install leaves chroot
# binds under /mnt that keep the storage busy, so unmount the whole tree first; a zfs pool
# additionally must be EXPORTED (a still-imported pool boots the installed system to
# emergency), which a plain filesystem has no equivalent of.
teardown() {
  info "unmounting /mnt"
  timeout 120 umount -R /mnt
  if [ "$storage" = zfs ]; then
    info "exporting $pool"
    timeout 120 zpool export "$pool"
    if timeout 30 zpool list "$pool" >/dev/null 2>&1; then
      fatal "$pool still imported after export — installed system would boot to emergency"
    fi
  fi
}

info "action-install starting: storage=$storage${pool:+ pool=$pool} system=$toplevel"
prepare_target
place_sops_key
install_system
teardown
info "action-install done — $storage installed cleanly"
