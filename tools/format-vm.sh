# format-vm — the whole in-VM half of the format-VM path: disko formats the attached blank
# disk from the host's layout, and the closure is injected as DATA — no target-arch binary
# ever executes, which is what lets an aarch64 image build on an x86 runner with no binfmt.
#
# Runs as root inside vmTools.runInLinuxVM. Everything arrives as env (fv_*): the runner's
# own disko format/mount/unmount scripts, the closure's registration + store-paths, the
# profile toplevel, the ESP manifest (`<source>\t<target>` lines, the fat-image format),
# the target's hostid, and the pool names to verify exported on the way out.
set -euo pipefail

required fv_format fv_mount fv_unmount fv_registration fv_store_paths fv_udevd

# The stage-1 dance from disko's own image builder: without udevd no /dev/vda1 symlink
# ever appears and every mkfs waits forever on a settle that cannot finish.
ln -sfn /proc/self/fd /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr
mkdir -p /etc/udev
mkdir -p /dev/.mdadm
"$fv_udevd/lib/systemd/systemd-udevd" --daemon
udevadm trigger --action=add
udev_settle_timeout=${udev_settle_timeout:-120}
udevadm settle --timeout="$udev_settle_timeout"

# The pool must be born with the TARGET's hostid, or first boot needs `zpool import -f`.
if [ -n "${fv_hostid:-}" ]; then
  zgenhostid "$fv_hostid"
  info "hostid set to $fv_hostid"
fi

# mkfs tools stamp creation times from SOURCE_DATE_EPOCH where they honour it (mke2fs
# does); the kernel's own stamps are the fixed-rtc's business.
export SOURCE_DATE_EPOCH=1
run "disko format" "$fv_format"
run "disko mount" "$fv_mount"

# The pool guid is DERIVED, not the create's random one — the identity rule (every id
# derived from the artifact's name) applied as far as zfs allows; vdev guids stay random,
# which is one of the reasons this path never claims same-bytes.
if [ -n "${fv_pool_guids:-}" ]; then
  read -r -a pool_guids <<< "$fv_pool_guids"
  for pg in "${pool_guids[@]}"; do
    pool=${pg%%:*}
    hex=${pg##*:}
    run "reguid pool $pool" zpool reguid -g "$((16#$hex))" "$pool"
  done
fi

root=/mnt
mkdir -p "$root/nix/store"
count=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  cp -a "$p" "$root/nix/store/"
  count=$((count + 1))
done < "$fv_store_paths"
info "staged $count store paths"

# sqlite is endian-neutral: the RUNNER's nix registers the target-arch paths as data.
unset NIX_REMOTE
run "load nix db" env NIX_STATE_DIR="$root/nix/var/nix" NIX_STORE_DIR=/nix/store \
  nix-store --load-db < "$fv_registration"

# Same normalisation as store-ext4: epoch the registration stamps, checkpoint, compact.
db=$root/nix/var/nix/db/db.sqlite
run "normalise nix db" sqlite3 "$db" \
  "UPDATE ValidPaths SET registrationTime = 1; \
   PRAGMA wal_checkpoint(TRUNCATE); \
   VACUUM INTO '$db.compact';"
rm -f "$db-shm"
rm -f "$db-wal"
mv "$db.compact" "$db"

if [ -n "${fv_profile:-}" ]; then
  mkdir -p "$root/nix/var/nix/profiles" "$root/nix/var/nix/gcroots"
  mkdir -p "$root/etc" "$root/var" "$root/run" "$root/proc" "$root/sys" "$root/dev" "$root/tmp"
  chmod 1777 "$root/tmp"
  ln -sfn "$fv_profile" "$root/nix/var/nix/profiles/system-1-link"
  ln -sfn system-1-link "$root/nix/var/nix/profiles/system"
  ln -sfn /nix/var/nix/profiles "$root/nix/var/nix/gcroots/profiles"
  touch "$root/etc/NIXOS"
  info "profile -> $fv_profile"
fi

if [ -n "${fv_esp_manifest:-}" ]; then
  esp_mount=${fv_esp_mount:?esp manifest without a mountpoint}
  while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] || continue
    [ -e "$src" ] || fatal "format-vm: esp source missing: $src"
    install -m 0644 -D "$src" "$root$esp_mount$dst"
  done < "$fv_esp_manifest"
  info "esp populated at $esp_mount"
fi

# The layout as BUILT, in gpt-disk's row format, read off the kernel's own view.
disk=${fv_disk:-/dev/vda}
lsblk --json --bytes --output NAME,PARTLABEL,FSTYPE,START,SIZE "$disk" \
  | jq '[.blockdevices[0].children[]?
         | { label: (.partlabel // .name),
             fs: (if .fstype == "zfs_member" then "zfs"
                  elif .fstype == null then "none"
                  else .fstype end),
             startByte: ((.start // 0) * 512),
             sizeByte: .size }]' > /tmp/xchg/layout.json

run "disko unmount" "$fv_unmount"

# disko's unmount exports the pool; a pool still imported here would carry THIS boot's
# in-use state into the artifact, so absence is verified, not assumed.
if [ -n "${fv_pools:-}" ]; then
  read -r -a pools <<< "$fv_pools"
  for p in "${pools[@]}"; do
    if zpool list -H -o name "$p" > /dev/null 2>&1; then
      run "export pool $p" zpool export "$p"
    fi
  done
fi
