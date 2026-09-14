# The first e2e claim: a disk/ext4 host's #image-raw — assembled with no VM, no loop
# device and no root — BOOTS: firmware, systemd-boot, its own initrd, its own userspace.
# The pristine artifact's slot is formatted and EMPTY, and the booted system says so. The
# host also declared sidecar delivery, so the sidecar rides along as a second disk and the
# booted system is its CONSUMER: it mounts it by label and re-derives the key's public
# half.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  boot = import ./lib-boot.nix { inherit pkgs; };
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
  e = compose hosts.ext4;
in
boot {
  name = "e2e-raw-boot";
  image = e.image-raw.file;
  prepare = ''
    ${lib.getExe e.image-secrets-vfat.run} sidecar.img
    pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
  '';
  extraDrives = "-drive if=virtio,format=raw,file=sidecar.img";
  expect = ''
    grep -q "E2E-BOOT-OK e2e-ext4" console.log
    grep -q "E2E-KEY-EMPTY" console.log
    grep -q "E2E-SIDECAR $pub" console.log
  '';
}
