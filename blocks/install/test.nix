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
    payload = {
      kind = "closure";
      toplevel = target;
      storePaths = [ target pkgs.hello ];
      prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
      mount = pkgs.writeShellScript "mount" "zpool import rpool && mount -t zfs rpool/root /mnt";
    };
    pool = "rpool";
    storage = "zfs";
    encrypted = false;
    slotName = "secrets";
    slotFiles = [ "/sops.age" ];
    disks = [ "/dev/target" ];
    report = null;
    # Assembled by hand like everything else here: the machine record is DATA, not a
    # configuration the block could read anything further from.
    machine = {
      kernelPackages = pkgs.linuxPackages;
      initrdAvailableKernelModules = [ "virtio_pci" "virtio_blk" ];
      initrdKernelModules = [ ];
      kernelModules = [ ];
      firmware = [ ];
    };
    slotFace = tools.slotFace { format = "raw"; name = "secrets"; };
  };
  handed = install base;
  handedEncrypted = install (base // {
    encrypted = true;
  });

  refused = args: !(builtins.tryEval (install (base // args)).system.toplevel.drvPath).success;

  # The other delivery: a finished disk, written as it is. What it holds is not this
  # block's business, so the fixture is a file — that is the whole contract.
  fixtureImage = pkgs.runCommand "fixture-payload.img.zst"
    { nativeBuildInputs = [ pkgs.zstd ]; }
    "echo 'a disk, as far as this block is concerned' | zstd -3 -o $out";
  imageBase = base // {
    storage = "ext4";
    pool = "";
    payload = { kind = "image"; image = fixtureImage; toplevel = target; };
  };
  handedImage = install imageBase;
  refusedImage = args:
    !(builtins.tryEval (install (imageBase // args)).system.toplevel.drvPath).success;

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
assert lib.assertMsg (refused { storage = "ext4"; encrypted = true; })
  "L3: encryption outside the zfs layout must be refused at eval";
assert lib.assertMsg (refused { slotName = "Bad Name"; })
  "a slot name outside the naming rule must be refused at eval";

assert lib.assertMsg (builtins.elem fixtureImage handedImage.system.storePaths)
  "an image delivery must CARRY the image it writes";
assert lib.assertMsg (!(builtins.elem pkgs.hello handedImage.system.storePaths))
  "and nothing else: an image is written as it is, so no closure rides along";
assert lib.assertMsg
  (refusedImage { payload = { kind = "image"; }; })
  "an image payload with no image must be refused at eval";
assert lib.assertMsg
  (refusedImage { storage = "zfs"; pool = "rpool"; encrypted = true; })
  "an image cannot be encrypted by this block — nothing here creates the pool (L3)";
assert lib.assertMsg
  (refusedImage { completion = "kexec"; payload = { kind = "image"; image = fixtureImage; }; })
  "kexec needs to know the kernel it hands over to; an image alone does not say";
assert lib.assertMsg
  ((install (imageBase // { completion = "kexec"; })).system.toplevel != null)
  "with the toplevel named, the hand-over is complete";

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
    grep -q secrets "$starter"
    grep -q ${target} "$starter"
    grep -q '/dev/target' "$starter"
    grep -q 'INSTALL-OK fixture' "$starter"

    echo "== the encryption declaration reaches the action =="
    unit_enc=${handedEncrypted.system.toplevel}/etc/systemd/system/action-install.service
    starter_enc="$(grep -oP 'ExecStart=\K\S+' "$unit_enc")"
    grep -qw true "$starter_enc"
    grep -qw false "$starter"

    echo "== the installer's own slot is taken over for the action =="
    [ -e ${handed.system.toplevel}/etc/systemd/system/slot.service ]

    echo "== packed as an ordinary image, the artifact carries the carried closure =="
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${packed.layout})"
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${packed.layout})"
    dd if=${packed.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( (root_len + 1048575) / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep "$(basename ${target})" > /dev/null
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep hello > /dev/null

    touch $out
  ''
