# The first e2e claim: a disk/ext4 host's #image-raw — assembled with no VM, no loop
# device and no root — BOOTS: firmware, systemd-boot, its own initrd, its own userspace.
# The pristine artifact's slot is formatted and EMPTY, and the booted system says so.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
in
boot {
  name = "e2e-raw-boot";
  image = (compose hosts.ext4).image-raw.file;
  expect = ''
    grep -q "E2E-BOOT-OK e2e-ext4" console.log
    grep -q "E2E-KEY-EMPTY" console.log
  '';
}
