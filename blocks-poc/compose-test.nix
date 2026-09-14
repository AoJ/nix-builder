{ pkgs, tools, compose }:

let
  inherit (pkgs) lib;
  fixture = import ./blocks/personalize/fixture.nix { inherit pkgs; };

  # A synthetic host: two variants, because a live format packs a DIFFERENT toplevel.
  # No nixosSystem anywhere.
  host = {
    name = "demo";
    system = "x86_64-linux";
    variants = {
      runtime = {
        toplevel = pkgs.writeText "demo-toplevel" "the host as it runs";
        kernel = pkgs.writeText "demo-kernel" "kernel";
        initrd = pkgs.writeText "demo-initrd" "initrd";
        kernelParams = [ "root=LABEL=nixos" ];
        storage = "ext4";
      };
      live = {
        toplevel = pkgs.writeText "demo-live-toplevel" "the memory-rooted variant";
        kernel = pkgs.writeText "demo-kernel" "kernel";
        initrd = pkgs.writeText "demo-live-initrd" "live initrd";
        kernelParams = [ "boot.live" ];
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
    };
  };

  e = compose host;

  # The matrix's one hole is a LAW: it reads the same for every zfs host, and it does not
  # exist on the -install half, whose store is the wrapper's own.
  zfsHost = host // {
    variants = host.variants // {
      runtime = host.variants.runtime // { storage = "zfs"; };
    };
  };
  zfsRefused = !(builtins.tryEval (compose zfsHost).image-raw.file.outPath).success;
  zfsInstallFine = (builtins.tryEval (compose zfsHost).image-raw-install.file.outPath).success;

  # A declared delivery must have a producer.
  unproduced = host // { secrets = host.secrets // { delivery = [ "embedded" "deploy" ]; }; };
  unproducedRefused = !(builtins.tryEval (compose unproduced).image-raw.file.outPath).success;
in

# The variant is keyed on the format, and the names make it visible:
assert lib.assertMsg (e.image-raw.toplevel == e.image-qcow2.toplevel)
  "raw and qcow2 pack the SAME closure";
assert lib.assertMsg (e.image-iso.toplevel != e.image-raw.toplevel)
  "iso packs the live variant, a different closure";
assert lib.assertMsg (e.closure-live == e.image-iso.toplevel)
  "#closure-live is a LOOKUP of what image packed, not a second evaluation";
assert lib.assertMsg (e.closure == host.variants.runtime.toplevel)
  "#closure is the host as it runs, named";
assert lib.assertMsg zfsRefused
  "L2: #image-raw for a zfs host is a hole the composer names at eval";
assert lib.assertMsg zfsInstallFine
  "L2 costs nothing on the -install half: the installer's store is the wrapper's own";
assert lib.assertMsg unproducedRefused
  "a delivery nobody produces must fail at eval";

pkgs.runCommand "test-compose"
  { nativeBuildInputs = [
      pkgs.gptfdisk pkgs.mtools pkgs.e2fsprogs pkgs.jq pkgs.xorriso pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail

    echo "== the host asked for embedded delivery, so every disk endpoint has the slot =="
    sgdisk -p ${e.image-raw.file} | grep -q secrets
    xorriso -indev ${e.image-iso.file} -find ${e.image-iso.slot.path} 2>/dev/null \
      | grep -q secrets

    echo "== the -install pipe: the same format, the artifact carries the host's closure =="
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${e.image-raw-install.layout})"
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${e.image-raw-install.layout})"
    dd if=${e.image-raw-install.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( (root_len + 1048575) / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' \
      | grep "$(basename ${host.variants.runtime.toplevel})" > /dev/null

    echo "== the netboot install rides the initrd, because the composer picked cpio =="
    [ -e ${e.image-kexec-install.file}/kexec.sh ]
    grep -aq 'the host as it runs' ${e.image-kexec-install.file}/initrd

    echo "== phase 2 composes against what image RETURNED; the key belongs, and lands =="
    install -m 0644 ${e.image-raw.file} work.img
    ${lib.getExe e.image-personalize.run} work.img
    off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${e.image-raw.layout})"
    mcopy -i work.img@@"$off" ::/sops.age got
    cmp got ${fixture}/host.key

    echo "== the sidecar is there for the host that also declared it — ALL THREE media =="
    mcopy -i ${e.image-secrets-vfat.file} ::/sops.age side
    cmp side ${fixture}/host.key
    xorriso -osirrox on -indev ${e.image-secrets-iso.file} -extract /sops.age side-iso 2>/dev/null
    cmp side-iso ${fixture}/host.key
    jq -r '."/sops.age"' ${e.image-secrets-json.file} | base64 -d > side-json
    cmp side-json ${fixture}/host.key

    touch $out
  ''
