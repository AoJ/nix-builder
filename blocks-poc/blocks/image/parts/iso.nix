# The live medium: an iso9660 carrying the squashfs store and the slot, EFI-booted through an
# El Torito record that points at the ESP image — kernel, initrd and loader entries ride
# INSIDE that FAT image, because that is the filesystem the firmware and systemd-boot read.
# `-isohybrid-gpt-basdat` marks the same image in a GPT so the file also boots dd'd to a
# stick (the nixpkgs pattern, make-iso9660-image.sh).
{ pkgs, lib, ids }:

{ name, espImg, storeImg, extraFiles ? [ ] }:

pkgs.runCommand "${name}.iso"
  { nativeBuildInputs = [ pkgs.xorriso pkgs.coreutils ]; }
  ''
    set -euo pipefail
    staged="$(mktemp -d)"
    mkdir -p "$staged/boot"
    cp ${espImg} "$staged/boot/efi.img"
    cp ${storeImg} "$staged/nix-store.squashfs"
    ${lib.concatMapStringsSep "\n" (f: ''
      mkdir -p "$staged$(dirname ${lib.escapeShellArg f.path})"
      cp ${f.source} "$staged"${lib.escapeShellArg f.path}
    '') extraFiles}

    # xorriso honours the stdenv's SOURCE_DATE_EPOCH; the volume id comes from the image
    # name, so two images never answer the same by-label lookup.
    xorriso -as mkisofs -r -J \
      -volid ${lib.escapeShellArg (lib.toUpper (ids.volumeId "${name}:iso"))} \
      -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat \
      -o "$out" "$staged"
  ''
