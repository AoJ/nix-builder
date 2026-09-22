# The slotless install path: a host that declares NO secrets names no slot, so its
# installer builds no slot service and its layout no slot partition. The plain host's
# #image-kexec-install — a netboot installer carrying the closure — boots with no disk of
# its own, formats an ext4 target through disko WITHOUT a slot anywhere, installs, and the
# target boots the system alone. No "slot taken over" line, no key: there is nothing to
# deliver, and the install must run clean all the same.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.plain;
in
{
  witnesses = [ "plain.image-kexec-install" "plain.closure" ];
  check = pkgs.runCommand "e2e-slotless-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    mkdir tree
    cp ${e.image-kexec-install.file}/* tree/
    chmod -R +w tree

    cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree/kexec.sh)"
    [ -n "$cmdline" ] || { echo "no command line in kexec.sh" >&2; exit 1; }
    truncate -s 8G target.img
    for r in a b; do truncate -s 16M result-$r.img; mkfs.fat -n E2EOUT result-$r.img > /dev/null; done

    echo "== phase A: the slotless netboot installer formats ext4 via disko and installs =="
    sc=0
    timeout 3000 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-a.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== install result:" >&2; cat result-a >&2
    grep -q "INSTALL-OK e2e-plain" result-a
    # No slot was delivered, and the act says so rather than looking for one.
    ! grep -q "slot taken over" result-a

    echo "== phase B: the installed disk boots ALONE, with no slot partition =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-b.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    mcopy -i result-b.img ::/log result-b 2>/dev/null || touch result-b
    echo "=== boot result:" >&2; cat result-b >&2
    grep -q "E2E-BOOT-OK e2e-plain" result-b
    grep -q "E2E-DB-OK" result-b

    touch "$out"
  ''
  ;
}
