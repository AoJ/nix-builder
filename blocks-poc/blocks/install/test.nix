{ pkgs, tools }:

let
  inherit (pkgs) lib;
  install = import ./default.nix { inherit pkgs tools; };
  image = import ../image/default.nix { inherit pkgs tools; };

  # Assembled BY HAND: the extracted values, not a configuration.
  target = pkgs.writeText "target-toplevel" "the system being installed";
  base = {
    name = "fixture";
    system = "x86_64-linux";
    toplevel = target;
    closure = [ target pkgs.hello ];
    prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    mount = pkgs.writeShellScript "mount" "zpool import rpool && mount -t zfs rpool/root /mnt";
    pool = "rpool";
    storage = "zfs";
    keyDestination = "/var/lib/sops/age.key";
    disks = [ "/dev/target" ];
    report = null;
    slotFace = tools.slotFace { format = "raw"; name = "secrets"; };
  };
  handed = install base;

  refused = args: !(builtins.tryEval (install (base // args)).system.toplevel.drvPath).success;

  # The pipe: image(install(host)) — the format does not know it is packing an installer.
  packed = image ({
    name = "fixture-install";
    format = "raw";
    system = "x86_64-linux";
    storeShape = "ext4";
    storePlacement = "partition";
  } // handed.system);
in

assert lib.assertMsg (builtins.elem target handed.system.storePaths)
  "the installer must CARRY the system it installs — offline is the point";
assert lib.assertMsg
  ((install (base // {
    rootMode = "memory";
    slotFace = tools.slotFace { format = "kexec"; name = "secrets"; };
  })).system.rootMode == "memory")
  "the memory-rooted installer exists and declares itself";
assert lib.assertMsg (refused { disks = [ ]; })
  "an install with no disks to wipe must be refused, not left to format blind";
assert lib.assertMsg (refused { storage = "squashfs"; })
  "storage outside the installable set must be refused at eval";
assert lib.assertMsg (refused { rootMode = "self-hosting"; })
  "an unknown root mode must be refused at eval";

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
    grep -q '/dev/target' "$starter"
    grep -q 'INSTALL-OK fixture' "$starter"

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
