{ pkgs, lib, ids }:

{ name, kernel, initrd, kernelParams, storeImg, extraFiles ? [ ] }:

pkgs.runCommand "${name}.iso"
  { nativeBuildInputs = [ pkgs.xorriso pkgs.coreutils ]; }
  ''
    set -euo pipefail
    staged="$(mktemp -d)"
    mkdir -p "$staged/boot"
    cp ${kernel} "$staged/boot/kernel"
    cp ${initrd} "$staged/boot/initrd"
    printf 'options %s\n' ${lib.escapeShellArg (lib.concatStringsSep " " kernelParams)} \
      > "$staged/boot/cmdline.txt"
    cp ${storeImg} "$staged/nix-store.squashfs"
    ${lib.concatMapStringsSep "\n" (f: ''
      mkdir -p "$staged$(dirname ${lib.escapeShellArg f.path})"
      cp ${f.source} "$staged"${lib.escapeShellArg f.path}
    '') extraFiles}

    # xorriso honours the stdenv's SOURCE_DATE_EPOCH; the volume id comes from the image
    # name, so two images never answer the same by-label lookup.
    xorriso -as mkisofs -r -J \
      -volid ${lib.escapeShellArg (lib.toUpper (ids.volumeId "${name}:iso"))} \
      -o "$out" "$staged"
  ''
