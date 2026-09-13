{ pkgs, tools }:

let
  image = import ./default.nix { inherit pkgs tools; };

  # Assembled BY HAND. No nixosSystem anywhere, no host anywhere.
  built = image {
    name = "fixture";
    format = "raw";
    system = "x86_64-linux";
    kernel = pkgs.writeText "bzImage" "not a kernel, but it is a file";
    initrd = pkgs.writeText "initrd" "not an initrd either";
    kernelParams = [ "console=ttyS0" "root=LABEL=nixos" ];
    storePaths = [ pkgs.hello ];
  };

  # Same builder, same inputs, a different derivation — so nix really builds it a second time.
  # Two builds of ONE derivation are the same store path, which is why a non-deterministic
  # builder is invisible to nix and why this has to be forced.
  again = d: d.overrideAttrs (_: { determinismProbe = "2"; });

  elsewhere = image {
    name = "other";
    format = "raw";
    system = "x86_64-linux";
    kernel = pkgs.writeText "bzImage" "not a kernel, but it is a file";
    initrd = pkgs.writeText "initrd" "not an initrd either";
    kernelParams = [ "console=ttyS0" "root=LABEL=nixos" ];
    storePaths = [ pkgs.hello ];
  };
in
pkgs.runCommand "test-image"
  { nativeBuildInputs = [ pkgs.gptfdisk pkgs.mtools pkgs.e2fsprogs pkgs.jq ]; }
  ''
    set -euo pipefail

    echo "== the artifact is a GPT disk with the two partitions the block decided on =="
    sgdisk -p ${built.file} | grep -q ESP
    sgdisk -p ${built.file} | grep -q nixos

    echo "== read the layout OUT of the block, do not restate it =="
    esp_off="$(jq -r '.[] | select(.label=="ESP") | .startByte' ${built.layout})"
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${built.layout})"

    echo "== the caller never said BOOTX64.EFI — the block knew =="
    mdir -i ${built.file}@@"$esp_off" -/ ::/EFI/BOOT | grep -q BOOTX64

    echo "== the kernel params the caller DID say arrived in the loader entry =="
    mcopy -i ${built.file}@@"$esp_off" ::/loader/entries/nixos.conf - \
      | grep -q 'options console=ttyS0 root=LABEL=nixos'

    echo "== the root filesystem carries the closure it was asked to carry =="
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${built.layout})"
    dd if=${built.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( root_len / 1048576 )) status=none
    dumpe2fs -h root.img | grep -q 'Filesystem volume name:   nixos'
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep -q hello

    echo "== built twice, byte for byte the same =="
    cmp ${built.file} ${again built.file}

    echo "== two names, two identities: no shared constant =="
    mine="$(sgdisk -p ${built.file} | awk '/Disk identifier/ { print $NF }')"
    theirs="$(sgdisk -p ${elsewhere.file} | awk '/Disk identifier/ { print $NF }')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]

    touch $out
  ''
