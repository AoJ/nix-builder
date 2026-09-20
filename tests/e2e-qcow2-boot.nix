# The qcow2 envelope, booted: #image-qcow2 is the raw disk run through `qemu-img convert`,
# and nothing else booted a qcow2 — the raw endpoints prove the disk's CONTENTS, this proves
# the envelope firmware actually starts from. The ext4 host's is the cheap one to boot (the
# raw is userspace assembly, no VM); the conversion is format-agnostic, so a booting qcow2
# here is the mechanism proven for every raw the block makes. The pristine slot is empty and
# the booted system says so.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  e = compose hosts.ext4;
in
{
  witnesses = [ "ext4.image-qcow2" ];
  check = boot {
    name = "e2e-qcow2-boot";
    image = e.image-qcow2.file;
    imageFormat = "qcow2";
    expect = ''
      grep -q "E2E-BOOT-OK e2e-ext4" result
      grep -q "E2E-DB-OK" result
      grep -q "E2E-KEY-EMPTY" result
    '';
  };
}
