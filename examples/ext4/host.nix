# A plain disk host: your configuration, a disko layout, and the handful of things a
# configuration cannot state. Everything else — the storage, the machine, the live
# variants, the install recipe, the disk list — is read out of the host itself.
#
# The layout here is the builder's TEMPLATE, for a host with nothing particular to say
# about its disk. It is an ordinary disko layout in this configuration: override any of it
# below, or drop it and write your own — the install treats both the same way, because it
# just runs disko's create script.
#
# See README.md for where each value comes from, and ../../lib/host-record.nix for the
# record this fills in.
# extraModules is empty for a real host; the suite passes its witness modules through it to
# BOOT this very example (tests/e2e-example-ext4.nix), so what you copy is what is proven.
{ pkgs, builder, diskoModule, extraModules ? [ ] }:

let
  slotName = "secrets";
  # The disk's STABLE identity, taken from the real machine (`ls -l /dev/disk/by-id/`).
  # The install clears exactly the disks the layout names, so a name that moves between
  # boots is a name that can clear the wrong disk.
  device = "/dev/disk/by-id/virtio-main";

  configuration = { config, modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-ext4";
    users.allowNoPasswordLogin = true;

    # CONSUME your own secrets. The embedded slot is a vfat partition IN the image, found by
    # its partlabel = slotName — your input, one source, nothing derived to guess. `nofail`
    # so a host whose slot is not filled yet (phase 2 fills it) still boots.
    fileSystems."/run/secrets" = {
      device = "/dev/disk/by-partlabel/${slotName}";
      fsType = "vfat";
      options = [ "ro" "nofail" ];
    };
    # Delivering by SIDECAR instead (a separate medium)? Its iso9660 label is name-DERIVED, so
    # mount by exactly what you derive — the SAME function the builder stamps with, never a
    # hardcoded string, and available with no build (a hash of the name):
    #   fileSystems."/run/secrets" = {
    #     device = "/dev/disk/by-label/${builder.lib.labels.secretsIsoLabel config.networking.hostName}";
    #     fsType = "iso9660";
    #     options = [ "ro" "nofail" ];
    #   };
  };

  # GPT on that disk: an ESP at /boot, a vfat slot partition named slotName, an ext4 root
  # taking the rest. The two sizes are arguments; the rest is an ordinary disko layout in
  # this configuration — override a partition with lib.mkForce, or drop the template and
  # write your own. The install runs disko's create script either way.
  layout = builder.lib.diskLayout {
    inherit device slotName;
    slotSize = "32M";
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration diskoModule layout ] ++ extraModules;
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
