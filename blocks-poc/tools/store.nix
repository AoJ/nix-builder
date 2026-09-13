{ pkgs }:

{ rootPaths, shape, label }:

let
  inherit (pkgs) lib;

  closure = pkgs.closureInfo { rootPaths = rootPaths; };

  # The path a squashfs store's dump sits at. A nixpkgs convention
  # (nixos/lib/make-squashfs.nix), read back by nixpkgs' own units
  # (netboot.nix, iso-image.nix). Both sides take it from nixpkgs, not
  # from each other, which is why no dependency runs between them.
  registrationPath = "/nix/store/nix-path-registration";

  ext4 = pkgs.runCommand "store-ext4.img"
    {
      nativeBuildInputs = [ pkgs.e2fsprogs pkgs.fakeroot pkgs.nix pkgs.coreutils ];
    }
    ''
      set -euo pipefail
      staged="$(mktemp -d)"
      mkdir -p "$staged/nix/store" "$staged/nix/var/nix"
      while IFS= read -r p; do
        cp -a --reflink=auto "$p" "$staged/nix/store/"
      done < ${closure}/store-paths

      # A writable filesystem holds the store AND the database, so the database is
      # written now and the image carries it. (The reproducibility fixes this needs
      # are in the withdrawn branch's assemble/ext4-nix-root.sh and are not repeated
      # here: this is a shape check, not the finished tool.)
      env NIX_STATE_DIR="$staged/nix/var/nix" NIX_STORE_DIR=/nix/store \
        nix-store --load-db < ${closure}/registration

      files="$(find "$staged" | wc -l)"
      kib="$(du -sk --apparent-size "$staged" | cut -f1)"
      truncate -s "$(( kib / 1024 + kib / 4096 + 128 ))M" "$out"

      # -E no_copy_xattrs: on a SELinux host mke2fs reads security.selinux off the
      # staged tree and aborts. The label has no meaning inside the image anyway.
      fakeroot mke2fs -t ext4 -b 4096 -L ${lib.escapeShellArg label} -E no_copy_xattrs \
        -N "$(( files * 2 + 4096 ))" \
        -U deadbeef-dead-beef-dead-beefdeadbeef \
        -d "$staged" "$out"
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
  img = if shape == "ext4" then ext4 else squashfs;
  fs = shape;
  registered = true;
  needsBootUnit = shape == "squashfs";
  inherit registrationPath;
}
