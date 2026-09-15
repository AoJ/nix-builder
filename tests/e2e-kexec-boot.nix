# The netboot payload BOOTS (DECIDED face: squashfs-in-initrd): qemu starts the tree's own
# kernel and initrd with the command line read OUT of the artifact's kexec descriptor — no
# firmware, no disk attached at all. Stage 1 loop-mounts the squashfs store out of the
# initramfs, hands the personalized slot files over at /run/initrd-slot, and the booted
# system re-derives the key's public half.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4;
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "ext4.image-kexec" "ext4.image-personalize-kexec" ];
  check = pkgs.runCommand "e2e-kexec-boot"
  {
    nativeBuildInputs = [ pkgs.qemu ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    mkdir tree
    cp ${e.image-kexec.file}/* tree/
    chmod -R +w tree
    ${lib.getExe e.image-personalize-kexec.run} "$PWD/tree"

    cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree/kexec.sh)"
    [ -n "$cmdline" ] || { echo "no command line in kexec.sh" >&2; exit 1; }

    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -serial file:console.log -display none -no-reboot || sc=$?
    echo "qemu exited $sc" >&2
    if [ -e console.log ]; then
      tail -n 30 console.log >&2
    fi

    grep -q "E2E-BOOT-OK e2e-ext4" console.log
    grep -q "E2E-DB-OK" console.log
    pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-KEY $pub" console.log
    touch "$out"
  ''
  ;
}
