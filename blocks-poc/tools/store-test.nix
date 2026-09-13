{ pkgs }:

let
  store = import ./store.nix { inherit pkgs; };

  asExt4 = store { rootPaths = [ pkgs.hello ]; shape = "ext4"; label = "nixos"; };
  asSquash = store { rootPaths = [ pkgs.hello ]; shape = "squashfs"; label = "nixos"; };
in
pkgs.runCommand "test-store"
  { nativeBuildInputs = [ pkgs.e2fsprogs pkgs.squashfsTools ]; }
  ''
    set -euo pipefail

    echo "== ext4 carries the database itself =="
    debugfs -R "ls /nix/var/nix/db" ${asExt4.img} | tr ' ' '\n' | grep -q 'db.sqlite'
    [ ${builtins.toJSON asExt4.needsBootUnit} = false ]

    echo "== squashfs cannot, so it carries the dump — at the path the OS reads =="
    unsquashfs -l ${asSquash.img} | grep -q 'squashfs-root/nix-path-registration'
    [ ${builtins.toJSON asSquash.needsBootUnit} = true ]

    echo "== and that path is the one the tool declares, not one restated here =="
    [ ${builtins.toJSON asSquash.registrationPath} = /nix/store/nix-path-registration ]

    touch $out
  ''
