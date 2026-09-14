{ pkgs, tools, compose }:

let
  inherit (pkgs) lib;

  # A synthetic host: two variants, because a live format packs a DIFFERENT toplevel.
  # No nixosSystem anywhere.
  fixtureKey = pkgs.writeText "age-key-fixture" "AGE-SECRET-KEY-FIXTURE";
  host = rec {
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
      files = [ { target = "/sops.age"; source = fixtureKey; runtimeSource = "${fixtureKey}"; } ];
    };
    install = {
      prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
      mount = pkgs.writeShellScript "mount" "mount /dev/target-root \"$1\"";
      keyDestination = "/var/lib/sops/age.key";
    };
  };

  e = compose host;
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
       skip=$(( root_off / 1048576 )) count=$(( root_len / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' \
      | grep -q "$(basename ${host.variants.runtime.toplevel})"

    echo "== the netboot install rides the initrd, because the composer picked cpio =="
    [ -e ${e.image-kexec-install.file}/kexec.sh ]
    grep -aq 'the host as it runs' ${e.image-kexec-install.file}/initrd

    echo "== phase 2 composes against what image RETURNED, and the key lands =="
    install -m 0644 ${e.image-raw.file} work.img
    ${e.image-personalize.run} work.img
    off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${e.image-raw.layout})"
    mcopy -i work.img@@"$off" ::/sops.age got
    cmp got ${fixtureKey}

    echo "== the sidecar is there for the host that also declared it — ALL THREE media =="
    mcopy -i ${e.image-secrets-vfat.file} ::/sops.age side
    cmp side ${fixtureKey}
    xorriso -osirrox on -indev ${e.image-secrets-iso.file} -extract /sops.age side-iso 2>/dev/null
    cmp side-iso ${fixtureKey}
    jq -r '."/sops.age"' ${e.image-secrets-json.file} | base64 -d > side-json
    cmp side-json ${fixtureKey}

    touch $out
  ''
