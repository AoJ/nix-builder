{ pkgs }:

{ name, rootPaths, shape, label }:

let
  inherit (pkgs) lib;
  ids = import ./ids.nix;

  closure = pkgs.closureInfo { rootPaths = rootPaths; };

  # The path a squashfs store's dump sits at. A nixpkgs convention
  # (nixos/lib/make-squashfs.nix), read back by nixpkgs' own units
  # (netboot.nix, iso-image.nix). Both sides take it from nixpkgs, not
  # from each other, which is why no dependency runs between them.
  registrationPath = "/nix/store/nix-path-registration";

  uuid = ids.uuid "${name}:store";

  ext4 = pkgs.runCommand "store-ext4.img"
    {
      nativeBuildInputs = [
        pkgs.e2fsprogs pkgs.fakeroot pkgs.nix pkgs.coreutils
        pkgs.findutils pkgs.gawk pkgs.sqlite
      ];
    }
    ''
      set -euo pipefail
      staged="$(mktemp -d)"
      mkdir -p "$staged/nix/store" "$staged/nix/var/nix"
      while IFS= read -r p; do
        cp -a --reflink=auto "$p" "$staged/nix/store/"
      done < ${closure}/store-paths

      # A writable filesystem holds the store AND the database, so the database is
      # written now and the image carries it.
      env NIX_STATE_DIR="$staged/nix/var/nix" NIX_STORE_DIR=/nix/store \
        nix-store --load-db < ${closure}/registration

      # --load-db stamps every row with the wall clock, and sqlite leaves a -shm of mmap state
      # beside the file plus a change counter and stale bytes in unused space. Nothing at runtime
      # reads registrationTime — it is a gc-by-age hint — so date it at the epoch, checkpoint so
      # no row is lost, and VACUUM INTO a file that has no history to differ in.
      db="$staged/nix/var/nix/db/db.sqlite"
      sqlite3 "$db" \
        "UPDATE ValidPaths SET registrationTime = 1; \
         PRAGMA wal_checkpoint(TRUNCATE); \
         VACUUM INTO '$db.compact';"
      rm -f "$db-shm" "$db-wal"
      mv "$db.compact" "$db"

      # mke2fs copies atime/mtime off the staged tree, and on a builder mounted `relatime` its
      # own read bumps each atime past whatever was set here. Canonical times on the tree AND
      # SOURCE_DATE_EPOCH on mke2fs, which clamps — measured, neither alone is enough.
      find "$staged" -exec touch -h -d @1 {} +

      # Size from the FILES, not from `du`: du reports ALLOCATED blocks, which depend on the
      # builder's own filesystem, so two builders sized one 1.3 GiB tree 60 MiB apart.
      find "$staged" -type f -printf '%s\n' > file-sizes
      find "$staged" -type d -printf 'd\n' > dir-list
      find "$staged" -printf 'e\n' > entry-list
      data_blocks="$(awk '{ n += int(($1 + 4095) / 4096) } END { print n + 0 }' file-sizes)"
      dirs="$(wc -l < dir-list)"
      entries="$(wc -l < entry-list)"
      blocks=$(( (data_blocks + dirs) * 130 / 100 + 16384 ))

      # The default inode ratio is sized for ordinary data; a store closure is ~130k small files
      # per GiB and mke2fs dies with "Could not allocate inode in ext2 filesystem".
      inodes=$(( entries * 12 / 10 + 8192 ))

      # -E no_copy_xattrs: on a SELinux host mke2fs reads security.selinux off the
      # staged tree and aborts. The label has no meaning inside the image anyway.
      SOURCE_DATE_EPOCH=1 fakeroot mke2fs -q -t ext4 -b 4096 -L ${lib.escapeShellArg label} \
        -E ${lib.escapeShellArg "no_copy_xattrs,hash_seed=${uuid},root_owner=0:0"} \
        -N "$inodes" -U ${lib.escapeShellArg uuid} -d "$staged" -F "$out" "$blocks"
    '';

  # The netboot shape: the store rides in the initrd as an appended cpio segment. The paths
  # land on the initramfs tmpfs (writable), but the database still boots empty — so the archive
  # carries the dump at the same constant path, and the same kind of unit loads it.
  cpio = pkgs.runCommand "store.cpio"
    { nativeBuildInputs = [ pkgs.cpio pkgs.coreutils pkgs.findutils ]; }
    ''
      set -euo pipefail
      staged="$(mktemp -d)"
      mkdir -p "$staged/nix/store"
      while IFS= read -r p; do
        cp -a --reflink=auto "$p" "$staged/nix/store/"
      done < ${closure}/store-paths
      cp ${closure}/registration "$staged/nix/store/nix-path-registration"
      find "$staged" -exec touch -h -d @1 {} +
      (cd "$staged" && find . -mindepth 1 | sort \
        | cpio -o -H newc -R +0:+0 --reproducible --quiet) > "$out"
    '';

  squashfs = pkgs.runCommand "store-squashfs.img"
    { nativeBuildInputs = [ pkgs.squashfsTools pkgs.coreutils ]; }
    ''
      set -euo pipefail
      # A read-only store cannot hold the database — it lives at /nix/var/nix/db,
      # which boots empty. So the image carries the DUMP and a unit in the OS loads
      # it at every boot. That unit is not this tool's to give.
      cp ${closure}/registration nix-path-registration
      mksquashfs nix-path-registration $(cat ${closure}/store-paths) "$out" \
        -no-hardlinks -keep-as-directory -all-root -b 1048576 -comp zstd \
        -no-progress
    '';
in
{
  img = { inherit ext4 squashfs cpio; }.${shape};
  fs = shape;
  registered = true;
  needsBootUnit = shape != "ext4";
  inherit registrationPath uuid;
}
