# The appliance's real deliverable, booted: a memory/squashfs host has no installer (L6),
# so a live ISO is how it actually ships — and while e2e-live-iso boots a DISK host's live
# variant, this boots the appliance's own #image-iso. El Torito starts the ESP image, stage
# 1 loop-mounts the squashfs store out of the iso9660, and the diskless system comes up in
# RAM. No slot, no secrets — the appliance carries none.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
in
{
  witnesses = [ "memory.image-iso" ];
  check = boot {
    name = "e2e-memory-iso-boot";
    image = (compose hosts.memory).image-iso.file;
    expect = ''
      grep -q "E2E-BOOT-OK e2e-memory" result
      grep -q "E2E-DB-OK" result
    '';
  };
}
