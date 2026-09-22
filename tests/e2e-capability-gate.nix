# The capability gate's refusals, each proven by pulling the ground away: the
# ext4-install host's netboot installer is started once with NO target disk at all (the
# declared disk is absent — the gate must refuse, not let disko fail mid-format), and once
# with a target far too small for the carried closure (the gate must refuse on capacity,
# not let nixos-install hit ENOSPC after the format). Then the encrypted host's installer
# is started UNPERSONALIZED — no pool passphrase ever delivered — and must refuse before
# any wipe: without this gate the create fails only after the disk is already cleared.
# Every run must end in INSTALL-FAILED with a poweroff, and the present disks must come
# out byte-identical — refused means untouched. The remaining refusal, a declared disk
# carrying the running system, has its own e2e (install-gate).
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4-install;
  z = compose hosts.zfs-enc;
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
    prep_tree() {
      mkdir "$1"
      cp "$2"/* "$1"/
      chmod -R +w "$1"
      cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" "$1"/kexec.sh)"
      [ -n "$cmdline" ] || { echo "no command line in $1/kexec.sh" >&2; exit 1; }
    }
    prep_tree tree ${e.image-kexec-install.file}
    cmdline_e="$cmdline"
    prep_tree tree-z ${z.image-kexec-install.file}
    cmdline_z="$cmdline"

    run_installer() {
      local tree="$1" append="$2" log="$3"
      shift 3
      sc=0
      timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
        -kernel "$tree/kernel" -initrd "$tree/initrd" -append "$append" \
        "$@" \
        -serial file:"$log" -display none -no-reboot || sc=$?
      echo "installer qemu ($log) exited $sc" >&2
    }

    echo "== the declared disk is ABSENT: the gate must refuse =="
    truncate -s 16M result-a.img
    mkfs.fat -n E2EOUT result-a.img > /dev/null
    run_installer tree "$cmdline_e" gate-a.log \
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
    run_installer tree "$cmdline_e" gate-b.log \
      -drive if=none,id=target,format=raw,file=tiny.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-b.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout
    mcopy -i result-b.img ::/log result-b 2>/dev/null || touch result-b
    echo "=== result:" >&2; cat result-b >&2
    grep -q "INSTALL-FAILED e2e-ext4-install" result-b
    ! grep -q "INSTALL-OK" result-b
    cmp tiny.img tiny.orig

    echo "== the encrypted host's passphrase was NOT delivered: refuse before any wipe =="
    truncate -s 8G target.img
    cp --sparse=always target.img target.orig
    truncate -s 16M result-c.img
    mkfs.fat -n E2EOUT result-c.img > /dev/null
    run_installer tree-z "$cmdline_z" gate-c.log \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-c.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout
    mcopy -i result-c.img ::/log result-c 2>/dev/null || touch result-c
    echo "=== result:" >&2; cat result-c >&2
    grep -q "INSTALL-FAILED e2e-zfs-enc" result-c
    ! grep -q "INSTALL-OK" result-c
    cmp target.img target.orig

    touch "$out"
  ''
  ;
}
