# store-ext4 — an ext4 filesystem carrying a registered nix store, with no root, no loop
# device, no VM and no target-arch execution. With a profile toplevel it is a bootable NixOS
# ROOT; without one it is a bare store filesystem.
#
#   store-ext4 <out> <label> <uuid> <registration> <store-paths> [<profile-toplevel>]
#
# Three things here are not obvious and each one cost a boot to learn:
#
#   * THE NIX DB. A store is not just files — /nix/var/nix/db must list every path as valid,
#     or the system boots into something that cannot answer `nix-store -q`. The db is plain
#     sqlite and endian-neutral, so `closureInfo`'s `registration` dump loads into a staged
#     NIX_STATE_DIR on ANY architecture (nixpkgs does the same at make-disk-image.nix).
#   * OWNERSHIP WITHOUT ROOT. `mke2fs -d` records whatever uid/gid it sees, so a tree copied
#     by a normal user yields a filesystem owned by that user. fakeroot fixes it without
#     privileges — but it works by LD_PRELOAD, so the whole chain must be dynamically linked
#     against the same libc, which is why this re-execs ITSELF (a nix bash) rather than
#     wrapping the individual commands.
#   * INODES. The default inode ratio is sized for ordinary data; a store closure is ~130k
#     small files per GiB and mke2fs dies with "Could not allocate inode". -N is computed
#     from the actual file count, not guessed.
set -euo pipefail

# fakeroot is entered once, around everything: a chown under one fakeroot is invisible to a
# second one, so staging and mke2fs must share a single session.
if [ "${store_ext4_fakeroot:-0}" != 1 ]; then
  export store_ext4_fakeroot=1
  exec fakeroot "$0" "$@"
fi

out=${1:?usage: store-ext4 <out> <label> <uuid> <registration> <store-paths> [<profile>]}
label=${2:?missing label}
uuid=${3:?missing uuid}
registration=${4:?missing registration}
store_paths=${5:?missing store-paths file}
profile=${6:-}

root=$PWD/ext4-root
rm -rf "$root"
mkdir -p "$root"/nix/store

count=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  cp -a "$p" "$root/nix/store/"
  count=$((count + 1))
done < "$store_paths"
info "staged $count store paths"

# sqlite is endian-neutral, so the architecture of THIS machine is irrelevant to the db.
run "load nix db" env NIX_STATE_DIR="$root/nix/var/nix" NIX_STORE_DIR=/nix/store \
  nix-store --load-db < "$registration"

# The db as sqlite leaves it is not reproducible, in three ways, all measured: `--load-db`
# stamps every row with the wall clock (registrationTime), a 32 KiB -shm of mmap state sits
# beside the file, and the file itself carries a change counter plus whatever its last write
# left in unused space. So: date the registrations at the epoch (nothing at runtime reads
# them — it is a gc-by-age hint), checkpoint so no row is lost, and VACUUM INTO a fresh file,
# which has no history to differ in. nix re-enables WAL itself the first time it opens it.
db=$root/nix/var/nix/db/db.sqlite
run "normalise nix db" sqlite3 "$db" \
  "UPDATE ValidPaths SET registrationTime = 1; \
   PRAGMA wal_checkpoint(TRUNCATE); \
   VACUUM INTO '$db.compact';"
rm -f "$db-shm"
rm -f "$db-wal"
mv "$db.compact" "$db"

if [ -n "$profile" ]; then
  # The system profile as `nix-env --set` leaves it: a numbered generation link plus the
  # `system` symlink. A direct system -> toplevel symlink boots fine but leaves
  # `nix-env --list-generations` empty, which systemd-boot-builder reads on the first switch.
  mkdir -p "$root"/nix/var/nix/profiles "$root"/nix/var/nix/gcroots
  mkdir -p "$root"/etc "$root"/var "$root"/run "$root"/proc "$root"/sys "$root"/dev "$root"/tmp
  mkdir -p "$root"/boot
  chmod 1777 "$root"/tmp
  ln -sfn "$profile" "$root/nix/var/nix/profiles/system-1-link"
  ln -sfn system-1-link "$root/nix/var/nix/profiles/system"
  ln -sfn /nix/var/nix/profiles "$root/nix/var/nix/gcroots/profiles"
  touch "$root/etc/NIXOS"
fi

chown -R 0:0 "$root"
# Canonical times on the staged tree — nix's own "1 second past the epoch". A tree built by
# mkdir/cp otherwise carries the wall clock, and mke2fs copies atime/mtime straight off it.
find "$root" -exec touch -h -d @1 {} +

# Size from the FILES, not from `du`: du reports ALLOCATED blocks, which depend on the
# builder's own filesystem (sparseness, block size), so two builders sized the same tree
# differently and the image was not reproducible — measured, 1.38 vs 1.32 GiB for one
# closure. Summing ceil(size/4KiB) per file is deterministic and tighter than du's rounding.
find "$root" -type f -printf '%s\n' > file-sizes
find "$root" -type d -printf 'd\n' > dir-list
find "$root" -printf 'e\n' > entry-list
data_blocks=$(awk '{ n += int(($1 + 4095) / 4096) } END { print n + 0 }' file-sizes)
dirs_count=$(wc -l < dir-list)
entries=$(wc -l < entry-list)
# 30% slack for the first switch's new generation, plus 64 MiB of floor for a tiny closure.
blocks=$(((data_blocks + dirs_count) * 130 / 100 + 16384))
inodes=$((entries * 12 / 10 + 8192))
info "ext4: $blocks x 4KiB blocks, $inodes inodes, from $entries entries"

# A fixed uuid + hash seed is what makes two builds of the same image byte-identical; both
# are derived per image by the caller, never shared, so two hosts never answer the same
# by-uuid. no_copy_xattrs: on a SELinux host mke2fs reads security.selinux off the staged
# tree and aborts; the label has no meaning inside the image anyway.
#
# SOURCE_DATE_EPOCH=1, not the stdenv's 1980: mke2fs stamps the creation times with it and
# clamps each copied time to it, so the whole image reads 1 like the staged tree above. Both
# halves are needed and neither alone is enough — measured: on a builder mounted `relatime`,
# mke2fs's OWN read of each file bumps its atime past the canonical value, and only the
# clamp brings it back. Nothing reads these times; nix normalises the store to 1 itself.
run "mke2fs" env SOURCE_DATE_EPOCH=1 mke2fs -q -t ext4 -b 4096 -N "$inodes" -L "$label" \
  -U "$uuid" -E "no_copy_xattrs,hash_seed=$uuid,root_owner=0:0" -d "$root" -F "$out" "$blocks"
