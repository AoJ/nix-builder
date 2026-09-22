# L3's real case: the encrypted pool, created at install with the passphrase the slot
# delivered — no placeholder anywhere, no prompt anywhere (DECIDED: full automation; a host
# wanting interactive unlock changes its layout, not the delivery). Then the installed
# system boots unattended: the install delivered the pool key to the destination the
# host's layout declared, and the layout's stage-1 read unlocks the pool with it.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.zfs-enc;
in
{
  witnesses = [ "zfs-enc.image-kexec-install" "zfs-enc.image-personalize-kexec" ];
  check = pkgs.runCommand "e2e-install-encrypted"
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

    sc=0
    timeout 3000 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp "$(( NIX_BUILD_CORES > 0 ? NIX_BUILD_CORES : 1 ))" \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result:" >&2; cat result >&2

    grep -q "installer: slot taken over" result
    grep -q "E2E-POOL-ENCRYPTION aes-256-gcm" result
    # The installer's own console, shown when the act refused or failed: the witness disk
    # carries the verdict, the serial log carries the reason.
    grep -q "INSTALL-OK e2e-zfs-enc" result || {
      echo "=== installer console:" >&2; tail -n 60 install.log >&2; exit 1
    }

    echo "== the encrypted target boots unattended — the delivered key unlocks the pool =="
    truncate -s 16M result-boot.img; mkfs.fat -n E2EOUT result-boot.img > /dev/null
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp "$(( NIX_BUILD_CORES > 0 ? NIX_BUILD_CORES : 1 ))" \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-boot.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    mcopy -i result-boot.img ::/log result-boot 2>/dev/null || touch result-boot
    echo "=== result-boot:" >&2; cat result-boot >&2
    grep -q "E2E-BOOT-OK e2e-zfs-enc" result-boot

    touch "$out"
  ''
  ;
}
