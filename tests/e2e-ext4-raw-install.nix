# The disk-rooted installer installing a DIFFERENT disk — the USB-stick scenario, the one
# freedom the unmarked #image-raw-install has that the inmemory one does not: the medium
# carries the closure RAM-independently, so it can only ever install a disk OTHER than its
# own. The ext4-install host's #image-raw-install — personalized through its slot partition
# — boots from installer.img, formats the SEPARATE target disk through disko, installs its
# carried closure offline, lands the key and reboots; then the target boots ALONE and proves
# its own userspace and the key at its destination. (The `ext4` host cannot stand in here —
# its install is a synthetic stub; ext4-install is the real disko ext4 installer.)
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4-install;
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "ext4-install.image-raw-install" ];
  check = pkgs.runCommand "e2e-ext4-raw-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age pkgs.mtools pkgs.dosfstools ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${e.image-raw-install.file} installer.img
    ${lib.getExe e.image-personalize.run} installer.img
    truncate -s 8G target.img
    for r in a b; do truncate -s 16M result-$r.img; mkfs.fat -n E2EOUT result-$r.img > /dev/null; done
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd

    echo "== phase A: the disk-rooted installer boots and installs the SEPARATE target =="
    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 1 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=virtio,format=raw,file=installer.img \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-a.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== install result:" >&2; cat result-a >&2
    grep -q "installer: slot taken over" result-a
    grep -q "INSTALL-OK e2e-ext4-install" result-a

    echo "== phase B: the installed target disk boots ALONE =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars2.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 1 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars2.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-b.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    mcopy -i result-b.img ::/log result-b 2>/dev/null || touch result-b
    echo "=== boot result:" >&2; cat result-b >&2
    grep -q "E2E-BOOT-OK e2e-ext4-install" result-b
    grep -q "E2E-DB-OK" result-b
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-KEY $pub" result-b

    touch "$out"
  ''
  ;
}
