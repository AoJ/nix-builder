# The whole cycle, on the host L2 exists for: a zfs host's #image-raw-install —
# personalized with the host's key — boots, creates the pool, runs the ONE tested install
# action offline out of its own carried closure, lands the key, exports cleanly and
# reboots; then the TARGET disk boots alone and proves what only the installed system can:
# its own userspace, and the key at its declared destination.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.zfs;
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "zfs.image-raw-install" "zfs.image-personalize" "zfs.closure" ];
  check = pkgs.runCommand "e2e-install-cycle"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${e.image-raw-install.file} installer.img
    ${lib.getExe e.image-personalize.run} installer.img
    truncate -s 8G target.img
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd

    echo "== phase A: the installer boots and installs =="
    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=virtio,format=raw,file=installer.img \
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
