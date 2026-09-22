# Test hosts and e2e for the blocks PoC. Real nixosSystem configurations enter HERE and
# nowhere else — blocks and their tests never see one. The staged gates:
#   test-coverage           the (host, endpoint) table; holes match the laws, booted
#                           matches what the e2e suite WITNESSES
#   test-hosts-compose-<h>  eval-only, ONE host per attribute — run them as separate nix
#                           processes; one eval of all hosts peaks past this box's RAM
#   e2e-*                   built artifacts booted under OVMF/KVM or -kernel/-initrd,
#                           witnessed on the result disk the harness attaches
{ pkgs ? import (import ../nixpkgs-pin.nix) { } }:
let
  tools = import ../tools { inherit pkgs; };
  compose = import ../compose.nix { inherit pkgs tools; };
  record = import ./e2e-record.nix { inherit pkgs; };
  hosts = import ./hosts { inherit pkgs tools record; };

  e2e = {
    raw-boot = import ./e2e-raw-boot.nix { inherit pkgs compose hosts; };
    zfs-raw-boot = import ./e2e-zfs-raw-boot.nix { inherit pkgs compose hosts; };
    zfs-qcow2-boot = import ./e2e-zfs-qcow2-boot.nix { inherit pkgs compose hosts; };
    qcow2-boot = import ./e2e-qcow2-boot.nix { inherit pkgs compose hosts; };
    memory-iso-boot = import ./e2e-memory-iso-boot.nix { inherit pkgs compose hosts; };
    slotless-install = import ./e2e-slotless-install.nix { inherit pkgs compose hosts; };
    ext4-raw-install = import ./e2e-ext4-raw-install.nix { inherit pkgs compose hosts; };
    zfs-inmemory-install = import ./e2e-zfs-inmemory-install.nix { inherit pkgs compose hosts; };
    memory-boot = import ./e2e-memory-boot.nix { inherit pkgs compose hosts; };
    personalize-boot = import ./e2e-personalize-boot.nix { inherit pkgs compose hosts; };
    personalize-stream = import ./e2e-personalize-stream.nix { inherit pkgs compose hosts; };
    live-iso = import ./e2e-live-iso.nix { inherit pkgs compose hosts; };
    kexec-boot = import ./e2e-kexec-boot.nix { inherit pkgs compose hosts; };
    install-cycle = import ./e2e-install-cycle.nix { inherit pkgs compose hosts; };
    deploy-install = import ./e2e-deploy-install.nix { inherit pkgs compose hosts; };
    install-encrypted = import ./e2e-install-encrypted.nix { inherit pkgs compose hosts; };
    iso-install = import ./e2e-iso-install.nix { inherit pkgs compose hosts; };
    ext4-install = import ./e2e-ext4-install.nix { inherit pkgs compose hosts; };
    self-reinstall = import ./e2e-self-reinstall.nix { inherit pkgs compose hosts; };
    reinstall = import ./e2e-reinstall.nix { inherit pkgs compose hosts; };
    install-gate = import ./e2e-install-gate.nix { inherit pkgs compose hosts; };
    capability-gate = import ./e2e-capability-gate.nix { inherit pkgs compose hosts; };
    zfs-reinstall = import ./e2e-zfs-reinstall.nix { inherit pkgs compose hosts; };
    image-install = import ./e2e-image-install.nix { inherit pkgs compose hosts; };
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
  test-sidecar-identity = import ./test-sidecar-identity.nix { inherit pkgs compose hosts; };
}
// builtins.listToAttrs (map (h: {
  name = "test-hosts-compose-${h}";
  value = gate h;
}) (builtins.attrNames coverage.table))
// builtins.listToAttrs (map (n: {
  name = "e2e-${n}";
  value = e2e.${n}.check;
}) (builtins.attrNames e2e))
# A hole is a law-forbidden (host, endpoint) pair: the endpoint EXISTS but its artifact is
# a derivation that fails to build with the law. run-all builds every `hole-*` expecting
# that failure — the direct test of what a consumer hits building a forbidden pair.
// builtins.listToAttrs (builtins.concatMap (h:
  map (n: {
    name = "hole-${h}-${n}";
    value = (compose hosts.${h}).${n}.file;
  }) coverage.lawHoles.${h})
  (builtins.attrNames coverage.lawHoles))
