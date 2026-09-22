# Booting the memory-rooted EXAMPLE a user copies: tmpfs root over the read-only squashfs
# store the image writes. It has no slot, so the proof is narrower — userspace comes up over
# the RAM root and the store the image stamped, which the examples/ eval gate never showed.
{ pkgs }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  record = import ./e2e-record.nix { inherit pkgs; };
  builder = { lib = import ../lib/api.nix; };

  endpoints = import ../examples/memory/host.nix {
    inherit pkgs builder;
    extraModules = [
      (import ./hosts/modules/e2e-result.nix { inherit record; })
      (import ./hosts/modules/marker.nix { inherit record; })
    ];
  };
in
{
  witnesses = [ ];
  check = boot {
    name = "e2e-example-memory";
    image = endpoints.image-raw.file;
    expect = ''
      grep -q "E2E-BOOT-OK example-memory" result
    '';
  };
}
