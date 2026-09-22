# Booting the encrypted-zfs EXAMPLE a user copies — and it can only be reached by INSTALLING
# it, because #image-raw is a hole (L3: no image is ever encrypted). So this drives the whole
# arc the example is FOR: the installer creates the pool from the passphrase the slot delivered,
# and the installed target then boots UNATTENDED, stage 1 unlocking the pool with the key the
# install laid where the layout said. The examples/ gate could never show this arc closes.
{ pkgs }:

let
  lib = pkgs.lib;
  record = import ./e2e-record.nix { inherit pkgs; };
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
  builder = { lib = import ../lib/api.nix; };
  diskoModule = (import ../disko-pin.nix) + "/module.nix";

  e = import ../examples/zfs-encrypted/host.nix {
    inherit pkgs builder diskoModule;
    extraModules = [
      (import ./hosts/modules/e2e-result.nix { inherit record; })
      (import ./hosts/modules/marker.nix { inherit record; })
    ];
    # The real deploy points these at the machine's own paths; the suite hands the same
    # fixture the zfs-enc test host uses, so the install has a real passphrase and key.
    secretsFiles = [
      { target = "/sops.age"; content.file = "${fixture}/host.key"; }
      { target = "/pool.pass"; content.file = "${fixture}/pool.pass"; }
    ];
  };
in
{
  witnesses = [ ];
  check = pkgs.runCommand "e2e-example-zfs-encrypted"
    {
      nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools ];
      requiredSystemFeatures = [ "kvm" ];
    }
    ''
      set -euo pipefail
      mkdir tree
      cp ${e.image-kexec-install.file}/* tree/
      chmod -R +w tree
      ${lib.getExe e.image-personalize-kexec.run} "$PWD/tree"

      cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree/kexec.sh)"
      [ -n "$cmdline" ] || { echo "no command line in kexec.sh" >&2; exit 1; }
      truncate -s 8G target.img
      truncate -s 16M result.img; mkfs.fat -n E2EOUT result.img > /dev/null

      echo "== install the encrypted example onto the target (device by-id is virtio-main) =="
      sc=0
      timeout 3000 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
        -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
        -drive if=none,id=target,format=raw,file=target.img \
        -device virtio-blk-pci,drive=target,serial=main \
        -drive if=none,id=eout,format=raw,file=result.img \
        -device virtio-blk-pci,drive=eout,serial=e2eout \
        -serial file:install.log -display none -no-reboot || sc=$?
      echo "install qemu exited $sc" >&2

      echo "== the installed encrypted target boots UNATTENDED, unlocking with the delivered key =="
      truncate -s 16M result-boot.img; mkfs.fat -n E2EOUT result-boot.img > /dev/null
      install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
      sc=0
      timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
        -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=vars.fd \
        -drive if=none,id=target,format=raw,file=target.img \
        -device virtio-blk-pci,drive=target,serial=main \
        -drive if=none,id=eout,format=raw,file=result-boot.img \
        -device virtio-blk-pci,drive=eout,serial=e2eout \
        -serial file:boot.log -display none -no-reboot || sc=$?
      echo "boot qemu exited $sc" >&2
      mcopy -i result-boot.img ::/log result-boot 2>/dev/null || touch result-boot
      echo "=== result-boot:" >&2; cat result-boot >&2
      grep -q "E2E-BOOT-OK example-zfs-enc" result-boot || {
        echo "=== install log tail:" >&2; tail -n 60 install.log >&2
        echo "=== boot log tail:" >&2; tail -n 40 boot.log >&2
        exit 1
      }
      touch "$out"
    '';
}
