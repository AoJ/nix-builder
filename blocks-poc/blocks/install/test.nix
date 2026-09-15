{ pkgs, tools }:

let
  inherit (pkgs) lib;
  install = import ./default.nix { inherit pkgs tools; };
  image = import ../image/default.nix { inherit pkgs tools; };

  # Assembled BY HAND: the extracted values, not a configuration.
  target = pkgs.writeText "target-toplevel" "the system being installed";
  handed = install {
    name = "fixture";
    system = "x86_64-linux";
    toplevel = target;
    closure = [ target pkgs.hello ];
    prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    mount = pkgs.writeShellScript "mount" "zpool import rpool && mount -t zfs rpool/root /mnt";
    pool = "rpool";
    storage = "zfs";
    keyDestination = "/var/lib/sops/age.key";
    slotFace = tools.slotFace { format = "raw"; name = "secrets"; };
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
assert lib.assertMsg
  ((install {
    name = "fixture"; system = "x86_64-linux"; toplevel = target; closure = [ target ];
    prepare = pkgs.writeShellScript "p" ":"; mount = pkgs.writeShellScript "m" ":";
    pool = "rpool"; storage = "zfs"; keyDestination = "/k"; rootMode = "memory";
    slotFace = tools.slotFace { format = "kexec"; name = "secrets"; };
  }).system.rootMode == "memory")
  "the memory-rooted installer exists and declares itself";

pkgs.runCommand "test-install"
  { nativeBuildInputs = [ pkgs.gptfdisk pkgs.e2fsprogs pkgs.jq pkgs.coreutils pkgs.gnugrep ]; }
  ''
    set -euo pipefail

    echo "== the installer is a real OS whose service runs the ONE install action =="
    unit=${handed.system.toplevel}/etc/systemd/system/action-install.service
    [ -e "$unit" ]
    starter="$(grep -oP 'ExecStart=\K\S+' "$unit")"
    grep -q 'action-install' "$starter"
    grep -q 'prepare' "$starter"
    grep -q 'rpool' "$starter"
    grep -q '/var/lib/sops/age.key' "$starter"
    grep -q ${target} "$starter"

    echo "== the installer's own slot feeds the install-time key to the action =="
    [ -e ${handed.system.toplevel}/etc/systemd/system/slot-key.service ]

    echo "== packed as an ordinary image, the artifact carries the carried closure =="
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${packed.layout})"
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${packed.layout})"
    dd if=${packed.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( (root_len + 1048575) / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep "$(basename ${target})" > /dev/null
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep hello > /dev/null

    touch $out
  ''
