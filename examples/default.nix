# The examples, wired as suite targets so they cannot rot: each `test-example-*` forces
# every endpoint the example shows to a .drv (context discarded, nothing built) — the
# same eval gate the test hosts get, one example per attribute so the runner keeps them
# in separate nix processes. Browse an example's endpoints directly:
#
#   nix build -f examples example-ext4.endpoints.image-raw.file
{ pkgs ? import (import ../nixpkgs-pin.nix) { } }:

let
  inherit (pkgs) lib;
  tools = import ../tools { inherit pkgs; };
  compose = import ../compose.nix { inherit pkgs tools; };

  examples = {
    ext4 = import ./host-ext4.nix { inherit pkgs tools compose; };
    zfs = import ./host-zfs.nix { inherit pkgs tools compose; };
    zfs-encrypted = import ./host-zfs-encrypted.nix { inherit pkgs tools compose; };
    memory = import ./host-memory.nix { inherit pkgs tools compose; };
  };

  gate = name: example:
    pkgs.writeText "test-example-${name}" (lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (n: d: "${n} ${builtins.unsafeDiscardStringContext d.drvPath}")
        example.shown));
in

lib.mapAttrs' (n: e: lib.nameValuePair "example-${n}" e) examples
// lib.mapAttrs' (n: e: lib.nameValuePair "test-example-${n}" (gate n e)) examples
