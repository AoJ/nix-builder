# The netboot payload BOOTS (DECIDED face: squashfs-in-initrd): qemu starts the tree's own
# kernel and initrd with the command line read OUT of the artifact's kexec descriptor — no
# firmware, no disk attached at all. Stage 1 loop-mounts the squashfs store out of the
# initramfs, hands the personalized slot files over at /run/initrd-slot, and the booted
# system re-derives the key's public half.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4;
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "ext4.image-kexec" "ext4.image-personalize-kexec" ];
  check = pkgs.runCommand "e2e-kexec-boot"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    mkdir tree
    cp ${e.image-kexec.file}/* tree/
    chmod -R +w tree
    ${lib.getExe e.image-personalize-kexec.run} "$PWD/tree"
    truncate -s 16M result.img
    mkfs.fat -n E2EOUT result.img > /dev/null

    cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree/kexec.sh)"
    [ -n "$cmdline" ] || { echo "no command line in kexec.sh" >&2; exit 1; }

    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp "$(( NIX_BUILD_CORES > 0 ? NIX_BUILD_CORES : 1 ))" \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:console.log -display none -no-reboot || sc=$?
    echo "qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result:" >&2; cat result >&2

    grep -q "E2E-BOOT-OK e2e-ext4" result
    grep -q "E2E-DB-OK" result
    pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-KEY $pub" result
    touch "$out"
  ''
  ;
}
