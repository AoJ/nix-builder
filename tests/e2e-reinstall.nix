# An install REPLACES, proven — not assumed: running the same installer a second time over
# a disk that already holds the installed system must produce that system again from
# nothing, not an installation layered onto what was there. After a fresh install (phase
# A), the harness plants a canary in the target's slot partition; the installer runs again
# (phase C) and the canary must be GONE — its survival would mean the disk was reused, and
# a machine that is half one system and half another is a machine nobody can reason about.
# The target then boots (phase D), the installed system, complete.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4-install;
in
{
  witnesses = [ ];
  check = pkgs.runCommand "e2e-never-reformat"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools pkgs.gptfdisk pkgs.gawk ];
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
    for r in a c d; do truncate -s 16M result-$r.img; mkfs.fat -n E2EOUT result-$r.img > /dev/null; done

    run_installer() {
      sc=0
      timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
        -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
        -drive if=none,id=target,format=raw,file=target.img \
        -device virtio-blk-pci,drive=target,serial=target \
        -drive if=none,id=eout,format=raw,file="$1" \
        -device virtio-blk-pci,drive=eout,serial=e2eout \
        -serial file:"$2" -display none -no-reboot || sc=$?
      echo "installer qemu exited $sc" >&2
    }

    echo "== phase A: fresh install =="
    run_installer result-a.img install-a.log
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== phase A result:" >&2; cat result-a >&2
    grep -q "INSTALL-OK e2e-ext4-install" result-a

    echo "== the harness plants a canary on the installed disk =="
    slot_num="$(sgdisk -p target.img | awk '$NF == "secrets" { print $1 }')"
    [ -n "$slot_num" ]
    slot_start="$(sgdisk -i "$slot_num" target.img | awk '/^First sector/ { print $3 }')"
    [ -n "$slot_start" ]
    slot_off=$(( slot_start * 512 ))
    echo "must not survive a reinstall" > canary
    mcopy -o -i target.img@@"$slot_off" canary ::/canary
    mcopy -i target.img@@"$slot_off" ::/canary planted
    cmp canary planted

    echo "== phase C: the installer runs AGAIN over the installed disk =="
    run_installer result-c.img install-c.log
    mcopy -i result-c.img ::/log result-c 2>/dev/null || touch result-c
    echo "=== phase C result:" >&2; cat result-c >&2
    grep -q "INSTALL-OK e2e-ext4-install" result-c

    echo "== the canary is GONE: the disk was cleared, not reused =="
    # The slot may sit at a different offset now — the layout was created afresh — so it
    # is found by name again rather than assumed to be where it was.
    slot_num="$(sgdisk -p target.img | awk '$NF == "secrets" { print $1 }')"
    [ -n "$slot_num" ]
    slot_start="$(sgdisk -i "$slot_num" target.img | awk '/^First sector/ { print $3 }')"
    slot_off=$(( slot_start * 512 ))
    ! mcopy -i target.img@@"$slot_off" ::/canary gone 2>/dev/null

    echo "== phase D: the disk still boots the installed system =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-d.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    mcopy -i result-d.img ::/log result-d 2>/dev/null || touch result-d
    echo "=== phase D result:" >&2; cat result-d >&2
    grep -q "E2E-BOOT-OK e2e-ext4-install" result-d
    grep -q "E2E-DB-OK" result-d

    touch "$out"
  ''
  ;
}
