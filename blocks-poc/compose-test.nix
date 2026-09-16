{ pkgs, tools, compose }:

let
  inherit (pkgs) lib;
  fixture = import ./blocks/personalize/fixture.nix { inherit pkgs; };

  # A synthetic host, assembled by hand: two variants, because a live format packs a
  # DIFFERENT toplevel. No nixosSystem anywhere.
  host = {
    name = "demo";
    system = "x86_64-linux";
    slotName = "secrets";
    variants = {
      runtime = {
        toplevel = pkgs.writeText "demo-toplevel" "the host as it runs";
        kernel = pkgs.writeText "demo-kernel" "kernel";
        initrd = pkgs.writeText "demo-initrd" "initrd";
        espBinary = pkgs.writeText "systemd-boot.efi" "not a bootloader";
        kernelParams = [ "root=LABEL=nixos" ];
        rootMode = "disk";
        storage = "ext4";
        machine = {
          kernelPackages = pkgs.linuxPackages;
          initrdAvailableKernelModules = [ "virtio_pci" "virtio_blk" ];
          initrdKernelModules = [ ];
          kernelModules = [ ];
          firmware = [ ];
        };
      };
      # The memory-rooted variants, hand-built (no nixosSystem). liveIso is keyed by label,
      # liveNetboot is plain — the two the composer asks for per live format.
      liveNetboot = {
        toplevel = pkgs.writeText "demo-live-toplevel" "the memory-rooted variant";
        kernel = pkgs.writeText "demo-kernel" "kernel";
        initrd = pkgs.writeText "demo-live-initrd" "live initrd";
        espBinary = pkgs.writeText "systemd-boot.efi" "not a bootloader";
        kernelParams = [ "boot.live" ];
        rootMode = "memory";
      };
      liveIso = _label: {
        toplevel = pkgs.writeText "demo-live-toplevel" "the memory-rooted variant";
        kernel = pkgs.writeText "demo-kernel" "kernel";
        initrd = pkgs.writeText "demo-live-initrd" "live initrd";
        espBinary = pkgs.writeText "systemd-boot.efi" "not a bootloader";
        kernelParams = [ "boot.live" ];
        rootMode = "memory";
      };
    };
    secrets = {
      delivery = [ "embedded" "sidecar" ];
      bundle = "${fixture}/bundle.yaml";
      keyTarget = "/sops.age";
      files = [{
        target = "/sops.age";
        source = "${fixture}/host.key";
        runtimeSource = "${fixture}/host.key";
      }];
    };
    install = {
      prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
      mount = pkgs.writeShellScript "mount" "mount /dev/target-root \"$1\"";
      pool = "rpool";
      keyDestination = "/var/lib/sops/age.key";
      disks = [ "/dev/target" ];
      report = null;
    };
  };

  e = compose host;

  refusedEndpoint = h: n:
    !(builtins.tryEval (compose h).${n}.file.outPath).success;

  zfsHost = host // {
    variants = host.variants // {
      runtime = host.variants.runtime // { storage = "zfs"; };
    };
  };

  squashfsHost = host // {
    variants = host.variants // {
      runtime = host.variants.runtime // { storage = "squashfs"; rootMode = "memory"; };
    };
  };

  unproduced = host // { secrets = host.secrets // { delivery = [ "embedded" "deploy" ]; }; };

in

assert lib.assertMsg (e.image-raw.toplevel == e.image-qcow2.toplevel)
  "raw and qcow2 pack the SAME closure";
assert lib.assertMsg (e.image-iso.toplevel != e.image-raw.toplevel)
  "iso packs the live variant, a different closure";
assert lib.assertMsg (e.closure-live == e.image-iso.toplevel)
  "#closure-live is a LOOKUP of what image packed, not a second evaluation";
assert lib.assertMsg (e.closure == host.variants.runtime.toplevel)
  "#closure is the host as it runs, named";
assert lib.assertMsg (refusedEndpoint zfsHost "image-raw")
  "L2: #image-raw for a zfs host is a hole the composer names at eval";
assert lib.assertMsg (!refusedEndpoint zfsHost "image-raw-install")
  "L2 costs nothing on the -install half: the installer's store is the wrapper's own";
assert lib.assertMsg (refusedEndpoint unproduced "image-raw")
  "a delivery nobody produces must fail at eval";
assert lib.assertMsg (!refusedEndpoint host "image-kexec-install")
  "the memory-rooted installer exists: the kexec wrapper evaluates";
assert lib.assertMsg (!refusedEndpoint host "image-iso-install")
  "the iso-rooted installer exists: the iso wrapper evaluates";
assert lib.assertMsg (!refusedEndpoint host "image-raw-install-inmemory")
  "the memory-rooted disk wrapper exists: -install-inmemory evaluates";
assert lib.assertMsg (refusedEndpoint squashfsHost "image-raw-install")
  "L6: a squashfs host's install endpoints are holes the composer names at eval";
assert lib.assertMsg (refusedEndpoint squashfsHost "image-raw-install-inmemory")
  "L6 covers the inmemory wrapper the same way";
assert lib.assertMsg (!refusedEndpoint squashfsHost "image-raw")
  "L6 costs nothing on the runtime half: the squashfs host's image is the deliverable";

pkgs.runCommand "test-compose"
  { nativeBuildInputs = [
      pkgs.gptfdisk pkgs.mtools pkgs.e2fsprogs pkgs.jq pkgs.xorriso pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail

    echo "== the host asked for embedded delivery, so every deliverable has the slot =="
    sgdisk -p ${e.image-raw.file} | grep -q secrets
    xorriso -indev ${e.image-iso.file} -find ${e.image-iso.slot.path} 2>/dev/null \
      | grep -q secrets

    echo "== -install-inmemory: nothing on the disk but the ESP and the slot =="
    sgdisk -p ${e.image-raw-install-inmemory.file} | grep -q ESP
    sgdisk -p ${e.image-raw-install-inmemory.file} | grep -q secrets
    ! sgdisk -p ${e.image-raw-install-inmemory.file} | grep -qw nixos
    inm_esp="$(jq -r '.[] | select(.label=="ESP") | .startByte' \
      ${e.image-raw-install-inmemory.layout})"
    mdir -i ${e.image-raw-install-inmemory.file}@@"$inm_esp" -/ :: | grep -q nixos-initrd

    echo "== the -install pipe: the same format, the artifact carries the host's closure =="
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${e.image-raw-install.layout})"
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${e.image-raw-install.layout})"
    dd if=${e.image-raw-install.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( (root_len + 1048575) / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' \
      | grep "$(basename ${host.variants.runtime.toplevel})" > /dev/null

    echo "== phase 2 composes against what image RETURNED; the key belongs, and lands =="
    install -m 0644 ${e.image-raw.file} work.img
    ${lib.getExe e.image-personalize.run} work.img
    off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${e.image-raw.layout})"
    mcopy -i work.img@@"$off" ::/sops.age got
    cmp got ${fixture}/host.key

    echo "== the sidecars are RUNNERS, and every sidecar format reads back =="
    ${lib.getExe e.image-secrets-vfat.run} side.img
    mcopy -i side.img ::/sops.age side
    cmp side ${fixture}/host.key
    ${lib.getExe e.image-secrets-iso.run} side.iso
    xorriso -osirrox on -indev side.iso -extract /sops.age side-iso 2>/dev/null
    cmp side-iso ${fixture}/host.key
    ${lib.getExe e.image-secrets-json.run} side.json
    jq -r '."/sops.age"' side.json | base64 -d > side-json
    cmp side-json ${fixture}/host.key

    touch $out
  ''
