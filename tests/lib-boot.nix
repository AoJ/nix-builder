# One way to boot an artifact under OVMF/KVM and read the witness off the serial console.
# Used by every e2e; the artifact and the expected markers are the parameters.
{ pkgs }:

{ name, image, expect, prepare ? "" }:

pkgs.runCommand name
  {
    nativeBuildInputs = [ pkgs.qemu ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    install -m 0644 ${image} disk.img
    install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd vars.fd
    ${prepare}

    sc=0
    timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
      -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=virtio,format=raw,file=disk.img \
      -serial file:console.log -display none -no-reboot || sc=$?
    echo "qemu exited $sc" >&2
    tail -n 30 console.log >&2 || true

    ${expect}
    touch "$out"
  ''
