# kexec and ipxe are ONE payload with two loader descriptors: the tree carries both, and the
# format only decides which one a consumer starts from. The store rides the initrd as an
# appended cpio segment — there is no disk to put it on.
{ pkgs, lib, ids }:

{ name, kernel, initrd, kernelParams, storeCpio }:

let
  params = lib.concatStringsSep " " kernelParams;
in
pkgs.runCommand "${name}-netboot" { nativeBuildInputs = [ pkgs.coreutils ]; }
  ''
    set -euo pipefail
    mkdir "$out"
    cp ${kernel} "$out/kernel"
    cat ${initrd} ${storeCpio} > "$out/initrd"

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
