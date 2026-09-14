{ pkgs, tools }:

let
  inherit (pkgs) lib;
  image = import ./default.nix { inherit pkgs tools; };

  # Assembled BY HAND. No nixosSystem anywhere, no host anywhere.
  payload = {
    system = "x86_64-linux";
    toplevel = pkgs.writeText "toplevel" "not a system, but it is what was packed";
    kernel = pkgs.writeText "bzImage" "not a kernel, but it is a file";
    initrd = pkgs.writeText "initrd" "not an initrd either";
    kernelParams = [ "console=ttyS0" "root=LABEL=nixos" ];
    storePaths = [ pkgs.hello ];
  };

  raw = image (payload // {
    name = "fixture"; format = "raw"; storeShape = "ext4";
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  bare = image (payload // { name = "fixture"; format = "raw"; storeShape = "ext4"; });
  qcow2 = image (payload // {
    name = "fixture"; format = "qcow2"; storeShape = "ext4";
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  asIso = image (payload // {
    name = "fixture"; format = "iso"; storeShape = "squashfs";
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  asKexec = image (payload // { name = "fixture"; format = "kexec"; storeShape = "cpio"; });
  asIpxe = image (payload // { name = "fixture"; format = "ipxe"; storeShape = "cpio"; });

  # Same builder, same inputs, a different derivation — so nix really builds it a second time.
  # Two builds of ONE derivation are the same store path, which is why a non-deterministic
  # builder is invisible to nix and why this has to be forced.
  again = d: d.overrideAttrs (_: { determinismProbe = "2"; });

  elsewhere = image (payload // { name = "other"; format = "raw"; storeShape = "ext4"; });

  # A wrong composition fails at eval, in image — not at boot on the machine.
  refused = args: !(builtins.tryEval (image (payload // args)).file.outPath).success;
  evalRefusals = {
    cpio-on-disk = refused { name = "bad"; format = "raw"; storeShape = "cpio"; };
    ext4-in-initrd = refused { name = "bad"; format = "kexec"; storeShape = "ext4"; };
    writable-iso = refused { name = "bad"; format = "iso"; storeShape = "ext4"; };
  };
in

assert lib.assertMsg (raw.toplevel == payload.toplevel)
  "the output must carry the toplevel that was packed";
assert lib.assertMsg (lib.all (v: v) (lib.attrValues evalRefusals))
  "an illegal (format, store shape) composition must fail at eval: ${builtins.toJSON evalRefusals}";

pkgs.runCommand "test-image"
  { nativeBuildInputs = [
      pkgs.gptfdisk pkgs.mtools pkgs.e2fsprogs pkgs.jq pkgs.qemu-utils
      pkgs.xorriso pkgs.cpio pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail

    echo "== raw: a GPT disk with the partitions the block decided on =="
    sgdisk -p ${raw.file} | grep -q ESP
    sgdisk -p ${raw.file} | grep -q nixos

    echo "== read the layout OUT of the block, do not restate it =="
    esp_off="$(jq -r '.[] | select(.label=="ESP") | .startByte' ${raw.layout})"
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${raw.layout})"

    echo "== the caller never said BOOTX64.EFI — the block knew =="
    mdir -i ${raw.file}@@"$esp_off" -/ ::/EFI/BOOT | grep -q BOOTX64

    echo "== the kernel params the caller DID say arrived in the loader entry =="
    mcopy -i ${raw.file}@@"$esp_off" ::/loader/entries/nixos.conf - \
      | grep -q 'options console=ttyS0 root=LABEL=nixos'

    echo "== the root filesystem carries the closure it was asked to carry =="
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${raw.layout})"
    dd if=${raw.file} of=root.img bs=1M \
       skip=$(( root_off / 1048576 )) count=$(( root_len / 1048576 )) status=none
    debugfs -R "ls /nix/store" root.img | tr ' ' '\n' | grep -q hello

    echo "== the slot is reserved, formatted, and EMPTY =="
    slot_off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${raw.layout})"
    [ "$(mdir -b -i ${raw.file}@@"$slot_off" :: | wc -l)" = 0 ]

    echo "== no slot asked for, none reserved =="
    ! sgdisk -p ${bare.file} | grep -q secrets
    [ ${builtins.toJSON (bare.slot == null)} = true ]

    echo "== qcow2 is the same disk in a different envelope: round-trip and compare =="
    qemu-img convert -f qcow2 -O raw ${qcow2.file} back.img
    cmp back.img ${raw.file}

    echo "== iso: payload, store and the slot FILE are inside; nothing was restated =="
    xorriso -indev ${asIso.file} -find /boot/kernel 2>/dev/null | grep -q kernel
    xorriso -indev ${asIso.file} -find /nix-store.squashfs 2>/dev/null | grep -q squashfs
    slot_path=${lib.escapeShellArg asIso.slot.path}
    xorriso -indev ${asIso.file} -find "$slot_path" 2>/dev/null | grep -q "$slot_path"

    echo "== netboot: ONE payload, BOTH descriptors, same tree for kexec and ipxe =="
    [ ${asKexec.file} = ${asIpxe.file} ]
    [ -x ${asKexec.file}/kexec.sh ]
    grep -q 'console=ttyS0' ${asKexec.file}/boot.ipxe
    grep -q 'console=ttyS0' ${asKexec.file}/kexec.sh

    echo "== the initrd is the caller's initrd with the store cpio appended =="
    n="$(stat -c%s ${payload.initrd})"
    cmp -n "$n" ${asKexec.file}/initrd ${payload.initrd}
    tail -c +$(( n + 1 )) ${asKexec.file}/initrd \
      | cpio -t --quiet | grep -q 'nix/store/nix-path-registration'

    echo "== built twice, byte for byte the same =="
    cmp ${raw.file} ${again raw.file}
    cmp ${asIso.file} ${again asIso.file}

    echo "== two names, two identities: no shared constant =="
    mine="$(sgdisk -p ${raw.file} | awk '/Disk identifier/ { print $NF }')"
    theirs="$(sgdisk -p ${elsewhere.file} | awk '/Disk identifier/ { print $NF }')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]
    iso_mine="$(xorriso -indev ${asIso.file} -pvd_info 2>/dev/null | awk '/Volume Id/ { print $4 }')"
    iso_other="$(xorriso -indev ${again (image (payload // {
      name = "other"; format = "iso"; storeShape = "squashfs"; })).file} -pvd_info 2>/dev/null \
      | awk '/Volume Id/ { print $4 }')"
    [ -n "$iso_mine" ] && [ "$iso_mine" != "$iso_other" ]

    touch $out
  ''
