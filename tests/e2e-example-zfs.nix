# Booting the zfs EXAMPLE a user copies: an unencrypted pool the format-VM makes from the
# host's disko layout, its root a zfs dataset. Proves the copied file boots — the pool
# imports, userspace comes up, and the embedded slot its config mounts is really there.
{ pkgs }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  record = import ./e2e-record.nix { inherit pkgs; };
  builder = { lib = import ../lib/api.nix; };
  diskoModule = (import ../disko-pin.nix) + "/module.nix";

  endpoints = import ../examples/zfs/host.nix {
    inherit pkgs builder diskoModule;
    extraModules = [
      (import ./hosts/modules/e2e-result.nix { inherit record; })
      (import ./hosts/modules/marker.nix { inherit record; })
      (import ./hosts/modules/verify-slot.nix { inherit record; })
    ];
  };
in
{
  witnesses = [ ];
  check = boot {
    name = "e2e-example-zfs";
    image = endpoints.image-raw.file;
    expect = ''
      grep -q "E2E-BOOT-OK example-zfs" result
      grep -q "E2E-EXAMPLE-SLOT-MOUNTED" result
      grep -q "E2E-KEY-EMPTY" result
    '';
  };
}
