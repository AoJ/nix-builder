# action-install — deliver a system onto its target from a RAM install environment. One
# act, two ways of delivering, chosen by what the caller carries:
#
#   image    a finished disk, streamed onto the target as it is. What it holds is never
#            looked at — a NixOS host, another operating system, anything that boots.
#   closure  store paths installed onto storage the target's own recipe creates, for a
#            layout no image can hold (a zfs pool, whose identity is a kernel object).
#
#   action-install <createScript> <mountScript> <toplevel> <slotName> <slotFiles> \
#     <storage> <pool> <encrypted> <disk>...
#
# createScript brings the target's storage into existence AND mounts it at /mnt (disko's
# create, or an equivalent). mountScript mounts an already-present target at /mnt — the
# never-reformat probe. The disks are the block devices the target lives on: wiped before a
# create, never touched on the mount path.
#
# The image way takes `payload_image` and `payload_bytes` from the environment instead of
# the create/mount pair, and never mounts the target at all.
#
# The SLOT is the only thing this carries: the caller lays the installer's own slot out at
# /run/slot, the host's own storage scripts read from there whatever they need, and the act
# copies the same files into the partition named slotName on the target — so the installed
# system finds its secrets exactly where it would have, had the image written the slot.
# Nothing here reads a file's content or knows what any of them are for; slotFiles lists
# the paths the host said would be there, and arrival is all that is checked.
#
# install_wipe=yes is the caller's explicit reinstall intent: the create path is taken and
# the declared disks are cleared even when a target is already present.
set -euo pipefail

create=${1:-}
mounts=${2:-}
toplevel=${3:-}
slot_name=${4:-}
slot_files=${5:-}
storage=${6:-}
pool=${7:-}
encrypted=${8:-}

[ "$#" -ge 9 ] || fatal "usage: action-install <create> <mount> <toplevel> <slotName>" \
  "<slotFiles> <storage> <pool> <encrypted> <disk>..."
shift 8
disks=("$@")
required slot_name slot_files storage
payload_image=${payload_image:-}
if [ -n "$payload_image" ]; then
  kind=image
  [ "${#disks[@]}" = 1 ] \
    || fatal "an image is one disk written as it is; this install declares ${#disks[@]}"
  # The image's own header says how big it unpacks to — one source of truth, and it holds
  # for an image from anywhere, not just one this repo built.
  sc=0
  listing=$(timeout 60 zstd -lv "$payload_image") || sc=$?
  [ "$sc" = 0 ] || fatal "cannot read the image's header: $payload_image"
  payload_bytes=$(awk -F'[()]' '/Decompressed Size/ { split($2, a, " "); print a[1] }' \
    <<< "$listing")
  case "$payload_bytes" in
    "" | *[!0-9]*) fatal "the image declares no decompressed size: $payload_image" ;;
  esac
else
  kind=closure
  required create mounts toplevel encrypted
  [ "$storage" != zfs ] || required pool
  [ "$encrypted" = true ] || [ "$encrypted" = false ] \
    || fatal "encrypted must be true or false, got '$encrypted'"
fi
install_wipe=${install_wipe:-no}

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
#   4. Everything the host said its slot carries actually arrived: an installer nobody
#      personalized must not wipe a disk and discover it afterwards. What the files ARE
#      is never looked at — only that they are there.
capability_gate() {
  local disk dev typ sz capacity=0
  local tmp_req tmp_du closure_bytes required want
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    [ -e "/run/slot$want" ] || fatal "the slot carries no $want — this installer was" \
      "never personalized; refusing before any wipe"
  done < "$slot_files"
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

  if [ "$kind" = image ]; then
    # An image is written as it is, so it must FIT — no headroom arithmetic, just the
    # disk being at least as large as what goes on it.
    if [ "$payload_bytes" -gt "$capacity" ]; then
      fatal "the image needs $payload_bytes bytes but the declared disk holds $capacity" \
        "— refusing before any write"
    fi
    info "capability gate ok: image $payload_bytes bytes, disk $capacity bytes"
    return 0
  fi

  tmp_req=$(mktemp)
  add_cleanup "rm -f '$tmp_req'"
  tmp_du=$(mktemp)
  add_cleanup "rm -f '$tmp_du'"
  # ONE du invocation over the whole closure: du de-duplicates hardlinks only within a
  # single call, and the store is hardlink-woven — a split (xargs) sum overcounts.
  nix-store -q --requisites "$toplevel" | tr '\n' '\0' > "$tmp_req"
  du -sb --files0-from="$tmp_req" > "$tmp_du"
  closure_bytes=$(awk '{ s += $1 } END { printf "%d", s }' "$tmp_du")
  [ "$closure_bytes" -gt 0 ] || fatal "cannot size the carried closure"
  required=$((closure_bytes + closure_bytes / 5 + install_reserve_bytes))
  if [ "$required" -gt "$capacity" ]; then
    fatal "the carried closure needs ~$required bytes (closure $closure_bytes + headroom)" \
      "but the declared disks hold $capacity — refusing before any format"
  fi
  info "capability gate ok: closure $closure_bytes bytes, disks $capacity bytes"
}

# The image way: clear the disk, stream the image onto it, and make the table whole again.
# Nothing is mounted and nothing is read out of what was written — this is a delivery, not
# an installation.
write_image() {
  local disk=${disks[0]} dev
  dev=$(readlink -f "$disk") || fatal "cannot resolve declared disk $disk"
  info "writing the image to $disk ($payload_bytes bytes)"
  run "wipe $disk" action-wipe "$disk"
  # Decompressed straight onto the disk: a 1.4 GB image would otherwise need that much
  # free memory in an installer that has no disk of its own to spill to.
  run "write image" zstdcat_to_disk "$payload_image" "$dev"
  best_effort "flush buffers" sync
  # A disk larger than the image leaves GPT's backup header where the image ended, which
  # is not the end of this disk. -e moves it; without it every later tool reports a
  # corrupt table.
  best_effort "move the GPT backup header to the end of $disk" sgdisk -e "$dev"
  best_effort "reread partition tables" partprobe "$dev"
  udevadm settle
}

# A function rather than a pipeline at the call site: `run` takes ONE command, and a
# pipeline's failure would otherwise be the last stage's alone.
zstdcat_to_disk() {
  set -o pipefail
  zstd -dc "$1" | dd of="$2" bs=4M conv=fsync status=none
}

wipe_and_create() {
  info "wiping ${disks[*]} and creating $storage (this formats the disks)"
  run "wipe ${disks[*]}" action-wipe "${disks[@]}"
  # No timeout: create is a destructive, non-rerunnable write — killing it mid-flight
  # manufactures exactly the half-written state the probe exists to prevent.
  run "create $storage" "$create"
}

# Bring the target up at /mnt: never reformat what is already installed there — unless
# the caller carries explicit reinstall intent, which takes the create path regardless of
# what the probe would find. The intent runs AFTER the gate: refused means untouched even
# for a reinstall.
prepare_target() {
  local enc
  if [ "$install_wipe" = yes ]; then
    wipe_and_create
    return
  fi
  if [ "$storage" = zfs ]; then
    # `zpool import` doubles as the probe — the pool is the thing that persists.
    if timeout 120 zpool import -f "$pool" 2> /dev/null; then
      # The found pool must MATCH the host's declaration. Continuing across the mismatch
      # would land an encrypted host on a plain pool without a single error — refuse, and
      # leave the pool as found; a reinstall is an explicit wipe, never an accident.
      enc=$(timeout 30 zfs get -H -o value encryption "$pool") \
        || fatal "cannot read encryption state of $pool"
      if [ "$encrypted" = true ] && [ "$enc" = off ]; then
        timeout 120 zpool export "$pool"
        fatal "pool $pool exists UNENCRYPTED but this host expects an encrypted pool" \
          "— wipe first to reinstall"
      fi
      if [ "$encrypted" = false ] && [ "$enc" != off ]; then
        timeout 120 zpool export "$pool"
        fatal "pool $pool exists ENCRYPTED but this host expects a plain pool" \
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

# The target's slot: the partition the host's layout named, found among the DECLARED disks
# so a same-named partition on the installer's own medium cannot be mistaken for it. The
# files go in as they came; this runs before nixos-install, so anything the installed
# system builds from them (an initrd secret, say) sees them already in place.
place_slot() {
  local disk dev part label target="" mnt="" own=no sc=0
  if [ -z "$(find /run/slot -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null)" ]; then
    info "the slot carries nothing -> the target's slot stays as the layout made it"
    return 0
  fi
  for disk in "${disks[@]}"; do
    dev=$(readlink -f "$disk") || fatal "cannot resolve declared disk $disk"
    while IFS= read -r part; do
      sc=0
      label=$(timeout 30 lsblk -nlo PARTLABEL --nodeps "$part") || sc=$?
      [ "$sc" = 0 ] || continue
      [ "$label" = "$slot_name" ] || continue
      target=$part
      break
    done < <(timeout 30 lsblk -npo PATH "$dev" | tail -n +2)
    [ -z "$target" ] || break
  done
  [ -n "$target" ] || fatal "the target declares no partition named $slot_name," \
    "so the installed system would have no slot to read its secrets from"

  # A host whose storage scripts already mounted its slot under /mnt keeps that mount:
  # anything the install itself builds from the slot — an initrd secret, say — reads it
  # through the host's own path, and a second mount of the same partition would hide the
  # files from exactly the step that needs them. findmnt exits nonzero when nothing is
  # mounted, which is a normal answer here and must not end the script through errexit.
  sc=0
  mnt=$(timeout 30 findmnt -nro TARGET --first-only --source "$target") || sc=$?
  if [ "$sc" != 0 ] || [ -z "$mnt" ]; then
    own=yes
    mnt=$(mktemp -d)
    add_cleanup "rmdir '$mnt' 2> /dev/null || true"
    run "mount the target's slot" timeout 60 mount "$target" "$mnt"
  fi
  cp -a /run/slot/. "$mnt/"
  [ "$own" = no ] || run "unmount the target's slot" timeout 60 umount "$mnt"
  info "slot placed on $target at $mnt"
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

info "action-install starting: $kind delivery, storage=$storage${pool:+ pool=$pool}" \
  "slot=$slot_name"
capability_gate
if [ "$kind" = image ]; then
  write_image
  place_slot
  info "action-install done — the image is on the disk"
else
  prepare_target
  place_slot
  install_system
  teardown
  info "action-install done — $storage installed cleanly"
fi
