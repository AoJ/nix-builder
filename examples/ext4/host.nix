# A plain disk host: your configuration, a disko layout, and the handful of things a
# configuration cannot state. Everything else — the storage, the machine, the live
# variants, the install recipe, the disk list — is read out of the host itself.
#
# See README.md for where each value comes from, and ../../lib/host-record.nix for the
# record this fills in.
{ pkgs, builder, diskoModule }:

let
  slotName = "secrets";
  # The disk's STABLE identity, taken from the real machine (`ls -l /dev/disk/by-id/`).
  # The install clears exactly the disks the layout names, so a name that moves between
  # boots is a name that can clear the wrong disk.
  device = "/dev/disk/by-id/virtio-main";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-ext4";
    users.allowNoPasswordLogin = true;
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration diskoModule (import ./layout.nix { inherit device slotName; }) ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host slotName;

  # What this host wants in its slot, and where the bytes come from. `file` is a path
  # read when the phase-2 runner RUNS; a deploy holding the material in a variable would
  # say `content.env` instead, and an already-encrypted blob can be `content.text`.
  # Blocks carries the bytes and never opens them.
  secrets = {
    delivery = [ "embedded" "sidecar" ];
    files = [{
      target = "/sops.age";
      content.file = "/run/secrets/example-ext4/host.key";
    }];
  };
}
