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
      # registered, with the tmpfs root over it. No device stated — the appliance's runtime
      # store IS that partition, found by the label the image stamps (one source, so a
      # rename cannot silently leave the host without a root).
      (modules.readOnlyStore { })
    ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host;
  # No secrets and no slotName: this appliance delivers nothing to a slot, so it names none
  # and no slot partition is built. The secrets/personalize endpoints still exist as silent
  # no-ops — nothing may key off "this host has a bundle".
}
