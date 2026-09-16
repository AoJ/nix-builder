# The capability gate's other two refusals, each proven by pulling the ground away: the
# ext4-install host's netboot installer is started once with NO target disk at all (the
# declared disk is absent — the gate must refuse, not let disko fail mid-format), and once
# with a target far too small for the carried closure (the gate must refuse on capacity,
# not let nixos-install hit ENOSPC after the format). Both runs must end in INSTALL-FAILED
# with a poweroff, and the small disk must come out byte-identical — refused means
# untouched. The third refusal, a declared disk carrying the running system, has its own
# e2e (install-gate).
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4-install;
in
{
  witnesses = [ ];
  check = pkgs.runCommand "e2e-capability-gate"
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

    run_installer() {
      sc=0
      timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
        -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
        "$@" \
        -serial file:gate.log -display none -no-reboot || sc=$?
      echo "installer qemu exited $sc" >&2
    }

    echo "== the declared disk is ABSENT: the gate must refuse =="
    truncate -s 16M result-a.img
    mkfs.fat -n E2EOUT result-a.img > /dev/null
    run_installer \
      -drive if=none,id=eout,format=raw,file=result-a.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== result:" >&2; cat result-a >&2
    grep -q "INSTALL-FAILED e2e-ext4-install" result-a
    ! grep -q "INSTALL-OK" result-a

    echo "== the declared disk is TOO SMALL for the closure: refuse, and touch nothing =="
    truncate -s 256M tiny.img
    cp tiny.img tiny.orig
    truncate -s 16M result-b.img
    mkfs.fat -n E2EOUT result-b.img > /dev/null
    run_installer \
      -drive if=none,id=target,format=raw,file=tiny.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-b.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout
    mcopy -i result-b.img ::/log result-b 2>/dev/null || touch result-b
    echo "=== result:" >&2; cat result-b >&2
    grep -q "INSTALL-FAILED e2e-ext4-install" result-b
    ! grep -q "INSTALL-OK" result-b
    cmp tiny.img tiny.orig

    touch "$out"
  ''
  ;
}
