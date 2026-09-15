# The live medium, end to end: the ext4 host's #image-iso — the memory-rooted variant,
# packed by the block's own xorriso assembly, with NO nixos-generators and no iso-image
# module anywhere — is personalized through its slot FILE and boots under OVMF/KVM: El
# Torito starts the ESP image, stage 1 finds the medium by the label both sides derived
# from one name, loop-mounts the squashfs store, and the booted system reads the key off
# its own medium.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.ext4;
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
  boot = import ./lib-boot.nix { inherit pkgs; };
in
{
  witnesses = [ "ext4.image-iso" "ext4.image-personalize-iso" "ext4.closure-live" ];
  check = boot {
  name = "e2e-live-iso";
  image = e.image-iso.file;
  prepare = ''
    ${lib.getExe e.image-personalize-iso.run} disk.img
    pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
  '';
  expect = ''
    grep -q "E2E-BOOT-OK e2e-ext4" result
    grep -q "E2E-DB-OK" result
    grep -q "E2E-KEY $pub" result
  '';
};
}
