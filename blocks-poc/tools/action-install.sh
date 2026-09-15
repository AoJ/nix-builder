# action-install — install a system onto its target from a RAM install environment.
#
#   action-install <createScript> <mountScript> <toplevel> <keyDest> <storage> <pool> <disk>...
#
# createScript brings the target's storage into existence AND mounts it at /mnt (disko's
# create, or an equivalent). mountScript mounts an already-present target at /mnt — the
# never-reformat probe. The disks are the block devices the target lives on: wiped before a
# create, never touched on the mount path. The caller pre-delivers /run/sops.age (the
# installed system's age key, optional) and, for an encrypted pool, /tmp/zfs_root_key
# (createScript reads it).
set -euo pipefail

create=${1:-}
mounts=${2:-}
toplevel=${3:-}
key_dest=${4:-}
storage=${5:-}
pool=${6:-}

[ "$#" -ge 7 ] || fatal "usage: action-install <create> <mount> <toplevel> <keyDest> <storage> <pool> <disk>..."
shift 6
disks=("$@")
required create mounts toplevel key_dest storage
[ "$storage" != zfs ] || required pool

wipe_and_create() {
  info "$storage target absent -> wiping ${disks[*]} and creating (this formats the disks)"
  run "wipe ${disks[*]}" action-wipe "${disks[@]}"
  # No timeout: create is a destructive, non-rerunnable write — killing it mid-flight
  # manufactures exactly the half-written state the probe exists to prevent.
  run "create $storage" "$create"
}

# Bring the target up at /mnt: never reformat what is already installed there.
prepare_target() {
  if [ "$storage" = zfs ]; then
    # `zpool import` doubles as the probe — the pool is the thing that persists.
    if timeout 120 zpool import -f "$pool" 2> /dev/null; then
      info "pool $pool already exists -> mounting (no reformat)"
      timeout 120 zpool export "$pool"
      run "mount $pool" "$mounts"
    else
      wipe_and_create
    fi
  else
    # The mount script is the probe: it succeeds on an installed target, fails on a fresh
    # disk. A failed probe is not all-or-nothing — it can leave a partial tree under /mnt —
    # so the create path starts with the wipe's holder release, /mnt included.
    if timeout 120 "$mounts" 2> /dev/null; then
      info "$storage target already present -> mounting (no reformat)"
    else
      wipe_and_create
    fi
  fi
}

place_sops_key() {
  if [ -f /run/sops.age ]; then
    info "placing sops age key -> /mnt$key_dest"
    install -D -m600 /run/sops.age "/mnt$key_dest"
  else
    info "no /run/sops.age delivered -> skipping sops key"
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
