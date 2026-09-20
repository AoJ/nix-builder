# The qcow2 envelope over the format-VM's output: #image-qcow2 for a zfs host is the raw
# disk the format-VM made (pool and all) run through `qemu-img convert`. e2e-qcow2-boot
# proves the envelope boots off an ASSEMBLY raw; this proves it off a format-VM raw — the
# pool survives the round-trip and stage 1 imports it unforced. The pristine slot is empty.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  e = compose hosts.zfs;
in
{
  witnesses = [ "zfs.image-qcow2" ];
  check = boot {
    name = "e2e-zfs-qcow2-boot";
    image = e.image-qcow2.file;
    imageFormat = "qcow2";
    expect = ''
      grep -q "E2E-BOOT-OK e2e-zfs" result
      grep -q "E2E-DB-OK" result
      grep -q "E2E-KEY-EMPTY" result
    '';
  };
}
