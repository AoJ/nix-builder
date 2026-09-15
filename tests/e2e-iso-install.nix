# The third installer face, end to end: the zfs host's #image-iso-install — the installer
# wearing the iso face, keyed by the label both sides derive from the artifact's name —
# is personalized through the medium's slot FILE, boots from the medium under OVMF, takes
# the install-time key from /iso, installs offline onto the disk named by its stable
# identity, exports cleanly and reboots; the target disk then boots ALONE.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.zfs;
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "zfs.image-iso-install" "zfs.image-personalize-iso" ];
  check = pkgs.runCommand "e2e-iso-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${e.image-iso-install.file} work.iso
    ${lib.getExe e.image-personalize-iso.run} work.iso
    truncate -s 8G target.img
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd

    echo "== phase A: the iso installer boots from the medium and installs =="
    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=virtio,format=raw,file=work.iso \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    if [ -e install.log ]; then tail -n 40 install.log >&2; fi
    grep -q "installer: install-time key taken from the slot" install.log
    grep -q "niximilate-install done" install.log
    grep -q "NIXIMILATE-INSTALL-OK e2e-zfs" install.log

    echo "== phase B: the installed disk boots ALONE =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars2.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars2.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    if [ -e boot.log ]; then tail -n 30 boot.log >&2; fi
    grep -q "E2E-BOOT-OK e2e-zfs" boot.log
    grep -q "E2E-DB-OK" boot.log
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-INSTALLED-KEY $pub" boot.log

    touch "$out"
  ''
  ;
}
