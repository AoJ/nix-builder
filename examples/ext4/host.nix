# The plain disk VM — the smallest full story. One disko layout owns the disk AND the
# slot partition, so the same declaration boots the host, formats it at install, and
# names where phase 2 writes.
#
# The record is DATA: derivations and strings the composer reads. Everything it needs
# from the builder comes through `builder.lib`; nothing reaches into the builder's
# source tree.
#
# The fields, their types and what reads each: lib/host-record.nix — the contract the
# composer validates every record through.
{ pkgs, builder, diskoModule }:

let
  inherit (pkgs) lib;
  inherit (builder.lib.mk { inherit pkgs; }) modules;
  inherit (builder.lib) extract;

  system = "x86_64-linux";
  slotName = "secrets";
  # The disk's STABLE identity: an install survives /dev/sdX shuffling, a by-id name
  # does not move.
  device = "/dev/disk/by-id/virtio-main";

  # Your machine's configuration. The installer inherits the hardware support declared
  # here — kernel, module sets, firmware — so it boots exactly where the host boots.
  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-ext4";
    users.allowNoPasswordLogin = true;
  };

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ configuration diskoModule (import ./layout.nix { inherit device slotName; }) ];
  };
in
{
  name = "example-ext4";
  inherit system slotName;

  # Each live variant is the host PLUS a face — extendModules, never a second hand-built
  # configuration. A live format packs a different toplevel, and this is where that
  # difference is declared.
  variants = {
    runtime = extract nixos // { storage = "ext4"; };
    liveNetboot = extract (nixos.extendModules { modules = [ modules.liveNetboot ]; });
    liveIso = label: extract (nixos.extendModules { modules = [ (modules.liveIso label) ]; });
  };

  # Sources are RUNTIME path strings, never derivations: a secret in a derivation is a
  # secret in the store. Point them at whatever your vault drops on the deploying
  # machine — they are read when the phase-2 runner runs, not when this evaluates.
  secrets = {
    delivery = [ "embedded" "sidecar" ];
    bundle = "/run/secrets/example-ext4/bundle.yaml";
    keyTarget = "/sops.age";
    files = [{
      target = "/sops.age";
      source = "/run/secrets/example-ext4/host.key";
      runtimeSource = "/run/secrets/example-ext4/host.key";
    }];
  };

  # disko's own scripts ARE the install: create+mount, and mount-existing — the
  # never-reformat path. The layout's device list is what a create wipes, and nothing
  # else is ever touched.
  install = {
    prepare = nixos.config.system.build.diskoScript;
    mount = nixos.config.system.build.mountScript;
    pool = "";
    encrypted = false;
    keyDestination = "/var/lib/sops/age.key";
    poolKeyDestination = null;
    disks = map (d: d.device) (lib.attrValues nixos.config.disko.devices.disk);
    report = null;
  };
}
