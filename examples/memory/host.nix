# The appliance — memory-rooted, squashfs store. The runtime image IS the deliverable: a
# squashfs store is written by the image, never by an install (law L6), so every -install
# endpoint of this host is a named hole that refuses at eval. Deploying means shipping
# image-raw itself, or netbooting image-kexec; the disk carries a read-only store and the
# root lives in RAM.
#
# The fields, their types and what reads each: lib/host-record.nix — the contract the
# composer validates every record through.
{ pkgs, builder }:

let
  inherit (builder.lib.mk { inherit pkgs; }) modules;
  inherit (builder.lib) extract;

  system = "x86_64-linux";
  slotName = "secrets";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-memory";
    users.allowNoPasswordLogin = true;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [
      configuration
      # The read-only store: the squashfs partition the image writes, overlaid and
      # registered, with a tmpfs root over it. The partition is named by the image's own
      # store label.
      (modules.readOnlyStore { device = "/dev/disk/by-partlabel/nixos"; })
    ];
  };
in
{
  name = "example-memory";
  inherit system slotName;

  variants = {
    runtime = extract nixos // { storage = "squashfs"; };
    liveNetboot = extract (nixos.extendModules { modules = [ modules.liveNetboot ]; });
    liveIso = label: extract (nixos.extendModules { modules = [ (modules.liveIso label) ]; });
  };

  # A host that declares no secrets gets a silent no-op everywhere — every endpoint still
  # exists, nothing may key off "the host has a bundle".
  secrets = {
    delivery = [ ];
    files = [ ];
  };

  # No `install` at all: this host's installers are L6 holes, and the record only holds a
  # host to what its own endpoints actually read.
}
