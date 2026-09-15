# The whole phase-2 chain on a real artifact: personalize verifies the key against the
# host's bundle and fills the slot; the booted system then reads the key off its own slot
# partition and re-derives the public half — which must be the fixture's.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  fixture = import ../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
  e = compose hosts.ext4;
in
{
  witnesses = [ "ext4.image-personalize" ];
  check = boot {
  name = "e2e-personalize-boot";
  image = e.image-raw.file;
  prepare = ''
    ${pkgs.lib.getExe e.image-personalize.run} disk.img
    pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
  '';
  expect = ''
    grep -q "E2E-BOOT-OK e2e-ext4" console.log
    grep -q "E2E-KEY $pub" console.log
  '';
};
}
