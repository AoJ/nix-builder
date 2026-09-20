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

  # The endpoint names each example's flake.nix actually exposes — listed here so the gate
  # proves those exist, and a copy-paste flake cannot promise a name the composer would
  # refuse.
  published = {
    ext4 = [ "image-raw" "image-qcow2" "image-iso" "image-kexec-install"
             "image-personalize" "image-secrets-vfat" ];
    zfs = [ "image-raw" "image-qcow2" "image-kexec-install" "image-raw-install"
            "image-raw-install-inmemory" "image-iso-install" "image-personalize"
            "image-personalize-kexec" ];
    zfs-encrypted = [ "image-kexec-install" "image-raw-install"
                      "image-personalize-kexec" ];
    memory = [ "image-raw" "image-kexec" "image-iso" ];
  };

  drvOf = e: n:
    builtins.unsafeDiscardStringContext (
      if lib.hasPrefix "image-personalize" n || lib.hasPrefix "image-secrets" n
      then e.${n}.run.drvPath
      else e.${n}.file.drvPath);

  gate = name: endpoints:
    pkgs.writeText "test-example-${name}"
      (lib.concatMapStringsSep "\n" (n: "${name}.${n} ${drvOf endpoints n}") published.${name});
in

examples
// lib.mapAttrs' (name: e: lib.nameValuePair "test-example-${name}" (gate name e)) examples
