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
    nativeBuildInputs = [ pkgs.qemu pkgs.age ];
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

    echo "== phase A: the netboot installer boots and installs =="
    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    if [ -e install.log ]; then tail -n 40 install.log >&2; fi
    grep -q "installer: install-time key taken from the slot" install.log
    grep -q "niximilate-install done" install.log
    grep -q "NIXIMILATE-INSTALL-OK e2e-zfs" install.log

    echo "== phase B: the installed disk boots ALONE =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    if [ -e boot.log ]; then tail -n 30 boot.log >&2; fi
    grep -q "E2E-BOOT-OK e2e-zfs" boot.log
    grep -q "E2E-DB-OK" boot.log
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-INSTALLED-KEY $pub" boot.log

    touch "$out"
  ''
  ;
}
