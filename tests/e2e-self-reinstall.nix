# The in-place SCENARIO of #image-raw-install-inmemory (the endpoint installs any disk;
# this exercises the one freedom only it has): the ext4-install host's image — personalized
# through its slot PARTITION — is dd'd onto the target disk and the machine boots from it.
# The installer lives fully in RAM (the closure rides the initrd on the ESP), so it holds
# no claim on the medium: the mount probe finds no target, the wipe clears the very disk the
# machine booted from — the installer image included — and disko formats it fresh. The disk
# then boots the installed ext4 system alone. A BYSTANDER disk with data rides along through
# both phases and must come out byte-identical: the wipe clears exactly the disks the host
# declared, nothing else.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4-install;
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "ext4-install.image-raw-install-inmemory" "ext4-install.image-personalize" ];
  check = pkgs.runCommand "e2e-self-reinstall"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age pkgs.mtools pkgs.dosfstools pkgs.gptfdisk ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${e.image-raw-install-inmemory.file} self.img
    ${lib.getExe e.image-personalize.run} self.img

    # dd onto the target: the image must FIT the disk it claims, checked before a single
    # byte lands, and the backup GPT is moved to the disk's real end afterwards — exactly
    # the flash procedure a real one-disk machine gets.
    truncate -s 8G target.img
    img_size=$(stat -c%s self.img)
    disk_size=$(stat -c%s target.img)
    [ "$img_size" -le "$disk_size" ] || {
      echo "image ($img_size) larger than the target disk ($disk_size)" >&2; exit 1; }
    dd if=self.img of=target.img conv=notrunc,fsync status=none
    sgdisk -e target.img > /dev/null

    for r in a b; do truncate -s 16M result-$r.img; mkfs.fat -n E2EOUT result-$r.img > /dev/null; done
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd

    truncate -s 64M bystander.img
    mkfs.fat -n KEEPME bystander.img > /dev/null
    echo "do not touch" > keepme
    mcopy -i bystander.img keepme ::/keepme
    cp bystander.img bystander.orig

    echo "== phase A: boots from the disk, wipes it, reinstalls it =="
    # On the UEFI path the initrd (the carried closure, ~0.5G for this host) sits in
    # firmware memory TWICE before the kernel runs — systemd-boot's read buffer plus the
    # EFI stub's copy — so boot needs ~2x the compressed closure plus the system, or the
    # firmware refuses with Out of Resources (the kexec e2es escape this: qemu -initrd
    # loads it once).
    sc=0
    timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=bystander,format=raw,file=bystander.img \
      -device virtio-blk-pci,drive=bystander,serial=bystander \
      -drive if=none,id=eout,format=raw,file=result-a.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result-a.img ::/log result-a 2>/dev/null || touch result-a
    echo "=== install result:" >&2; cat result-a >&2
    grep -q "installer: slot taken over" result-a
    grep -q "INSTALL-OK e2e-ext4-install" result-a

    echo "== phase B: the SAME disk boots the installed system alone =="
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars2.fd
    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars2.fd \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=bystander,format=raw,file=bystander.img \
      -device virtio-blk-pci,drive=bystander,serial=bystander \
      -drive if=none,id=eout,format=raw,file=result-b.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:boot.log -display none -no-reboot || sc=$?
    echo "boot qemu exited $sc" >&2
    mcopy -i result-b.img ::/log result-b 2>/dev/null || touch result-b
    echo "=== boot result:" >&2; cat result-b >&2
    grep -q "E2E-BOOT-OK e2e-ext4-install" result-b
    grep -q "E2E-DB-OK" result-b
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-KEY $pub" result-b

    echo "== the bystander disk came through the wipe byte-identical =="
    cmp bystander.img bystander.orig

    touch "$out"
  ''
  ;
}
