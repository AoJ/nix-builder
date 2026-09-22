# The gate that keeps the examples honest: each one is evaluated through the SAME public
# API a consumer gets from the flake (lib/api.nix — the flake exports this very value),
# with this checkout standing in for the `builder` input. Every endpoint an example's
# flake.nix publishes is then forced to a .drv; nothing is built here.
#
# One example per attribute, because the runner gives each its own nix process — a full
# endpoint set costs ~1 GB of eval heap.
#
#   nix build -f examples ext4.image-raw.file     # build what an example makes
{ pkgs ? import (import ../nixpkgs-pin.nix) { } }:

let
  inherit (pkgs) lib;

  # What a consumer's `builder` flake input looks like from inside an example.
  builder = { lib = import ../lib/api.nix; };

  # The disk-owning examples import a disko module; a consumer passes their own input's
  # (disko.nixosModules.disko), the gate passes the pinned source's.
  diskoModule = (import ../disko-pin.nix) + "/module.nix";

  examples = {
    ext4 = import ./ext4/host.nix { inherit pkgs builder diskoModule; };
    zfs = import ./zfs/host.nix { inherit pkgs builder diskoModule; };
    zfs-encrypted = import ./zfs-encrypted/host.nix { inherit pkgs builder diskoModule; };
    memory = import ./memory/host.nix { inherit pkgs builder; };
  };

  # No per-host list of endpoints any more — that was the very thing this repo exists to
  # kill. Each host exposes the WHOLE set; the gate forces every non-hole endpoint to a .drv
  # (nothing built) and asserts every hole carries its law as DATA. And it asserts every
  # example exposes the SAME set of names — a host whose set drifts from the others fails
  # here, not silently in someone's flake.
  canonical = lib.sort lib.lessThan (builtins.attrNames (builtins.head (builtins.attrValues examples)));

  drvOf = e:
    builtins.unsafeDiscardStringContext (
      if e ? run then e.run.drvPath
      else if e ? file then e.file.drvPath
      else e.drvPath);  # closure / closure-live: the toplevel itself

  gate = name: endpoints:
    let
      names = lib.sort lib.lessThan (builtins.attrNames endpoints);
      holes = lib.filterAttrs (_: e: e ? hole) endpoints;
      buildable = lib.filterAttrs (_: e: !(e ? hole)) endpoints;
      forced = lib.mapAttrsToList (n: e: "${name}.${n} ${drvOf e}") buildable;
      # A hole is data: read its law and replacement, never force its .file.
      holed = lib.mapAttrsToList (n: e: "${name}.${n} hole:${e.hole.law} -> ${e.hole.replacement}") holes;
    in
    assert lib.assertMsg (names == canonical)
      "${name}: endpoint set drifts from the others: ${builtins.toJSON names}";
    pkgs.writeText "test-example-${name}"
      (lib.concatStringsSep "\n" (forced ++ holed));
in

examples
// lib.mapAttrs' (name: e: lib.nameValuePair "test-example-${name}" (gate name e)) examples
