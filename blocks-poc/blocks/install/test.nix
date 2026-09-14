{ pkgs, tools }:

let
  inherit (pkgs) lib;
  install = import ./default.nix { inherit pkgs tools; };
  image = import ../image/default.nix { inherit pkgs tools; };

  # Assembled BY HAND: five extracted values, not a configuration.
  target = pkgs.writeText "target-toplevel" "the system being installed";
  handed = install {
    name = "fixture";
    toplevel = target;
    closure = [ target pkgs.hello ];
    prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    mount = pkgs.writeShellScript "mount" "mount /dev/target-root \"$1\"";
    keyDestination = "/var/lib/sops/age.key";
  };

  # The pipe: image(install(host)) — the format does not know it is packing an installer.
  packed = image ({
    name = "fixture-install";
    format = "raw";
    system = "x86_64-linux";
    storeShape = "ext4";
  } // handed.system);
in

assert lib.assertMsg (builtins.elem target handed.system.storePaths)
  "the installer must CARRY the system it installs — offline is the point";

pkgs.runCommand "test-install"
  { nativeBuildInputs = [ pkgs.gptfdisk pkgs.e2fsprogs pkgs.jq pkgs.coreutils ]; }
  ''
    set -euo pipefail

    echo "== the installer runs the caller's steps against the caller's destination =="
    script=${handed.system.toplevel}/bin/install-fixture
    grep -q 'prepare' "$script"
    grep -q 'mount' "$script"
    grep -q '/var/lib/sops/age.key' "$script"
    grep -q ${target} "$script"

    echo "== packed as an ordinary image, the artifact carries the carried closure =="
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${packed.layout})"
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${packed.layout})"
    dd if=${packed.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( root_len / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep -q "$(basename ${target})"
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep -q hello

    touch $out
  ''
