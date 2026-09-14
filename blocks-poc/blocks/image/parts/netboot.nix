# kexec and ipxe are ONE payload with two loader descriptors: the tree carries both, and the
# format only decides which one a consumer starts from. The store rides the initrd as an
# appended cpio segment — there is no disk to put it on. A declared slot is RESERVED the
# same way: a marker segment the build appends, so personalize can refuse a tree whose
# image never declared one.
{ pkgs, lib, ids }:

{ name, kernel, initrd, kernelParams, storeCpio, slotName ? null }:

let
  params = lib.concatStringsSep " " kernelParams;

  slotCpio = pkgs.runCommand "slot.cpio"
    { nativeBuildInputs = [ pkgs.cpio pkgs.coreutils pkgs.findutils ]; }
    ''
      set -euo pipefail
      staged="$(mktemp -d)"
      touch "$staged/.slot-${slotName}"
      find "$staged" -exec touch -h -d @1 {} +
      (cd "$staged" && find . -mindepth 1 | sort \
        | cpio -o -H newc -R +0:+0 --reproducible --quiet) > "$out"
    '';
in
pkgs.runCommand "${name}-netboot" { nativeBuildInputs = [ pkgs.coreutils ]; }
  ''
    set -euo pipefail
    mkdir "$out"
    cp ${kernel} "$out/kernel"
    cat ${initrd} ${storeCpio} ${lib.optionalString (slotName != null) slotCpio} \
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
