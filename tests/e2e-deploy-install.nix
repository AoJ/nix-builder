# The PRODUCTION install path, end to end: the zfs host's #image-kexec-install — the
# memory-rooted installer wearing the netboot face, carrying the host's closure — is
# personalized through its initrd slot and started the way a running kernel would start it
# (-kernel/-initrd, no firmware). It takes the install-time key from the initrd-slot
# hand-over, creates the pool on the disk named by its stable identity, installs offline,
# exports cleanly and reboots; the target disk then boots ALONE.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.zfs;
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "zfs.image-kexec-install" "zfs.image-personalize-kexec" ];
  check = pkgs.runCommand "e2e-deploy-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age pkgs.mtools pkgs.dosfstools ];
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
    for r in a b; do truncate -s 16M result-$r.img; mkfs.fat -n E2EOUT result-$r.img > /dev/null; done

    echo "== phase A: the netboot installer boots and installs =="
    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-a.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== install result:" >&2; cat result-a >&2
    grep -q "installer: install-time key taken from the slot" result-a
    grep -q "NIXIMILATE-INSTALL-OK e2e-zfs" result-a

    echo "== phase B: the installed disk boots ALONE =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
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
    grep -q "E2E-BOOT-OK e2e-zfs" result-b
    grep -q "E2E-DB-OK" result-b
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-INSTALLED-KEY $pub" result-b

    touch "$out"
  ''
  ;
}
