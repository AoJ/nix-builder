# L3's real case: the encrypted pool, created at install with the passphrase the slot
# delivered — no placeholder anywhere, no prompt anywhere (DECIDED: full automation; a host
# wanting interactive unlock changes its layout, not the delivery). Phase A only, and on
# purpose: booting the encrypted target unattended needs the host's own unlock story,
# which is layout land, outside blocks — the witnesses here are the installer's.
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
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result:" >&2; cat result >&2

    grep -q "installer: install-time key taken from the slot" result
    grep -q "installer: pool passphrase taken from the slot" result
    grep -q "E2E-POOL-ENCRYPTION aes-256-gcm" result
    grep -q "NIXIMILATE-INSTALL-OK e2e-zfs-enc" result

    touch "$out"
  ''
  ;
}
