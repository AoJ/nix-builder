# Test hosts and e2e for the blocks PoC. Real nixosSystem configurations enter HERE and
# nowhere else — blocks and their tests never see one. The staged gates:
#   test-coverage           the (host, endpoint) table; holes match the laws, booted
#                           matches what the e2e suite WITNESSES
#   test-hosts-compose-<h>  eval-only, ONE host per attribute — run them as separate nix
#                           processes; one eval of all hosts peaks past this box's RAM
#   e2e-*                   built artifacts booted under OVMF/KVM or -kernel/-initrd,
#                           witnessed on the serial console
let
  pkgs = import (import ../nixpkgs-pin.nix) { };
  tools = import ../blocks-poc/tools { inherit pkgs; };
  compose = import ../blocks-poc/compose.nix { inherit pkgs tools; };
  hosts = import ./hosts { inherit pkgs tools; };

  e2e = {
    raw-boot = import ./e2e-raw-boot.nix { inherit pkgs compose hosts; };
    memory-boot = import ./e2e-memory-boot.nix { inherit pkgs compose hosts; };
    personalize-boot = import ./e2e-personalize-boot.nix { inherit pkgs compose hosts; };
    live-iso = import ./e2e-live-iso.nix { inherit pkgs compose hosts; };
    kexec-boot = import ./e2e-kexec-boot.nix { inherit pkgs compose hosts; };
    install-cycle = import ./e2e-install-cycle.nix { inherit pkgs compose hosts; };
    deploy-install = import ./e2e-deploy-install.nix { inherit pkgs compose hosts; };
    install-encrypted = import ./e2e-install-encrypted.nix { inherit pkgs compose hosts; };
  };

  coverage = import ./coverage.nix {
    inherit pkgs;
    witnessed = builtins.concatMap (e: e.witnesses) (builtins.attrValues e2e);
  };

  gate = import ./compose-test.nix { inherit pkgs compose hosts coverage; };
in
{
  inherit hosts;
  endpoints = builtins.mapAttrs (_: compose) hosts;

  test-coverage = coverage.check;
  test-schema = import ./schema-test.nix { inherit pkgs; };
}
// builtins.listToAttrs (map (h: {
  name = "test-hosts-compose-${h}";
  value = gate h;
}) (builtins.attrNames coverage.table))
// builtins.listToAttrs (map (n: {
  name = "e2e-${n}";
  value = e2e.${n}.check;
}) (builtins.attrNames e2e))
