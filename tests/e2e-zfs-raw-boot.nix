# The L2 amendment's boot proof: a zfs host's #image-raw — the pool made by the format-VM
# from the host's own disko layout, the closure injected with no target-arch execution —
# BOOTS: firmware, systemd-boot off the disko-made ESP, stage 1 imports the pool WITHOUT
# force (it was born with the host's hostid), and the injected store answers as a store.
# The layout's slot partition is formatted and EMPTY, and the booted system says so.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  e = compose hosts.zfs;
in
{
  witnesses = [ "zfs.image-raw" ];
  check = boot {
    name = "e2e-zfs-raw-boot";
    image = e.image-raw.file;
    expect = ''
      grep -q "E2E-BOOT-OK e2e-zfs" result
      grep -q "E2E-DB-OK" result
      grep -q "E2E-KEY-EMPTY" result
    '';
  };
}
