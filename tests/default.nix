# Test hosts and e2e for the blocks PoC. Real nixosSystem configurations enter HERE and
# nowhere else — blocks and their tests never see one. The staged gates:
#   test-coverage       the (host, endpoint) table: every pair has exactly one declared status
#   test-hosts-compose  eval-only: every non-hole endpoint of every host forces to a .drv,
#                       every hole refuses
#   e2e-*               built artifacts booted under OVMF/KVM, witnessed on the serial console
let
  pkgs = import (import ../nixpkgs-pin.nix) { };
  tools = import ../blocks-poc/tools { inherit pkgs; };
  compose = import ../blocks-poc/compose.nix { inherit pkgs tools; };
  hosts = import ./hosts { inherit pkgs; };
  coverage = import ./coverage.nix { inherit pkgs; };
in
{
  inherit hosts;
  endpoints = builtins.mapAttrs (_: compose) hosts;

  test-coverage = coverage.check;
  test-hosts-compose = import ./compose-test.nix { inherit pkgs compose hosts coverage; };
  e2e-raw-boot = import ./e2e-raw-boot.nix { inherit pkgs compose hosts; };
  e2e-memory-boot = import ./e2e-memory-boot.nix { inherit pkgs compose hosts; };
  e2e-personalize-boot = import ./e2e-personalize-boot.nix { inherit pkgs compose hosts; };
  e2e-install-cycle = import ./e2e-install-cycle.nix { inherit pkgs compose hosts; };
  e2e-live-iso = import ./e2e-live-iso.nix { inherit pkgs compose hosts; };
}
