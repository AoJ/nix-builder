# A zfs server. The configuration states a zfs root, and that is enough for the front door
# to know the storage and the pool (`rpool/root` → `rpool`). The pool is not a disko
# layout in the ext4 sense, but it IS disko data — so this host imports the zfs layout
# template next to disko's module, and the ONE layout feeds three things: the install runs
# disko's create script through it, the runtime disk image is formatted from it by the
# format-VM (a pool is a kernel object; a runner-arch VM makes it, so an aarch64 image
# builds on an x86 box), and the disk list a create may clear comes from it too.
#
# The runtime disk images are NO LONGER holes (that was L2 before the format-VM): `#image-raw`
# is real. See README.md.
{ pkgs, builder, diskoModule }:

let
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";
  slotName = "secrets";
  # The ESP partlabel: ONE binding, so the layout's label and the /boot mount below cannot
  # drift into a host that formats an ESP it then cannot find.
  espLabel = "ESP";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs";
    users.allowNoPasswordLogin = true;

    # A zfs root's runtime facts the host states itself (the layout template leaves
    # enableConfig off): the pool's hostId — the same one the format-VM builds the pool
    # with, so first boot imports without -f — and the root/boot mounts.
    networking.hostId = "8425e349";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    boot.zfs.devNodes = "/dev/disk/by-partlabel";
    fileSystems."/" = { device = "${pool}/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/${espLabel}"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;
  };

  # ESP at /boot, the vfat slot, the rest one pool with a legacy root — an ordinary disko
  # layout in this configuration; override a partition with lib.mkForce, or drop it and
  # write your own. Both the install and the image read the same data. pool and espLabel are
  # the SAME bindings the fileSystems above use, so the layout and the mounts cannot drift.
  layout = builder.lib.diskLayoutZfs { inherit device slotName pool espLabel; };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration diskoModule layout ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host slotName;

  secrets = {
    delivery = [ "embedded" "sidecar" ];
    files = [{
      target = "/sops.age";
      content.file = "/run/secrets/example-zfs/host.key";
    }];
  };
}
