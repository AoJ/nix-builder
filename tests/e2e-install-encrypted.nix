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
    nativeBuildInputs = [ pkgs.qemu ];
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

    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    if [ -e install.log ]; then tail -n 40 install.log >&2; fi

    grep -q "installer: install-time key taken from the slot" install.log
    grep -q "installer: pool passphrase taken from the slot" install.log
    grep -q "E2E-POOL-ENCRYPTION aes-256-gcm" install.log
    grep -q "niximilate-install done" install.log
    grep -q "NIXIMILATE-INSTALL-OK e2e-zfs-enc" install.log

    touch "$out"
  ''
  ;
}
