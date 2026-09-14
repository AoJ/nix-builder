# Test hosts and e2e for the blocks PoC. Real nixosSystem configurations enter HERE and
# nowhere else — blocks and their tests never see one. The staged gates:
#   test-hosts-compose  eval-only: every endpoint of every host forces to a .drv
#   e2e-*               built artifacts booted under OVMF/KVM, witnessed on the serial console
let
  pkgs = import <nixpkgs> { };
  tools = import ../blocks-poc/tools { inherit pkgs; };
  compose = import ../blocks-poc/compose.nix { inherit pkgs tools; };
  hosts = import ./hosts { inherit pkgs; };
in
{
  inherit hosts;
  endpoints = builtins.mapAttrs (_: compose) hosts;

  test-hosts-compose = import ./compose-test.nix { inherit pkgs compose hosts; };
  e2e-raw-boot = import ./e2e-raw-boot.nix { inherit pkgs compose hosts; };
  e2e-memory-boot = import ./e2e-memory-boot.nix { inherit pkgs compose hosts; };
  e2e-personalize-boot = import ./e2e-personalize-boot.nix { inherit pkgs compose hosts; };
  e2e-install-cycle = import ./e2e-install-cycle.nix { inherit pkgs compose hosts; };
  e2e-live-iso = import ./e2e-live-iso.nix { inherit pkgs compose hosts; };
}
