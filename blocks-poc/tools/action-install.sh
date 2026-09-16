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

# Filesystem headroom the target must hold beyond the closure: ESP, slot, metadata.
install_reserve_bytes=${install_reserve_bytes:-1073741824}

# THE CAPABILITY GATE, before even the probe: refuse up front what this install cannot do,
# so nothing destructive ever starts. None of this is an eval fact — disk identities,
# mounts and sizes exist only on the machine.
#   1. Every declared disk exists and is a WHOLE disk: an absent member would otherwise
#      surface as a mid-format failure — or a partial format of the members present.
#   2. No declared disk carries the RUNNING system: a disk with mounts is the one we
#      booted from, and the probe cannot be trusted to catch it — its mount path would
#      mount a disk-rooted installer's own root at /mnt and "find" a present target.
#      A memory-rooted installer holds no disk and passes vacuously.
#   3. The carried closure fits the declared capacity: otherwise nixos-install hits
#      ENOSPC after the format — exactly the mid-flight failure the gate exists to stop.
capability_gate() {
  local disk dev typ sz capacity=0
  local tmp_req tmp_du closure_bytes required
  for disk in "${disks[@]}"; do
    dev=$(readlink -f "$disk") || fatal "cannot resolve declared disk $disk"
    [ -b "$dev" ] || fatal "declared disk $disk is absent — refusing before any format"
    typ=$(timeout 30 lsblk -ndo TYPE "$dev") || fatal "cannot classify declared disk $disk"
    [ "$typ" = disk ] || fatal "declared disk $disk is a $typ, not a whole disk"
    if timeout 30 lsblk -rno MOUNTPOINTS "$dev" | grep -q .; then
      fatal "declared disk $disk carries the running system — refusing to install over it"
    fi
    sz=$(timeout 30 blockdev --getsize64 "$dev") || fatal "cannot size declared disk $disk"
    capacity=$((capacity + sz))
  done

  tmp_req=$(mktemp)
  add_cleanup "rm -f '$tmp_req'"
  tmp_du=$(mktemp)
  add_cleanup "rm -f '$tmp_du'"
  nix-store -q --requisites "$toplevel" > "$tmp_req"
  xargs -r -a "$tmp_req" du -sb > "$tmp_du"
  closure_bytes=$(awk '{ s += $1 } END { printf "%d", s }' "$tmp_du")
  [ "$closure_bytes" -gt 0 ] || fatal "cannot size the carried closure"
  required=$((closure_bytes + closure_bytes / 5 + install_reserve_bytes))
  if [ "$required" -gt "$capacity" ]; then
    fatal "the carried closure needs ~$required bytes (closure $closure_bytes + headroom)" \
      "but the declared disks hold $capacity — refusing before any format"
  fi
  info "capability gate ok: closure $closure_bytes bytes, disks $capacity bytes"
}

wipe_and_create() {
  info "$storage target absent -> wiping ${disks[*]} and creating (this formats the disks)"
  run "wipe ${disks[*]}" action-wipe "${disks[@]}"
  # No timeout: create is a destructive, non-rerunnable write — killing it mid-flight
  # manufactures exactly the half-written state the probe exists to prevent.
  run "create $storage" "$create"
}

# Bring the target up at /mnt: never reformat what is already installed there.
prepare_target() {
  local enc
  if [ "$storage" = zfs ]; then
    # `zpool import` doubles as the probe — the pool is the thing that persists.
    if timeout 120 zpool import -f "$pool" 2> /dev/null; then
      # The found pool must MATCH what this host expects: a delivered pool passphrase
      # means an encrypted pool, and vice versa. Continuing across the mismatch would
      # land an encrypted host on a plain pool without a single error — refuse, and
      # leave the pool as found; a reinstall is an explicit wipe, never an accident.
      enc=$(timeout 30 zfs get -H -o value encryption "$pool") \
        || fatal "cannot read encryption state of $pool"
      if [ -f /tmp/zfs_root_key ] && [ "$enc" = off ]; then
        timeout 120 zpool export "$pool"
        fatal "pool $pool exists UNENCRYPTED but this host expects an encrypted pool" \
          "— wipe first to reinstall"
      fi
      if [ ! -f /tmp/zfs_root_key ] && [ "$enc" != off ]; then
        timeout 120 zpool export "$pool"
        fatal "pool $pool exists ENCRYPTED but no pool passphrase was delivered" \
          "— wipe first to reinstall"
      fi
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
capability_gate
prepare_target
place_sops_key
install_system
teardown
info "action-install done — $storage installed cleanly"
