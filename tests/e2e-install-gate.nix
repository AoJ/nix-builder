# The running-system gate, proven by pointing the loaded gun at our own foot: the zfs
# host's #image-raw-install is DISK-rooted, and here its own boot medium is attached under
# the very identity the host declares as the target disk. Without the gate the probe would
# fail (no pool) and the wipe would clear the disk the installer is running from — dd
# through the mounted root. The action must instead refuse BEFORE the probe, report
# INSTALL-FAILED, power off, and leave the medium's partitions intact.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.zfs;
in
{
  witnesses = [ ];
  check = pkgs.runCommand "e2e-install-gate"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools pkgs.gptfdisk ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${e.image-raw-install.file} installer.img
    truncate -s 16M result.img
    mkfs.fat -n E2EOUT result.img > /dev/null
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd

    echo "== the installer's own disk IS the declared target: it must refuse =="
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=self,format=raw,file=installer.img \
      -device virtio-blk-pci,drive=self,serial=target \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:gate.log -display none -no-reboot || sc=$?
    echo "qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result:" >&2; cat result >&2
    grep -q "INSTALL-FAILED e2e-zfs" result
    ! grep -q "INSTALL-OK" result

    echo "== the medium was refused untouched: its partition table is still whole =="
    sgdisk -p installer.img | grep -qw nixos
    sgdisk -p installer.img | grep -q secrets
    sgdisk -p installer.img | grep -q ESP

    touch "$out"
  ''
  ;
}
