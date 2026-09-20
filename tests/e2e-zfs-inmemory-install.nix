# The one-disk zfs box: #image-raw-install-inmemory for a zfs target. The closure rides the
# initrd on the ESP, so the booted installer holds no claim on any disk — which is the one
# freedom this endpoint has: it can install the very disk it booted from. The zfs host's
# inmemory installer — personalized through its slot partition — is dd'd onto the target, the
# machine boots it fully in RAM, the wipe clears that same disk (the installer image
# included), disko creates the pool fresh and installs the carried closure, then the disk
# boots the installed zfs system alone with the pool imported unforced and the key in place.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.zfs;
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "zfs.image-raw-install-inmemory" ];
  check = pkgs.runCommand "e2e-zfs-inmemory-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age pkgs.mtools pkgs.dosfstools pkgs.gptfdisk ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${e.image-raw-install-inmemory.file} self.img
    ${lib.getExe e.image-personalize.run} self.img

    # dd onto the target, the real one-disk flash procedure: the image must fit, checked
    # before a byte lands, and the backup GPT is moved to the disk's real end afterwards.
    truncate -s 8G target.img
    img_size=$(stat -c%s self.img)
    disk_size=$(stat -c%s target.img)
    [ "$img_size" -le "$disk_size" ] || {
      echo "image ($img_size) larger than the target disk ($disk_size)" >&2; exit 1; }
    dd if=self.img of=target.img conv=notrunc,fsync status=none
    sgdisk -e target.img > /dev/null

    for r in a b; do truncate -s 16M result-$r.img; mkfs.fat -n E2EOUT result-$r.img > /dev/null; done
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd

    echo "== phase A: boots from the disk in RAM, wipes it, creates the pool, installs =="
    # The carried closure (zfs userland + kernel module) rides the initrd, which sits in
    # firmware memory twice before the kernel runs — so this needs generous RAM or the EFI
    # stub refuses with Out of Resources. The kexec e2es escape this (qemu -initrd loads it
    # once); a dd'd inmemory image does not.
    sc=0
    timeout 1800 qemu-system-x86_64 -enable-kvm -cpu host -m 6144 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result-a.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== install result:" >&2; cat result-a >&2
    grep -q "installer: slot taken over" result-a
    grep -q "INSTALL-OK e2e-zfs" result-a

    echo "== phase B: the SAME disk boots the installed zfs system alone =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars2.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars2.fd \
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
    grep -q "E2E-KEY $pub" result-b

    touch "$out"
  ''
  ;
}
