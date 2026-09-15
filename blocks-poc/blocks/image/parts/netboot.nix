# kexec and ipxe are ONE payload with two loader descriptors: the tree carries both, and the
# format only decides which one a consumer starts from. The store rides the initrd as a
# squashfs (DECIDED: compressed, lazily read) wrapped in an appended cpio segment at the
# nixpkgs name /nix-store.squashfs — the netboot face mounts it from there. A declared slot
# is RESERVED as a marker segment, so personalize can refuse a tree whose image never
# declared one.
{ pkgs, lib, ids }:

{ name, kernel, initrd, kernelParams, storeImg, slotName ? null }:

let
  params = lib.concatStringsSep " " kernelParams;

  segment = label: stage: pkgs.runCommand label
    { nativeBuildInputs = [ pkgs.cpio pkgs.coreutils pkgs.findutils ]; }
    ''
      set -euo pipefail
      staged="$(mktemp -d)"
      ${stage}
      find "$staged" -exec touch -h -d @1 {} +
      (
        set -euo pipefail
        cd "$staged"
        find . -mindepth 1 | sort | cpio -o -H newc -R +0:+0 --reproducible --quiet
      ) > "$out"
    '';

  storeSeg = segment "store-segment.cpio" ''
    cp ${storeImg} "$staged/nix-store.squashfs"
  '';

  slotSeg = segment "slot-segment.cpio" ''
    touch "$staged/.slot-${slotName}"
  '';
in
pkgs.runCommand "${name}-netboot" { nativeBuildInputs = [ pkgs.coreutils ]; }
  ''
    set -euo pipefail
    mkdir "$out"
    cp ${kernel} "$out/kernel"
    cat ${initrd} ${storeSeg} ${lib.optionalString (slotName != null) slotSeg} \
      > "$out/initrd"

    cat > "$out/kexec.sh" <<SH
    #!/bin/sh
    here="\$(dirname "\$0")"
    kexec -l "\$here/kernel" --initrd="\$here/initrd" --command-line=${lib.escapeShellArg params}
    kexec -e
    SH
    chmod +x "$out/kexec.sh"

    cat > "$out/boot.ipxe" <<IPXE
    #!ipxe
    kernel kernel ${params}
    initrd initrd
    boot
    IPXE
  ''
