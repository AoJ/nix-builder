# The appliance row of the matrix: a memory/squashfs host's #image-raw boots with a tmpfs
# root and a READ-ONLY store partition — the read-only-store module's mount and its
# registration unit, proven together on a running system.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
in
{
  witnesses = [ "memory.image-raw" "memory.closure" ];
  check = boot {
  name = "e2e-memory-boot";
  image = (compose hosts.memory).image-raw.file;
  expect = ''
    grep -q "E2E-BOOT-OK e2e-memory" result
    grep -q "E2E-DB-OK" result
  '';
};
}
