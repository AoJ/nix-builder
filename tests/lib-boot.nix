# Boot an artifact under OVMF/KVM and read the witness off the RESULT DISK, not the serial
# console: a fast guest can reboot before qemu drains serial, losing early output. The
# marker writes to a vfat disk attached with a stable virtio serial; here we pre-format it,
# attach it, and read it with mtools after qemu exits. `expect` greps ./result.
{ pkgs }:

{ name, image, expect, prepare ? "", extraDrives ? "", imageFormat ? "raw" }:

pkgs.runCommand name
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${image} disk.img
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    truncate -s 16M result.img
    mkfs.fat -n E2EOUT result.img > /dev/null
    ${prepare}

    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp "$(( NIX_BUILD_CORES > 0 ? NIX_BUILD_CORES : 1 ))" \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=virtio,format=${imageFormat},file=disk.img \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      ${extraDrives} \
      -serial file:console.log -display none -no-reboot || sc=$?
    echo "qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result disk:" >&2; cat result >&2
    if [ ! -s result ] && [ -e console.log ]; then
      echo "=== empty result; serial tail:" >&2; tail -n 30 console.log >&2
    fi

    ${expect}
    touch "$out"
  ''
