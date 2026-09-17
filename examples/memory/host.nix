# A memory-rooted appliance: a tmpfs root over a read-only squashfs store. That one fact
# in the configuration is what makes it memory-rooted — the front door reads it, so
# nothing here says "squashfs" a second time.
#
# The host has no install recipe and needs none: a squashfs store is written by the image
# (law L6), so its installers are holes and the image itself is the deliverable.
{ pkgs, builder }:

let
  inherit (builder.lib.mk { inherit pkgs; }) modules;

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-memory";
    users.allowNoPasswordLogin = true;
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      configuration
      # The read-only store: the squashfs partition the image writes, overlaid and
      # registered, with the tmpfs root over it. The partition is found by the label the
      # image gives it.
      (modules.readOnlyStore { device = "/dev/disk/by-partlabel/nixos"; })
    ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host;
  slotName = "secrets";
  # No secrets declared: every secrets and personalize endpoint still exists and is a
  # silent no-op. Nothing may key off "this host has a bundle".
}
